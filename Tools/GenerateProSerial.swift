import CryptoKit
import Foundation

struct Payload: Codable {
    let id: UUID
    let name: String
    let issuedAt: Date
}

func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: swift Tools/GenerateProSerial.swift PRIVATE_KEY_FILE CUSTOMER_NAME\n".utf8))
    exit(2)
}

let keyText = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
guard let firstLine = keyText.split(whereSeparator: \.isNewline).first,
      let keyData = Data(base64Encoded: String(firstLine)),
      let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData) else {
    FileHandle.standardError.write(Data("invalid private key file\n".utf8))
    exit(2)
}

let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601
encoder.outputFormatting = [.sortedKeys]
let payload = Payload(id: UUID(), name: CommandLine.arguments[2], issuedAt: Date())
let payloadData = try encoder.encode(payload)
let signature = try privateKey.signature(for: payloadData)
print("ANVX1.\(base64URL(payloadData)).\(base64URL(signature))")

