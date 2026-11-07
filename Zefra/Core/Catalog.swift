import Foundation

/// Turns raw sensor names into something readable. Apple doesn't publish what these names mean and
/// they change between Macs, so only families are named here, with the raw key always shown beside
/// them. The user can rename any sensor.
enum Catalog {
    struct Entry: Equatable {
        var group: SensorGroup
        var name: String
        var countsTowardHottest: Bool
    }

    /// Readings outside this aren't temperatures, whatever their name says.
    static let plausible = 10.0...125.0

    static func isPlausible(_ value: Double) -> Bool { value.isFinite && plausible.contains(value) }

    /// What kind of Mac this is, for the keys that mean different things.
    struct Chip: Equatable, Sendable {
        /// "m4Pro", "m1", or "intel".
        var tag: String
        var isIntel: Bool { tag == "intel" }

        /// From `machdep.cpu.brand_string`: "Apple M4 Pro" becomes "m4Pro".
        init(brand: String) {
            let words = brand.split(separator: " ")
            guard words.first == "Apple", words.count >= 2 else {
                tag = "intel"
                return
            }
            tag = words[1].lowercased() + words.dropFirst(2).map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined()
        }

        init(tag: String) { self.tag = tag }

        /// Whether a row of the table covers this chip.
        func matches(_ rowTag: String) -> Bool {
            if rowTag == "all" { return true }
            if rowTag == "apple" { return !isIntel }
            if rowTag.hasSuffix("*") {
                let generation = rowTag.dropLast()
                guard tag.hasPrefix(generation) else { return false }
                // "m1*" covers m1Pro but not, say, a future m10.
                let rest = tag.dropFirst(generation.count)
                return rest.first.map { !$0.isNumber } ?? true
            }
            return rowTag == tag
        }
    }

    /// The community's name for this key on this chip, when there is one.
    static func knownName(forSMCKey key: String, chip: Chip) -> String? {
        var fallback: String?
        for row in KnownSensors.rows where row.tags.contains(where: chip.matches) {
            if row.key == key {
                // A row for this very chip beats one for every Mac.
                if row.tags.contains(where: { $0 != "all" && $0 != "apple" }) { return row.name }
                fallback = fallback ?? row.name
            } else if fallback == nil, row.key.contains("%"), row.key.count == key.count {
                let digit = zip(row.key, key).first { $0.0 == "%" }?.1
                let fits = zip(row.key, key).allSatisfy { $0.0 == "%" ? $0.1.isNumber : $0.0 == $0.1 }
                if fits, let digit { fallback = row.name.replacingOccurrences(of: "%", with: String(digit)) }
            }
        }
        return fallback
    }

    /// A four-letter SMC key. nil when it isn't a temperature worth showing.
    static func entry(forSMCKey key: String, chip: Chip = Chip(tag: "m4Pro")) -> Entry? {
        guard key.count == 4, key.hasPrefix("T") else { return nil }
        guard var entry = family(of: key, chip: chip) else { return nil }
        // The community's TG rows are Intel GPUs. On Apple silicon those keys are the battery's gauges.
        if chip.isIntel || !key.hasPrefix("TG"), let known = knownName(forSMCKey: key, chip: chip) { entry.name = known }
        return entry
    }

    private static func family(of key: String, chip: Chip) -> Entry? {
        let prefix = String(key.prefix(2))
        if chip.isIntel {
            switch prefix {
            case "TC": return Entry(group: .cpuPerformance, name: "CPU \(key)", countsTowardHottest: true)
            case "TG": return Entry(group: .gpu, name: "GPU \(key)", countsTowardHottest: true)
            case "TB": return Entry(group: .battery, name: "Battery \(key)", countsTowardHottest: true)
            case "TH": return Entry(group: .storage, name: "Drive \(key)", countsTowardHottest: true)
            case "TM", "Tm": return Entry(group: .memory, name: "Memory \(key)", countsTowardHottest: true)
            case "TW": return Entry(group: .wireless, name: "Wi-Fi \(key)", countsTowardHottest: true)
            case "TV", "Tp", "TP": return Entry(group: .power, name: "Power \(key)", countsTowardHottest: true)
            default: return Entry(group: .board, name: "Board \(key)", countsTowardHottest: false)
            }
        }
        switch prefix {
        case "TC": return Entry(group: .cpuPerformance, name: "CPU \(key)", countsTowardHottest: true)
        case "Tp": return Entry(group: .cpuPerformance, name: "Performance core \(key)", countsTowardHottest: true)
        case "Te": return Entry(group: .cpuEfficiency, name: "Efficiency core \(key)", countsTowardHottest: true)
        case "Tg": return Entry(group: .gpu, name: "GPU \(key)", countsTowardHottest: true)
        case "TG": return Entry(group: .battery, name: "Battery gauge \(key)", countsTowardHottest: false)
        case "TB": return Entry(group: .battery, name: "Battery \(key)", countsTowardHottest: true)
        case "TH": return Entry(group: .storage, name: "SSD \(key)", countsTowardHottest: true)
        case "Tm": return Entry(group: .memory, name: "Memory \(key)", countsTowardHottest: true)
        case "TW": return Entry(group: .wireless, name: "Wi-Fi \(key)", countsTowardHottest: true)
        case "TP", "TR", "TU": return Entry(group: .power, name: "Power die \(key)", countsTowardHottest: true)
        case "TM": return Entry(group: .power, name: "Regulator \(key)", countsTowardHottest: true)
        // These read near 100° at idle and hold still: limits or targets rather than parts of the
        // machine. They stay visible, but never decide what "hottest" is.
        case "TV": return Entry(group: .power, name: "Reference \(key)", countsTowardHottest: false)
        case "Ts":
            // Ts0P and Ts1P sit near room temperature, unlike the rest of the family.
            if key.hasSuffix("P") { return Entry(group: .board, name: "Case \(key)", countsTowardHottest: false) }
            return Entry(group: .soc, name: "SoC \(key)", countsTowardHottest: true)
        default: return Entry(group: .board, name: "Board \(key)", countsTowardHottest: false)
        }
    }

    /// A name from the HID sensor list. nil for the ones that aren't temperatures of anything useful.
    static func entry(forHIDName name: String, hasSMC: Bool) -> Entry? {
        let lower = name.lowercased()
        if lower.contains("tdev") || lower.contains("tcal") { return nil }
        if lower.contains("nand") || lower.contains("ssd") { return Entry(group: .storage, name: name, countsTowardHottest: true) }
        if lower.contains("battery") || lower.contains("gas gauge") { return Entry(group: .battery, name: name, countsTowardHottest: false) }
        // The SMC already reports these dies, under names of its own.
        if lower.contains("tdie") { return hasSMC ? nil : Entry(group: .power, name: name, countsTowardHottest: true) }
        return hasSMC ? nil : Entry(group: .board, name: name, countsTowardHottest: false)
    }
}
