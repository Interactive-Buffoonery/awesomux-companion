import CryptoKit
import Foundation
import os
import Security

/// The phone's TLS client identity: a P-256 key, a self-signed certificate for it, and the
/// `SecIdentity` the Keychain forms from the two. The Mac pins the certificate's SPKI fingerprint.
struct PhoneIdentity: @unchecked Sendable {
    enum Storage: String, Codable, Sendable {
        /// Non-exportable key generated inside the Secure Enclave.
        case secureEnclave
        /// Software key in the Keychain, this device only, readable after first unlock.
        case keychain
    }

    enum Failure: Error { case keyGeneration(String), certificate(String), keychain(OSStatus), identityUnavailable }

    let tag: String
    let storage: Storage
    let identity: SecIdentity
    /// DER SubjectPublicKeyInfo of the phone key; hashed into the confirmation words and the Mac's pin.
    let spki: Data

    private static let log = Logger(subsystem: "com.interactivebuffoonery.awesomux.companion", category: "identity")
    private static let tagPrefix = "com.interactivebuffoonery.awesomux.companion.identity."

    /// Creates a fresh identity, preferring the Secure Enclave and falling back to a Keychain key
    /// when the enclave is missing (Simulator) or its key can't form a signing identity.
    static func create() throws -> PhoneIdentity {
        let tag = tagPrefix + UUID().uuidString.lowercased()
        #if !targetEnvironment(simulator)
        if SecureEnclave.isAvailable {
            do {
                return try make(tag: tag, storage: .secureEnclave)
            } catch {
                log.error("Secure Enclave identity failed, falling back to Keychain: \(String(describing: error), privacy: .public)")
                try? delete(tag: tag)
            }
        }
        #endif
        do {
            return try make(tag: tag, storage: .keychain)
        } catch {
            try? delete(tag: tag)
            throw error
        }
    }

    static func load(tag: String, storage: Storage) throws -> PhoneIdentity {
        guard tag.hasPrefix(tagPrefix) else { throw Failure.identityUnavailable }
        let identity = try copyIdentity(tag: tag)
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate,
              let spki = DER.subjectPublicKeyInfo(ofCertificate: SecCertificateCopyData(certificate) as Data)
        else { throw Failure.identityUnavailable }
        return PhoneIdentity(tag: tag, storage: storage, identity: identity, spki: spki)
    }

    static func delete(tag: String) throws {
        guard tag.hasPrefix(tagPrefix) else { throw Failure.identityUnavailable }
        let keyStatus = SecItemDelete([kSecClass: kSecClassKey, kSecAttrApplicationTag: Data(tag.utf8)] as CFDictionary)
        let certificateStatus = SecItemDelete([kSecClass: kSecClassCertificate, kSecAttrLabel: tag] as CFDictionary)
        for status in [keyStatus, certificateStatus] where status != errSecSuccess && status != errSecItemNotFound {
            throw Failure.keychain(status)
        }
    }

    private static func make(tag: String, storage: Storage) throws -> PhoneIdentity {
        var attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
        ]
        var keyAttributes: [CFString: Any] = [
            kSecAttrIsPermanent: true,
            kSecAttrApplicationTag: Data(tag.utf8),
            kSecAttrLabel: tag,
        ]
        switch storage {
        case .secureEnclave:
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(
                nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage, &error) else {
                throw Failure.keyGeneration(error.map { String(describing: $0.takeRetainedValue()) } ?? "access control")
            }
            attributes[kSecAttrTokenID] = kSecAttrTokenIDSecureEnclave
            keyAttributes[kSecAttrAccessControl] = access
        case .keychain:
            keyAttributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        attributes[kSecPrivateKeyAttrs] = keyAttributes

        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw Failure.keyGeneration(error.map { String(describing: $0.takeRetainedValue()) } ?? "unknown")
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let point = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?, point.count == 65 else {
            throw Failure.keyGeneration("public key")
        }
        let spki = DER.p256SubjectPublicKeyInfo(point: point)
        let certificateDER = try selfSignedCertificate(spki: spki, privateKey: privateKey)
        guard let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData) else {
            throw Failure.certificate("Security rejected the certificate DER")
        }
        let status = SecItemAdd([
            kSecClass: kSecClassCertificate,
            kSecValueRef: certificate,
            kSecAttrLabel: tag,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ] as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }

