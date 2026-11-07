import Foundation

/// Builds an alert email and the settings curl needs to send it. Everything that came from a person
/// is cleaned here: a line break in a subject would let it write extra headers.
enum Mail {
    /// One header line's worth: control characters out.
    static func clean(_ text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
            .trimmingCharacters(in: .whitespaces)
    }

    /// A bare address, or nil when it isn't one. No spaces, no brackets, one @.
    static func address(_ text: String) -> String? {
        let cleaned = clean(text)
        let parts = cleaned.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
              cleaned.rangeOfCharacter(from: CharacterSet(charactersIn: " <>\"\\,;:()[]")) == nil else { return nil }
        return cleaned
    }

    /// Non-ASCII subjects need RFC 2047 encoding.
    static func encodedHeader(_ text: String) -> String {
        let cleaned = clean(text)
        if cleaned.utf8.allSatisfy({ $0 < 128 }) { return cleaned }
        return "=?UTF-8?B?\(Data(cleaned.utf8).base64EncodedString())?="
    }

    static func message(from: String, to: String, subject: String, body: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let lines = body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            // A line of just a dot ends the message in SMTP, unless it's doubled.
            .map { $0.hasPrefix(".") ? "." + $0 : $0 }
        return [
            "From: Zefra <\(clean(from))>",
            "To: <\(clean(to))>",
            "Subject: \(encodedHeader(subject))",
            "Date: \(formatter.string(from: date))",
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=utf-8",
            "Content-Transfer-Encoding: 8bit",
            "",
        ].joined(separator: "\r\n") + "\r\n" + lines.joined(separator: "\r\n") + "\r\n"
    }

    /// A value for a curl config file, in double quotes with its own quoting.
    static func curlQuoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "") + "\""
    }

    /// curl's settings. They go in on stdin, so the password never shows up in a process list.
    static func curlConfig(_ mail: MailSettings, password: String?) -> String? {
        guard mail.isComplete, let from = address(mail.from), let to = address(mail.to) else { return nil }
        let host = clean(mail.host)
        guard host.rangeOfCharacter(from: CharacterSet(charactersIn: " /:@\\\"")) == nil else { return nil }
        let scheme = mail.security == .tls ? "smtps" : "smtp"
        var lines = [
            "url = \(curlQuoted("\(scheme)://\(host):\(mail.port)"))",
            "mail-from = \(curlQuoted(from))",
            "mail-rcpt = \(curlQuoted(to))",
            "upload-file = \"-\"",
            "silent",
            "show-error",
            "max-time = 30",
        ]
        // Never in the clear: STARTTLS has to succeed or nothing is sent.
        lines.append("ssl-reqd")
        if mail.usesPassword, !mail.username.isEmpty {
            lines.append("user = \(curlQuoted("\(mail.username):\(password ?? "")"))")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
