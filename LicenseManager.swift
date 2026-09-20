import Combine
import CryptoKit
import Foundation

struct ProLicensePayload: Codable, Equatable {
    let id: UUID
    let name: String
    let issuedAt: Date
}

enum ProLicenseVerifier {
    static func verify(serial rawSerial: String, publicKeyBase64: String) -> ProLicensePayload? {
        let serial = rawSerial.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = serial.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "ANVX1",
              let payloadData = Data(base64URL: String(parts[1])),
              let signature = Data(base64URL: String(parts[2])),
              let publicKeyData = Data(base64Encoded: publicKeyBase64),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData),
              publicKey.isValidSignature(signature, for: payloadData),
              let payload = try? JSONDecoder.licenseDecoder.decode(ProLicensePayload.self, from: payloadData),
              !payload.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return payload
    }
}

@MainActor
final class ProLicenseManager: ObservableObject {
    @Published private(set) var license: ProLicensePayload?
    @Published private(set) var validationMessage: String?

    var isProUnlocked: Bool { license != nil }

    private static let storedSerialKey = "anonvox.proLicense.v1"
    private static let publicKeyBase64 = "68xD5lBMAvO0Jnlfvsuhzh1EN4QYSbFChbpDVLeu4ew="

    init(defaults: UserDefaults = .standard) {
        guard let serial = defaults.string(forKey: Self.storedSerialKey) else { return }
        license = ProLicenseVerifier.verify(serial: serial, publicKeyBase64: Self.publicKeyBase64)
        if license == nil { defaults.removeObject(forKey: Self.storedSerialKey) }
    }

    @discardableResult
    func activate(serial: String, defaults: UserDefaults = .standard) -> Bool {
        guard let payload = ProLicenseVerifier.verify(serial: serial,
                                                       publicKeyBase64: Self.publicKeyBase64) else {
            validationMessage = "That serial number is not valid. Check the complete code and try again."
            return false
        }
        defaults.set(serial.trimmingCharacters(in: .whitespacesAndNewlines),
                     forKey: Self.storedSerialKey)
        license = payload
        validationMessage = "Pro mode unlocked for \(payload.name)."
        return true
    }

    func deactivate(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: Self.storedSerialKey)
        license = nil
        validationMessage = nil
    }
}

extension Data {
    init?(base64URL: String) {
        var base64 = base64URL.replacingOccurrences(of: "-", with: "+")
                              .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }

    var base64URLString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension JSONDecoder {
    static var licenseDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

