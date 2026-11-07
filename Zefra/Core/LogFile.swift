import Foundation

/// Where a log row goes and what it says.
enum LogFile {
    /// `2026-11-07` in the Mac's own time zone.
    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func name(schedule: LogSchedule, dated: Bool, launch: Date, now: Date, calendar: Calendar = .current) -> String {
        switch schedule {
        case .daily:
            // A new file each day needs the date, whatever the setting says.
            return "Zefra Log \(day(now, calendar: calendar)).csv"
        case .eachLaunch:
            guard dated else { return "Zefra Log.csv" }
            let parts = calendar.dateComponents([.hour, .minute, .second], from: launch)
            return String(format: "Zefra Log %@ %02d%02d%02d.csv", day(launch, calendar: calendar), parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
        case .append:
            return dated ? "Zefra Log \(day(launch, calendar: calendar)).csv" : "Zefra Log.csv"
        }
    }

    static func header(fans: [Int]) -> String {
        (["time", "hottest", "cpu", "cpu_average", "gpu", "ssd", "battery"] + fans.map { "fan\($0)_rpm" } + ["watts", "rules"]).joined(separator: ",") + "\n"
    }

    /// One row. `alert` marks a reading past the failsafe or a rule that's telling someone; the rule
    /// names go in quotes, because a name can hold a comma.
    static func row(time: String, values: [Double?], rules: [String], alert: Bool) -> String {
        let cells = values.map { $0.map { String(format: "%.1f", $0) } ?? "" }
        let names = "\"" + rules.joined(separator: "; ").replacingOccurrences(of: "\"", with: "\"\"") + "\""
        return (alert ? "ALERT: " : "") + ([time] + cells + [names]).joined(separator: ",") + "\n"
    }
}
