import Foundation
import IOKit

/// The System Management Controller, spoken to directly. Reading needs no special rights; writing
/// needs root. The call takes one 80-byte C struct, laid out here by its offsets, because Swift
/// doesn't promise C's layout for nested structs.
final class SMC {
    enum Failure: Error, CustomStringConvertible {
        case noService, call(kern_return_t), result(key: String, code: UInt8), noKey(String), badValue(String)

        var description: String {
            switch self {
            case .noService: "The SMC couldn't be opened."
            case .call(let code): "The SMC call failed (\(code))."
            case .result(let key, let code): "The SMC refused \(key) (0x\(String(code, radix: 16)))."
            case .noKey(let key): "This Mac has no \(key)."
            case .badValue(let key): "\(key) has a type Zefra can't write."
            }
        }
    }

    struct KeyInfo {
        var size: UInt32
        var type: String
    }

    private enum Command {
        static let read: UInt8 = 5
        static let write: UInt8 = 6
        static let keyAtIndex: UInt8 = 8
        static let keyInfo: UInt8 = 9
    }
    private enum Offset {
        static let key = 0, size = 28, type = 32, result = 40, command = 42, index = 44, bytes = 48
    }

    private var connection: io_connect_t = 0
    private var infos: [String: KeyInfo] = [:]

    init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw Failure.noService }
        defer { IOObjectRelease(service) }
        let opened = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard opened == KERN_SUCCESS else { throw Failure.call(opened) }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    static func code(_ key: String) -> UInt32 { key.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

    static func name(_ code: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .macOSRoman) ?? ""
    }

    private func call(_ input: [UInt8]) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: 80)
        var size = 80
        let status = input.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { target in
                IOConnectCallStructMethod(connection, 2, source.baseAddress, 80, target.baseAddress, &size)
            }
        }
        guard status == KERN_SUCCESS else { throw Failure.call(status) }
        return output
    }

    private static func store(_ value: UInt32, in bytes: inout [UInt8], at offset: Int) {
        bytes.withUnsafeMutableBytes { $0.storeBytes(of: value, toByteOffset: offset, as: UInt32.self) }
    }

    private static func load(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
    }

    func info(_ key: String) throws -> KeyInfo {
        if let known = infos[key] { return known }
        var input = [UInt8](repeating: 0, count: 80)
        Self.store(Self.code(key), in: &input, at: Offset.key)
        input[Offset.command] = Command.keyInfo
        let output = try call(input)
        guard output[Offset.result] == 0 else { throw Failure.noKey(key) }
        let info = KeyInfo(size: Self.load(output, at: Offset.size), type: Self.name(Self.load(output, at: Offset.type)))
        infos[key] = info
        return info
    }

    func has(_ key: String) -> Bool { (try? info(key)) != nil }

    func bytes(_ key: String) throws -> [UInt8] {
        let info = try info(key)
        var input = [UInt8](repeating: 0, count: 80)
        Self.store(Self.code(key), in: &input, at: Offset.key)
        Self.store(info.size, in: &input, at: Offset.size)
        input[Offset.command] = Command.read
        let output = try call(input)
        guard output[Offset.result] == 0 else { throw Failure.result(key: key, code: output[Offset.result]) }
        return Array(output[Offset.bytes..<(Offset.bytes + min(Int(info.size), 32))])
    }

    /// The key's value as a number, for every numeric type it can have.
    func number(_ key: String) -> Double? {
        guard let info = try? info(key), let data = try? bytes(key) else { return nil }
        return Self.decode(type: info.type, data)
    }

    static func decode(type: String, _ data: [UInt8]) -> Double? {
        func bigEndian(_ count: Int) -> UInt64? {
            data.count >= count ? data.prefix(count).reduce(UInt64(0)) { $0 << 8 | UInt64($1) } : nil
        }
        switch type {
        case "flt ": return data.count >= 4 ? Double(data.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }) : nil
        // Spelled out: `.map(Double.init)` on a UInt64 picks Double(bitPattern:), and 2 becomes 1e-323.
        case "ui8 ", "flag": return bigEndian(1).map { Double($0) }
        case "ui16": return bigEndian(2).map { Double($0) }
        case "ui32": return bigEndian(4).map { Double($0) }
        case "fpe2": return bigEndian(2).map { Double($0) / 4 }
        case "sp78": return bigEndian(2).map { Double(Int16(truncatingIfNeeded: $0)) / 256 }
        case "ioft": return data.count >= 8 ? Double(data.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }) / 65536 : nil
        default: return nil
        }
    }

    /// Every key on this Mac.
    func allKeys() -> [String] {
        guard let total = number("#KEY") else { return [] }
        var keys: [String] = []
        keys.reserveCapacity(Int(total))
        for index in 0..<UInt32(total) {
            var input = [UInt8](repeating: 0, count: 80)
            Self.store(index, in: &input, at: Offset.index)
            input[Offset.command] = Command.keyAtIndex
            guard let output = try? call(input), output[Offset.result] == 0 else { continue }
            keys.append(Self.name(Self.load(output, at: Offset.key)))
        }
        return keys
    }

    /// Writes raw bytes. Only the helper's fan code calls this.
    func write(_ key: String, _ data: [UInt8]) throws {
        let info = try info(key)
        guard data.count == Int(info.size) else { throw Failure.badValue(key) }
        var input = [UInt8](repeating: 0, count: 80)
        Self.store(Self.code(key), in: &input, at: Offset.key)
        Self.store(info.size, in: &input, at: Offset.size)
        input[Offset.command] = Command.write
        input.replaceSubrange(Offset.bytes..<(Offset.bytes + data.count), with: data)
        let output = try call(input)
        guard output[Offset.result] == 0 else { throw Failure.result(key: key, code: output[Offset.result]) }
    }

    /// A number in the key's own format.
    static func encode(_ value: Double, type: String) -> [UInt8]? {
        switch type {
        case "flt ": return withUnsafeBytes(of: Float(value)) { Array($0) }
        case "fpe2":
            let raw = UInt16(max(min(value * 4, 65535), 0))
            return [UInt8(raw >> 8), UInt8(raw & 0xFF)]
        case "ui8 ", "flag": return [UInt8(max(min(value, 255), 0))]
        case "ui16":
            let raw = UInt16(max(min(value, 65535), 0))
            return [UInt8(raw >> 8), UInt8(raw & 0xFF)]
        default: return nil
        }
    }

    /// The fan's mode key; a few Macs spell it in lower case.
    static func modeKey(_ fan: Int, on smc: SMC) -> String? {
        for key in ["F\(fan)Md", "F\(fan)md"] where smc.has(key) { return key }
        return nil
    }
}
