import Foundation
import Security

func require(_ status: OSStatus, _ operation: String) {
    guard status == errSecSuccess else {
        fputs("\(operation) failed: \(status)\n", stderr)
        exit(1)
    }
}

var keychain: SecKeychain?
require(SecKeychainOpen(CommandLine.arguments[1], &keychain), "Open runner keychain")
let query: [String: Any] = [
    kSecClass as String: kSecClassIdentity,
    kSecReturnRef as String: true,
    kSecMatchLimit as String: kSecMatchLimitAll,
    kSecMatchSearchList as String: [keychain!],
]
var result: CFTypeRef?
require(SecItemCopyMatching(query as CFDictionary, &result), "Find runner identities")
for identity in result as! [SecIdentity] {
    var certificate: SecCertificate?
    require(SecIdentityCopyCertificate(identity, &certificate), "Read identity certificate")
    var name: CFString?
    require(SecCertificateCopyCommonName(certificate!, &name), "Read certificate name")
    guard (name! as String).hasPrefix("Apple Development:") else { continue }
    var privateKey: SecKey?
    require(SecIdentityCopyPrivateKey(identity, &privateKey), "Read identity key reference")
    var error: Unmanaged<CFError>?
    let input = Data("heavy-gate signing probe".utf8) as CFData
    guard let signature = SecKeyCreateSignature(privateKey!, .rsaSignatureMessagePKCS1v15SHA256, input, &error) else {
        fputs("Raw key signature failed: \(String(describing: error?.takeRetainedValue()))\n", stderr)
        exit(1)
    }
    guard let publicKey = SecCertificateCopyKey(certificate!),
          SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, input, signature, &error) else {
        fputs("Signature does not verify against the certificate\n", stderr)
        exit(1)
    }
    print("Raw key signature verified against development certificate")
    exit(0)
}
fputs("Development identity not found\n", stderr)
exit(1)
