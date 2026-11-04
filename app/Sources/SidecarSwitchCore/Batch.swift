import Foundation

public enum RemoteBatchKind: String, Sendable, Equatable, CaseIterable {
    case prereqs
    case verify

    public var expectedSections: [String] {
        switch self {
        case .prereqs: return ["devices", "dispid"]
        case .verify: return ["connected_a", "connected_b", "dispid"]
        }
    }
}

public struct RemoteSectionResult: Sendable, Equatable {
    public var section: String
    public var exitCode: Int32
    public var content: String

    public init(section: String, exitCode: Int32, content: String) {
        self.section = section
        self.exitCode = exitCode
        self.content = content
    }
}

public enum BatchError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidNonce
    case emptyOutput
    case invalidStructure(String)
    case missingSection(String)
    case invalidExit(String)

    public var description: String {
        switch self {
        case .invalidNonce: return "nonce non valido"
        case .emptyOutput: return "stdout del batch vuoto"
        case .invalidStructure(let message): return "struttura batch non valida: \(message)"
        case .missingSection(let section): return "sezione mancante: \(section)"
        case .invalidExit(let section): return "exit non valido per \(section)"
        }
    }
}

public enum BatchExecution: Sendable, Equatable {
    case sections([RemoteSectionResult])
    case parseFailed(BatchError)
    case transport(Reason)
}

public protocol NonceProviding: Sendable {
    func makeNonce() -> String
}

public struct SystemNonceProvider: NonceProviding {
    public init() {}

    public func makeNonce() -> String {
        let value = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return String(value.prefix(16))
    }
}

public struct FixedNonceProvider: NonceProviding {
    public let nonce: String

    public init(_ nonce: String) {
        self.nonce = nonce
    }

    public func makeNonce() -> String { nonce }
}

public enum BatchProtocol {
    public static func isValidNonce(_ nonce: String) -> Bool {
        guard nonce.count == 16 else { return false }
        return nonce.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 97 && scalar.value <= 102)
        }
    }

    public static func begin(_ section: String, nonce: String) -> String {
        "__SSC_BEGIN_\(section)_\(nonce)__"
    }

    public static func end(_ section: String, nonce: String, exitCode: Int32) -> String {
        "__SSC_END_\(section)_\(nonce)__exit=\(exitCode)"
    }

    public static func endPrefix(_ section: String, nonce: String) -> String {
        "__SSC_END_\(section)_\(nonce)__exit="
    }
}

public enum BatchParser {
    public static func parse(nonce: String, stdout: String,
                             expected: [String]) -> Result<[RemoteSectionResult], BatchError> {
        guard BatchProtocol.isValidNonce(nonce) else { return .failure(.invalidNonce) }
        guard !stdout.isEmpty else { return .failure(.emptyOutput) }

        let lines = stdout.components(separatedBy: "\n")
        var results: [RemoteSectionResult] = []
        var index = 0
        var expectedIndex = 0

        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("__SSC_") {
                guard expectedIndex < expected.count else {
                    return .failure(.invalidStructure("marker inatteso \(line)"))
                }
                let section = expected[expectedIndex]
                guard line == BatchProtocol.begin(section, nonce: nonce) else {
                    return .failure(.invalidStructure("BEGIN inatteso/ fuori ordine: \(line)"))
                }
                index += 1
                var content: [String] = []
                var foundEnd = false
                while index < lines.count {
                    let candidate = lines[index]
                    if candidate.hasPrefix("__SSC_") {
                        guard let exitCode = parseEnd(candidate, section: section, nonce: nonce) else {
                            return .failure(.invalidStructure("END inatteso nella sezione \(section): \(candidate)"))
                        }
                        results.append(RemoteSectionResult(section: section, exitCode: exitCode,
                                                           content: content.joined(separator: "\n")))
                        foundEnd = true
                        index += 1
                        break
                    }
                    content.append(candidate)
                    index += 1
                }
                guard foundEnd else { return .failure(.missingSection(section)) }
                expectedIndex += 1
            } else {
                index += 1
            }
        }

        guard expectedIndex == expected.count else {
            return .failure(.missingSection(expected[expectedIndex]))
        }
        return .success(results)
    }

    private static func parseEnd(_ line: String, section: String, nonce: String) -> Int32? {
        let prefix = BatchProtocol.endPrefix(section, nonce: nonce)
        guard line.hasPrefix(prefix) else { return nil }
        let value = line.dropFirst(prefix.count)
        guard let exit = Int32(value), exit >= 0, String(exit) == String(value) else { return nil }
        return exit
    }
}

public enum BatchClassification {
    public static func devices(_ section: RemoteSectionResult) -> DevicesReport {
        let status = ExitCodes.sectionStatus(section.exitCode)
        return DevicesReport(status: status,
                             names: DeviceListParser.parse(section.content),
                             report: CommandReport(status: status, stdout: section.content))
    }

    public static func displays(_ section: RemoteSectionResult) -> DisplaysReport {
        let status = ExitCodes.sectionStatus(section.exitCode)
        return DisplaysReport(status: status,
                              displays: DisplayParser.parse(section.content),
                              report: CommandReport(status: status, stdout: section.content))
    }

    public static func probe(_ section: RemoteSectionResult) -> ProbeReport {
        let status = ExitCodes.sectionStatus(section.exitCode)
        return ExitCodes.probeReport(status: status, stdout: section.content, stderr: "")
    }
}
