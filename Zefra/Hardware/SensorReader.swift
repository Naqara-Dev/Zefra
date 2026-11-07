import Foundation
import IOKit
import IOKit.ps

@_silgen_name("IOHIDEventSystemClientCreate") private func IOHIDEventSystemClientCreate(_: CFAllocator?) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventSystemClientSetMatching") private func IOHIDEventSystemClientSetMatching(_: AnyObject, _: CFDictionary) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices") private func IOHIDEventSystemClientCopyServices(_: AnyObject) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyProperty") private func IOHIDServiceClientCopyProperty(_: UnsafeRawPointer, _: CFString) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDServiceClientCopyEvent") private func IOHIDServiceClientCopyEvent(_: UnsafeRawPointer, _: Int64, _: Int32, _: Int64) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventGetFloatValue") private func IOHIDEventGetFloatValue(_: UnsafeRawPointer, _: Int32) -> Double

/// One reading of the whole machine.
struct MachineSample: Sendable {
    var temps: TempSnapshot
    var fans: [RawFan]
    var battery: BatteryInfo?
    var power: PowerSource
    /// The whole Mac, in watts, when it reports it.
    var systemWatts: Double?
    var cpuLoad: Double?
    var thermal: ThermalLevel
    var readsSMC: Bool
    var drives: [DriveHealth] = []
    var flaggedFans: [Int] = []
}

struct RawFan: Sendable {
    var index: Int
    var rpm: Double
    var minRPM: Double
    var maxRPM: Double
    var target: Double
    var mode: Int
}

