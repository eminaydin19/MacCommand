import Foundation
import CryptoKit

struct RelayFrame: Codable, Sendable {
    var kind: String
    var method: String? = nil
    var path: String? = nil
    var query: String? = nil
    var length: Int? = nil
    var status: Int? = nil
    var headers: [String:String]? = nil
    var data: String? = nil
    var message: String? = nil
    var deadline: Int? = nil
}

struct RelayCipher: Sendable {
    static let chunkSize = 48 * 1024
    static let maxPlaintext = 96 * 1024
    private let key: SymmetricKey
    private let prefix: String
    private var sequence: UInt64 = 0

    static func channelKey(_ key: Data, requestID: String, challenge: String) throws -> Data {
        guard key.count == 32,
              requestID.range(of: #"\A[a-f0-9]{32}\z"#, options: .regularExpression) != nil,
              challenge.range(of: #"\A[a-f0-9]{32}\z"#, options: .regularExpression) != nil else { throw MacError.invalidResponse }
        let bytes = Array(challenge.utf8)
        let salt = try Data(stride(from: 0, to: bytes.count, by: 2).map { index in
            guard let byte = UInt8(String(decoding: bytes[index...index+1], as: UTF8.self), radix: 16) else {
                throw MacError.invalidResponse
            }
            return byte
        })
        let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: key),
            salt: salt, info: Data("MacCommand.relay.channel.v1|\(requestID)".utf8), outputByteCount: 32)
        return derived.withUnsafeBytes { Data($0) }
    }

    init(key: Data, requestID: String, direction: String) throws {
        guard key.count == 32,
              requestID.range(of:#"\A[a-f0-9]{32}\z"#,options:.regularExpression) != nil,
              ["request","response"].contains(direction) else { throw MacError.invalidResponse }
        self.key = SymmetricKey(data:key)
        prefix = "MacCommand.relay.v1|\(requestID)|\(direction)|"
    }
    mutating func seal(_ value: RelayFrame) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let plain = try encoder.encode(value)
        guard plain.count <= Self.maxPlaintext, sequence < UInt64.max else { throw MacError.invalidResponse }
        let box = try AES.GCM.seal(plain, using:key, authenticating:Data((prefix + String(sequence)).utf8))
        var bigEndian = sequence.bigEndian
        var frame = withUnsafeBytes(of:&bigEndian) { Data($0) }
        frame.append(contentsOf:box.nonce)
        frame.append(box.ciphertext)
        frame.append(box.tag)
        sequence += 1
        return frame
    }
    mutating func open(_ frame: Data) throws -> RelayFrame {
        guard (36...Self.maxPlaintext+36).contains(frame.count), sequence < UInt64.max else { throw MacError.invalidResponse }
        let index = frame.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard index == sequence else { throw MacError.invalidResponse }
        do {
            let box = try AES.GCM.SealedBox(nonce:AES.GCM.Nonce(data:frame.dropFirst(8).prefix(12)),
                ciphertext:frame.dropFirst(20).dropLast(16), tag:frame.suffix(16))
            let plain = try AES.GCM.open(box,using:key,authenticating:Data((prefix + String(sequence)).utf8))
            let value = try JSONDecoder().decode(RelayFrame.self,from:plain)
            guard ["head","data","end","error"].contains(value.kind) else { throw MacError.invalidResponse }
            sequence += 1
            return value
        } catch { throw MacError.invalidResponse }
    }
}