        // The Keychain only forms an identity when the stored certificate's public key hash matches a stored
        // private key; then prove that identity's key can sign the way TLS 1.3 asks (ECDSA P-256, SHA-256).
        let identity = try copyIdentity(tag: tag)
        var identityKey: SecKey?
        guard SecIdentityCopyPrivateKey(identity, &identityKey) == errSecSuccess, let identityKey,
              SecKeyIsAlgorithmSupported(identityKey, .sign, .ecdsaSignatureDigestX962SHA256),
              SecKeyCreateSignature(identityKey, .ecdsaSignatureDigestX962SHA256,
                                    Data(SHA256.hash(data: certificateDER)) as CFData, nil) != nil else {
            throw Failure.identityUnavailable
        }
        log.notice("Created \(storage.rawValue, privacy: .public) phone identity")
        return PhoneIdentity(tag: tag, storage: storage, identity: identity, spki: spki)
    }

    private static func copyIdentity(tag: String) throws -> SecIdentity {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassIdentity,
            kSecAttrLabel: tag,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ] as CFDictionary, &result)
        guard status == errSecSuccess, let result, CFGetTypeID(result) == SecIdentityGetTypeID() else {
            throw status == errSecSuccess ? Failure.identityUnavailable : Failure.keychain(status)
        }
        return result as! SecIdentity
    }

    /// A minimal X.509 v3 certificate: CN=awesoMux Companion, self-issued, ECDSA with SHA-256.
    private static func selfSignedCertificate(spki: Data, privateKey: SecKey) throws -> Data {
        let algorithm = DER.sequence([DER.oid([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02])]) // ecdsa-with-SHA256
        let name = DER.sequence([DER.set([DER.sequence([
            DER.oid([0x55, 0x04, 0x03]), // commonName
            DER.utf8String("awesoMux Companion"),
        ])])])
        let now = Date.now
        var serial = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, serial.count, &serial) == errSecSuccess else {
            throw Failure.certificate("serial")
        }
        serial[0] &= 0x7F // keep the INTEGER positive
        let tbs = DER.sequence([
            DER.contextConstructed(0, DER.integer([2])), // v3
            DER.integer(serial),
            algorithm,
            name,
            DER.sequence([DER.utcTime(now - 86_400), DER.utcTime(now + 20 * 365 * 86_400)]),
            name,
            spki,
        ])
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(privateKey, .ecdsaSignatureMessageX962SHA256, tbs as CFData, &error) as Data? else {
            throw Failure.certificate(error.map { String(describing: $0.takeRetainedValue()) } ?? "signature")
        }
        return DER.sequence([tbs, algorithm, DER.bitString(signature)])
    }
}

/// Just enough DER to write one certificate and read the SPKI back out of another.
enum DER {
    static func p256SubjectPublicKeyInfo(point: Data) -> Data {
        sequence([
            sequence([
                oid([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]), // id-ecPublicKey
                oid([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]), // prime256v1
            ]),
            bitString(point),
        ])
    }

    static func sequence(_ parts: [Data]) -> Data { element(0x30, parts.reduce(Data(), +)) }
    static func set(_ parts: [Data]) -> Data { element(0x31, parts.reduce(Data(), +)) }
    static func oid(_ bytes: [UInt8]) -> Data { element(0x06, Data(bytes)) }
    static func integer(_ bytes: [UInt8]) -> Data { element(0x02, Data(bytes)) }
    static func utf8String(_ text: String) -> Data { element(0x0C, Data(text.utf8)) }
    static func bitString(_ bytes: Data) -> Data { element(0x03, Data([0]) + bytes) }
    static func contextConstructed(_ number: UInt8, _ content: Data) -> Data { element(0xA0 | number, content) }

    static func utcTime(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        return element(0x17, Data(formatter.string(from: date).utf8))
    }

    static func element(_ tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        let count = content.count
        if count < 0x80 {
            out.append(UInt8(count))
        } else {
            let bytes = withUnsafeBytes(of: UInt32(count).bigEndian, Array.init).drop { $0 == 0 }
            out.append(0x80 | UInt8(bytes.count))
            out.append(contentsOf: bytes)
        }
        return out + content
    }

    /// The SubjectPublicKeyInfo element of an X.509 certificate, header included.
    static func subjectPublicKeyInfo(ofCertificate der: Data) -> Data? {
        var reader = Reader(Array(der))
        guard let certificate = reader.next(), certificate.tag == 0x30 else { return nil }
        var certificateReader = Reader(certificate.content)
        guard let tbs = certificateReader.next(), tbs.tag == 0x30 else { return nil }
        var fields = Reader(tbs.content)
        var index = 0
        while let field = fields.next() {
            // [0] version is optional; SPKI is the sixth field after it (serial, alg, issuer, validity, subject).
            if index == 0 && field.tag == 0xA0 { continue }
            if index == 5 { return field.tag == 0x30 ? Data(field.raw) : nil }
            index += 1
        }
        return nil
    }

    private struct Reader {
        struct Element { let tag: UInt8; let content: [UInt8]; let raw: [UInt8] }
        private let bytes: [UInt8]
        private var offset = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func next() -> Element? {
            let start = offset
            guard offset + 2 <= bytes.count else { return nil }
            let tag = bytes[offset]
            var length = Int(bytes[offset + 1])
            offset += 2
            if length & 0x80 != 0 {
                let count = length & 0x7F
                guard (1...4).contains(count), offset + count <= bytes.count else { return nil }
                length = bytes[offset..<offset + count].reduce(0) { $0 << 8 | Int($1) }
                offset += count
            }
            guard length >= 0, offset + length <= bytes.count else { return nil }
            defer { offset += length }
            return Element(tag: tag, content: Array(bytes[offset..<offset + length]), raw: Array(bytes[start..<offset + length]))
        }
    }
}
