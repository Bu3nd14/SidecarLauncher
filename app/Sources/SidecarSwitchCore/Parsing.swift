import Foundation

public enum DisplayRule {
    public static let sidecarVendor: UInt32 = 0x6161706c
    public static let virtualVendor: UInt32 = 0x5644

    public static func isLiveSidecar(_ display: DisplayInfo) -> Bool {
        display.vendor == sidecarVendor
            && !display.asleep
            && (display.active || display.mirrors != 0)
    }

    public static func hasBuiltin(_ displays: [DisplayInfo]) -> Bool {
        displays.contains { $0.builtin }
    }

    public static func hasVirtual(_ displays: [DisplayInfo]) -> Bool {
        displays.contains { $0.vendor == virtualVendor }
    }

    public static func hasSidecar(_ displays: [DisplayInfo]) -> Bool {
        displays.contains { $0.vendor == sidecarVendor }
    }
}

public enum ConnectedParser {
    public static func parse(_ stdout: String) -> (count: Int?, devices: [String]) {
        var count: Int?
        var devices: [String] = []
        for rawLine in stdout.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("connected=") {
                count = Int(line.dropFirst("connected=".count))
            } else if line.hasPrefix("device=") {
                devices.append(String(line.dropFirst("device=".count)))
            }
        }
        return (count, devices)
    }
}

public enum DeviceListParser {
    public static func parse(_ stdout: String) -> [String] {
        stdout.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

public enum DisplayParser {
    public static func parse(_ stdout: String) -> [DisplayInfo] {
        var displays: [DisplayInfo] = []
        for rawLine in stdout.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            var fields: [String: String] = [:]
            var size: String?
            for token in line.split(separator: " ") {
                let text = String(token)
                if let equals = text.firstIndex(of: "=") {
                    fields[String(text[..<equals])] = String(text[text.index(after: equals)...])
                } else if text.contains("x") {
                    size = text
                }
            }
            guard let idText = fields["id"], let id = UInt32(idText),
                  let vendorText = fields["vendor"], let vendor = parseHex(vendorText) else { continue }
            var width = 0
            var height = 0
            if let size, let separator = size.firstIndex(of: "x") {
                width = Int(size[..<separator]) ?? 0
                height = Int(size[size.index(after: separator)...]) ?? 0
            }
            displays.append(DisplayInfo(
                id: id,
                vendor: vendor,
                model: fields["model"].flatMap(parseHex) ?? 0,
                serial: fields["serial"].flatMap { UInt32($0) } ?? 0,
                builtin: fields["builtin"] == "true",
                main: fields["main"] == "true",
                active: fields["active"] == "true",
                mirrors: fields["mirror_of"].flatMap { UInt32($0) } ?? 0,
                asleep: fields["asleep"] == "true",
                width: width,
                height: height
            ))
        }
        return displays
    }

    private static func parseHex(_ value: String) -> UInt32? {
        if value.hasPrefix("0x") || value.hasPrefix("0X") {
            return UInt32(value.dropFirst(2), radix: 16)
        }
        return UInt32(value, radix: 16) ?? UInt32(value)
    }
}