/// Reads sensors, fans, battery and load. Reads only; it has no way to change anything.
actor SensorReader {
    private var smc: SMC?
    private var smcTemps: [(key: String, entry: Catalog.Entry)] = []
    private var fanCount = 0
    private var hidClient: AnyObject?
    private var previousTicks: (busy: UInt64, total: UInt64)?
    private var drives: [DriveHealth] = []
    private var drivesRead = Date.distantPast
    /// SMART changes slowly, and waking a drive to ask isn't free.
    private static let driveInterval: TimeInterval = 60

    static var chip: Catalog.Chip {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var raw = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &raw, &size, nil, 0)
        return Catalog.Chip(brand: String(decoding: raw.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }

    private func prepare() {
        guard smc == nil else { return }
        smc = try? SMC()
        guard let smc else { return }
        fanCount = Int(smc.number("FNum") ?? 0)
        let chip = Self.chip
        for key in smc.allKeys() {
            guard let entry = Catalog.entry(forSMCKey: key, chip: chip), let value = smc.number(key), Catalog.isPlausible(value) else { continue }
            smcTemps.append((key, entry))
        }
        smcTemps.sort { $0.key < $1.key }
    }

    func sample() -> MachineSample {
        prepare()
        var readings: [SensorReading] = []
        if let smc {
            for (key, entry) in smcTemps {
                guard let value = smc.number(key), Catalog.isPlausible(value) else { continue }
                readings.append(SensorReading(id: "smc:\(key)", key: key, name: entry.name, group: entry.group, value: value,
                                              countsTowardHottest: entry.countsTowardHottest))
            }
        }
        readings += hidReadings(hasSMC: !readings.isEmpty)
        if Date.now.timeIntervalSince(drivesRead) >= Self.driveInterval {
            drivesRead = .now
            drives = DriveReader.read()
        }
        for drive in drives {
            guard let temp = drive.temperature, Catalog.isPlausible(temp) else { continue }
            readings.append(SensorReading(id: "smart:\(drive.name)", key: "SMART", name: drive.name + (drive.isInternal ? "" : " (external)"), group: .storage,
                                          value: temp, countsTowardHottest: true))
        }
        return MachineSample(temps: TempSnapshot(readings: readings), fans: fans(), battery: Self.battery(), power: Self.powerSource(),
                             systemWatts: smc?.number("PSTR").flatMap { $0 > 0 && $0 < 1000 ? $0 : nil }, cpuLoad: cpuLoad(),
                             thermal: Self.thermal(), readsSMC: smc != nil, drives: drives, flaggedFans: flaggedFans())
    }

    /// The SMC's own mask of fans it considers bad, on the Macs that have one.
    private func flaggedFans() -> [Int] {
        guard let smc, smc.has("FBAD"), let mask = (try? smc.bytes("FBAD"))?.first, mask != 0 else { return [] }
        return (0..<fanCount).filter { mask & (1 << UInt8(min($0, 7))) != 0 }
    }

    private func fans() -> [RawFan] {
        guard let smc else { return [] }
        return (0..<fanCount).compactMap { index in
            guard let maxRPM = smc.number("F\(index)Mx"), maxRPM > 0 else { return nil }
            let mode = SMC.modeKey(index, on: smc).flatMap { smc.number($0) } ?? 0
            return RawFan(index: index, rpm: smc.number("F\(index)Ac") ?? 0, minRPM: smc.number("F\(index)Mn") ?? 0, maxRPM: maxRPM,
                          target: smc.number("F\(index)Tg") ?? 0, mode: Int(mode))
        }
    }

    /// The private list macOS keeps of its own temperature sensors: storage and battery come from here.
    private func hidReadings(hasSMC: Bool) -> [SensorReading] {
        if hidClient == nil {
            hidClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault)?.takeRetainedValue()
            if let hidClient { _ = IOHIDEventSystemClientSetMatching(hidClient, ["PrimaryUsagePage": 0xFF00, "PrimaryUsage": 5] as CFDictionary) }
        }
        guard let hidClient, let services = IOHIDEventSystemClientCopyServices(hidClient)?.takeRetainedValue() as? [AnyObject] else { return [] }
        var seen: [String: Int] = [:]
        var found: [SensorReading] = []
        for service in services {
            let pointer = Unmanaged.passUnretained(service).toOpaque()
            guard let name = IOHIDServiceClientCopyProperty(pointer, "Product" as CFString)?.takeRetainedValue() as? String,
                  let entry = Catalog.entry(forHIDName: name, hasSMC: hasSMC),
                  let event = IOHIDServiceClientCopyEvent(pointer, 15, 0, 0)?.takeRetainedValue() else { continue }
            let value = IOHIDEventGetFloatValue(Unmanaged.passUnretained(event).toOpaque(), 15 << 16)
            guard Catalog.isPlausible(value) else { continue }
            // Several sensors can share a name.
            let count = seen[name, default: 0] + 1
            seen[name] = count
            let key = count == 1 ? name : "\(name) \(count)"
            found.append(SensorReading(id: "hid:\(key)", key: key, name: count == 1 ? entry.name : "\(entry.name) \(count)", group: entry.group,
                                       value: value, countsTowardHottest: entry.countsTowardHottest))
        }
        return found.sorted { $0.id < $1.id }
    }

    private func cpuLoad() -> Double? {
        var info: processor_info_array_t?
        var count: mach_msg_type_number_t = 0
        var cpus: natural_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpus, &info, &count) == KERN_SUCCESS, let info else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.stride)) }
        var busy: UInt64 = 0, total: UInt64 = 0
        for cpu in 0..<Int(cpus) {
            let base = cpu * Int(CPU_STATE_MAX)
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            busy += user + system + nice
            total += user + system + nice + idle
        }
        defer { previousTicks = (busy, total) }
        guard let previous = previousTicks, total > previous.total else { return nil }
        return Double(busy - previous.busy) / Double(total - previous.total) * 100
    }

    private static func thermal() -> ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .nominal
        }
    }

    private static func powerSource() -> PowerSource {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String? else { return .adapter }
        return type == kIOPSBatteryPowerValue ? .battery : .adapter
    }

    /// macOS's own word on the battery, when it has one to say.
    private static func systemBatteryCondition() -> String? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any] else { continue }
            if let condition = description[kIOPSBatteryHealthConditionKey] as? String { return condition }
        }
        return nil
    }

    private static func battery() -> BatteryInfo? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = unmanaged?.takeRetainedValue() as? [String: Any],
              let design = properties["DesignCapacity"] as? Int, design > 0 else { return nil }
        let maxCapacity = (properties["AppleRawMaxCapacity"] as? Int) ?? (properties["NominalChargeCapacity"] as? Int) ?? 0
        let current = (properties["AppleRawCurrentCapacity"] as? Int) ?? 0
        // Amperage comes as an unsigned value that's really signed.
        let amps = (properties["Amperage"] as? Int) ?? 0
        let temperature = (properties["Temperature"] as? Int).map { Double($0) / 100 }
        return BatteryInfo(percent: maxCapacity > 0 ? min(Double(current) / Double(maxCapacity) * 100, 100) : 0,
                           cycles: (properties["CycleCount"] as? Int) ?? 0, designCycles: (properties["DesignCycleCount9C"] as? Int) ?? 0,
                           designCapacity: Double(design), maxCapacity: Double(maxCapacity), temperature: temperature,
                           volts: Double((properties["Voltage"] as? Int) ?? 0) / 1000, amps: Double(amps) / 1000,
                           isCharging: (properties["IsCharging"] as? Bool) ?? false,
                           onAdapter: (properties["ExternalConnected"] as? Bool) ?? false,
                           systemCondition: systemBatteryCondition(),
                           permanentFailure: ((properties["PermanentFailureStatus"] as? Int) ?? 0) != 0)
    }
}
