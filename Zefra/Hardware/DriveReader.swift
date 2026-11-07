import Foundation
import IOKit

/// Reads NVMe drives' SMART data through macOS's own plug-in. No special rights needed, and it only
/// reads. Drives behind a USB bridge usually don't pass SMART through, and macOS offers no way to
/// read SATA SMART without a driver, so those simply don't show up here.
enum DriveReader {
    private static func uuid(_ b: [UInt8]) -> CFUUID {
        CFUUIDGetConstantUUIDWithBytes(nil, b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])
    }

    private static var userClientType: CFUUID { uuid([0xAA, 0x0F, 0xA6, 0xF9, 0xC2, 0xD6, 0x45, 0x7F, 0xB1, 0x0B, 0x59, 0xA1, 0x32, 0x53, 0x29, 0x2F]) }
    private static var smartInterface: CFUUID { uuid([0xCC, 0xD1, 0xDB, 0x19, 0xFD, 0x9A, 0x4D, 0xAF, 0xBF, 0x95, 0x12, 0x45, 0x4B, 0x23, 0x0A, 0xB6]) }
    private static var plugInInterface: CFUUID { uuid([0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4, 0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F]) }

    /// In the plug-in's table: four IUnknown slots, two 16-bit version fields padded to eight bytes,
    /// and then the function that reads the log.
    private enum Table {
        static let release = 24
        static let readSMART = 40
    }

    static func read() -> [DriveHealth] {
        var iterator: io_iterator_t = 0
        let matching = ["IOPropertyMatch": ["NVMe SMART Capable": true]] as CFDictionary
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var drives: [DriveHealth] = []
        var names: [String: Int] = [:]
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var unmanaged: Unmanaged<CFMutableDictionary>?
            IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0)
            let properties = unmanaged?.takeRetainedValue() as? [String: Any] ?? [:]
            var name = ((properties["Device Characteristics"] as? [String: Any])?["Product Name"] as? String)?
                .trimmingCharacters(in: .whitespaces) ?? "Drive"
            let count = names[name, default: 0] + 1
            names[name] = count
            if count > 1 { name += " \(count)" }
            let location = (properties["Protocol Characteristics"] as? [String: Any])?["Physical Interconnect Location"] as? String
            guard let log = smartLog(of: service),
                  let drive = DriveHealth(name: name, isInternal: location != "External", log: log) else { continue }
            drives.append(drive)
        }
        return drives
    }

    private static func smartLog(of service: io_service_t) -> [UInt8]? {
        var plugin: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        guard IOCreatePlugInInterfaceForService(service, userClientType, plugInInterface, &plugin, &score) == KERN_SUCCESS,
              let plugin, let table = plugin.pointee else { return nil }
        defer { _ = table.pointee.Release(plugin) }
        var raw: LPVOID?
        guard table.pointee.QueryInterface(plugin, CFUUIDGetUUIDBytes(smartInterface), &raw) == 0, let interface = raw else { return nil }
        let functions = interface.assumingMemoryBound(to: UnsafeRawPointer.self).pointee
        defer {
            let release = unsafeBitCast(functions.load(fromByteOffset: Table.release, as: UnsafeRawPointer.self),
                                        to: (@convention(c) (UnsafeMutableRawPointer) -> UInt32).self)
            _ = release(interface)
        }
        let read = unsafeBitCast(functions.load(fromByteOffset: Table.readSMART, as: UnsafeRawPointer.self),
                                 to: (@convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> Int32).self)
        var log = [UInt8](repeating: 0, count: 512)
        let status = log.withUnsafeMutableBytes { read(interface, $0.baseAddress!) }
        return status == 0 ? log : nil
    }

    /// The newest panic report macOS has written, by name.
    static func newestPanicReport() -> String? {
        let folder = "/Library/Logs/DiagnosticReports"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        let reports = names.filter { $0.hasSuffix(".panic") }
        return reports.max { a, b in
            let da = (try? FileManager.default.attributesOfItem(atPath: "\(folder)/\(a)")[.modificationDate] as? Date) ?? .distantPast
            let db = (try? FileManager.default.attributesOfItem(atPath: "\(folder)/\(b)")[.modificationDate] as? Date) ?? .distantPast
            return da < db
        }
    }
}
