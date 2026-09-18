import CryptoKit
import Foundation

@_cdecl("BolemeVerifyEd25519")
public func BolemeVerifyEd25519(
    _ message: UnsafePointer<UInt8>?,
    _ messageLength: Int,
    _ signature: UnsafePointer<UInt8>?,
    _ signatureLength: Int,
    _ publicKey: UnsafePointer<UInt8>?,
    _ publicKeyLength: Int
) -> Bool {
    guard
        let message,
        let signature,
        let publicKey,
        messageLength >= 0,
        signatureLength == 64,
        publicKeyLength == 32
    else {
        return false
    }

    do {
        let messageData = Data(bytes: message, count: messageLength)
        let signatureData = Data(bytes: signature, count: signatureLength)
        let keyData = Data(bytes: publicKey, count: publicKeyLength)
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        return key.isValidSignature(signatureData, for: messageData)
    } catch {
        return false
    }
}
