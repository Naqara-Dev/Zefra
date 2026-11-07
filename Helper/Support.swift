import CommonCrypto
import Dispatch
import Foundation

nonisolated(unsafe) var signalSources: [DispatchSourceSignal] = []

enum SHA1 {
    /// The hash a code-signing requirement names a certificate by.
    static func hex(of data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA1($0.baseAddress, CC_LONG(data.count), &digest) }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
