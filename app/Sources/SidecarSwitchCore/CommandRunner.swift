import Darwin
import Foundation

public final class SystemCommandRunner: CommandRunning, @unchecked Sendable {
    public let gracePeriod: Duration
    private let outputLimit: Int

    public init(gracePeriod: Duration = .seconds(2), outputLimit: Int = 64 * 1024) {
        self.gracePeriod = gracePeriod
        self.outputLimit = outputLimit
    }

    public func run(_ spec: CommandSpec, timeout: Duration) async -> CommandResult {
        let grace = gracePeriod
        let limit = outputLimit
        return await withCheckedContinuation { (continuation: CheckedContinuation<CommandResult, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: SystemCommandRunner.execute(spec, timeout: timeout, grace: grace, outputLimit: limit))
            }
        }
    }

    private final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private let limit: Int
        private var truncated = false

        init(limit: Int) { self.limit = limit }

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock()
            let room = limit - data.count
            if room > 0 {
                data.append(contentsOf: chunk.prefix(room))
                if chunk.count > room { truncated = true }
            } else {
                truncated = true
            }
            lock.unlock()
        }

        func string() -> String {
            lock.lock()
            defer { lock.unlock() }
            return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        }

        func ending() -> String {
            lock.lock()
            let value = truncated
            lock.unlock()
            return value ? "<output troncato>" : ""
        }
    }

    private static func drain(fd: Int32, into buffer: OutputBuffer) {
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { raw -> Int in
                Darwin.read(fd, raw.baseAddress, raw.count)
            }
            if count > 0 {
                buffer.append(Data(chunk[0..<count]))
                continue
            }
            if count == 0 { break }
            if errno == EINTR { continue }
            break
        }
    }

    private static func execute(_ spec: CommandSpec, timeout: Duration, grace: Duration, outputLimit: Int) -> CommandResult {
        let process = Process()
        let executable: String
        var arguments: [String]

        if spec.executable.hasPrefix("/") {
            executable = spec.executable
            arguments = spec.arguments
        } else {
            executable = "/usr/bin/env"
            arguments = [spec.executable] + spec.arguments
        }

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        if let environment = spec.environment {
            process.environment = environment
        } else {
            process.environment = BaseEnvironment.make()
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return CommandResult(launchError: "\(error)", stdout: "", stderr: "")
        }

        let stdoutBuffer = OutputBuffer(limit: outputLimit)
        let stderrBuffer = OutputBuffer(limit: outputLimit)
        let stdoutFD = stdoutPipe.fileHandleForReading.fileDescriptor
        let stderrFD = stderrPipe.fileHandleForReading.fileDescriptor

        let group = DispatchGroup()
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            drain(fd: stdoutFD, into: stdoutBuffer)
        }
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            drain(fd: stderrFD, into: stderrBuffer)
        }

        let clock = ContinuousClock()
        let start = clock.now
        var timedOut = false

        while process.isRunning {
            if clock.now - start >= timeout {
                timedOut = true
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }

        if timedOut {
            if process.isRunning { process.terminate() }
            let graceStart = clock.now
            while process.isRunning && clock.now - graceStart < grace {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
        } else {
            process.waitUntilExit()
        }

        if group.wait(timeout: .now() + 2) == .timedOut {
            Darwin.close(stdoutFD)
            Darwin.close(stderrFD)
            _ = group.wait(timeout: .now() + 1)
        }
        try? stdoutPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForReading.close()

        var signal: Int32?
        var exitCode: Int32?
        if process.terminationReason == .uncaughtSignal {
            signal = process.terminationStatus
        } else {
            exitCode = process.terminationStatus
        }

        let stdout = stdoutBuffer.string() + stdoutBuffer.ending()
        let stderr = stderrBuffer.string() + stderrBuffer.ending()

        return CommandResult(exitCode: exitCode, signal: signal, timedOut: timedOut,
                             launchError: nil, stdout: stdout, stderr: stderr)
    }
}
