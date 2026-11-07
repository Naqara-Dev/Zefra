import Foundation
import Security

/// The email password, in the Keychain and nowhere else.
enum MailPassword {
    private static let service = "com.naqara.zefra.mail"

    static func read(account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ password: String, account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        guard !password.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = Data(password.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// Sends mail with the curl macOS ships, which already knows SMTP, STARTTLS and every server's quirks.
enum Mailer {
    /// nil on success, or what went wrong. Blocks; call it off the main actor.
    static func send(settings: MailSettings, password: String?, subject: String, body: String, extraConfig: String = "") -> String? {
        guard var config = Mail.curlConfig(settings, password: password), let from = Mail.address(settings.from), let to = Mail.address(settings.to) else {
            return "The email settings aren't complete."
        }
        config += extraConfig
        let message = Mail.message(from: from, to: to, subject: subject, body: body, date: .now)
        // Two things to hand over: the settings on stdin, the message through a private file.
        let folder = FileManager.default.temporaryDirectory.appending(path: "zefra-mail-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appending(path: "message.eml")
            try Data(message.utf8).write(to: file)
            config = config.replacingOccurrences(of: "upload-file = \"-\"", with: "upload-file = \(Mail.curlQuoted(file.path))")
            let curl = Process()
            curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            curl.arguments = ["--config", "-"]
            let input = Pipe(), errors = Pipe()
            curl.standardInput = input
            curl.standardOutput = FileHandle.nullDevice
            curl.standardError = errors
            try curl.run()
            input.fileHandleForWriting.write(Data(config.utf8))
            try input.fileHandleForWriting.close()
            let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            curl.waitUntilExit()
            guard curl.terminationStatus != 0 else { return nil }
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "The server didn't take it." : text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return error.localizedDescription
        }
    }

    /// What's sent with every alert: which Mac, and what happened.
    static func body(_ text: String) -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var raw = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &raw, &size, nil, 0)
        let model = String(decoding: raw.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return """
        \(text)

        Mac: \(model)
        Name: \(ProcessInfo.processInfo.hostName)
        macOS: \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)
        Time: \(Date.now.formatted(date: .abbreviated, time: .standard))
        """
    }
}
