import Foundation
import CryptoKit

guard CommandLine.arguments.count == 2 else {
    print("Usage: printf '%s' '<private_key_base64>' | swift sign_update.swift <file_path>")
    exit(1)
}

let filePath = CommandLine.arguments[1]
let keyBase64 = String(
    data: FileHandle.standardInput.readDataToEndOfFile(),
    encoding: .utf8
)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

guard !keyBase64.isEmpty else {
    print("Error: Missing private key on stdin")
    exit(1)
}

guard let data = FileManager.default.contents(atPath: filePath) else {
    print("Error: Could not read file at \(filePath)")
    exit(1)
}

guard let keyData = Data(base64Encoded: keyBase64) else {
    print("Error: Invalid base64 key")
    exit(1)
}

do {
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
    let signature = try key.signature(for: data)
    print(signature.base64EncodedString())
} catch {
    print("Error: Signing failed - \(error)")
    exit(1)
}
