@preconcurrency import CloudKit
import Foundation

let cloudContainerID = "iCloud.com.eminaydin.maccommand"

struct CloudMailbox: Sendable {
    static let recordType = "MacCommandJob"
    private static let assetKeys = ["part0", "part1"]
    let deviceID: String
    private var database: CKDatabase { CKContainer(identifier: cloudContainerID).privateCloudDatabase }
    private var zone: CKRecordZone.ID { CKRecordZone.ID(zoneName: "maccommand-" + deviceID) }

    func id(_ job: String) -> CKRecord.ID { CKRecord.ID(recordName: job, zoneID: zone) }

    func prepare() async throws {
        do { _ = try await database.recordZone(for: zone) }
        catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem {
            _ = try await database.save(CKRecordZone(zoneID: zone))
        }
    }

    private func putAssets(_ urls: [URL], in record: CKRecord) {
        for (index, key) in Self.assetKeys.enumerated() {
            record[key] = index < urls.count ? CKAsset(fileURL: urls[index]) : nil
        }
    }

    func assetURLs(_ record: CKRecord) -> [URL] {
        Self.assetKeys.compactMap { (record[$0] as? CKAsset)?.fileURL }
    }

    func submit(_ job: String, assets: [URL]) async throws {
        let record = CKRecord(recordType: Self.recordType, recordID: id(job))
        record["state"] = "queued"
        record["purgeAt"] = Date().addingTimeInterval(900)
        putAssets(assets, in: record)
        _ = try await database.save(record)
    }

    func awaitReply(_ job: String, timeout: Duration) async throws -> CKRecord {
        let limit = ContinuousClock.now.advanced(by: timeout)
        let recordID = id(job)
        while ContinuousClock.now < limit {
            try Task.checkCancellation()
            let records = try await database.records(for: [recordID], desiredKeys: ["state"])
            guard let status = try records[recordID]?.get() else { throw MacError.invalidResponse }
            switch status["state"] as? String {
            case "done":
                return try await database.record(for: recordID)
            case "failed":
                throw MacError.http(502, "Mac isteği tamamlayamadı.")
            default:
                try await Task.sleep(for: .seconds(3))
            }
        }
        throw MacError.http(503, "Mac zamanında yanıt vermedi. Yeniden göndermeden önce Mac’te işlemin durumunu kontrol et.")
    }

    func queued() async throws -> [CKRecord.ID] {
        let query = CKQuery(recordType: Self.recordType, predicate: NSPredicate(format: "state == %@", "queued"))
        let results = try await database.records(matching: query, inZoneWith: zone, desiredKeys: ["state"], resultsLimit: 8)
        return results.matchResults.compactMap { id, result in
            if case .success = result { return id }
            return nil
        }
    }

    func take(_ recordID: CKRecord.ID, folder: URL) async throws -> (CKRecord, [URL])? {
        let record = try await database.record(for: recordID)
        guard record["state"] as? String == "queued" else { return nil }
        let sources = assetURLs(record)
        guard (1...2).contains(sources.count) else { throw MacError.invalidResponse }
        let paths = try sources.enumerated().map { index, source in
            let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard (1...cloudAssetLimit).contains(size) else { throw MacError.invalidResponse }
            let destination = folder.appendingPathComponent("input-\(index).packet")
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        }
        record["state"] = "working"
        let result = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
        guard let saved = try result.saveResults[recordID]?.get() else { throw MacError.invalidResponse }
        return (saved, paths)
    }

    func finish(_ record: CKRecord, assets: [URL]) async throws {
        record["state"] = assets.isEmpty ? "failed" : "done"
        putAssets(assets, in: record)
        let result = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
        guard try result.saveResults[record.recordID]?.get() != nil else { throw MacError.invalidResponse }
    }

    func delete(_ job: String) async throws { _ = try await database.deleteRecord(withID: id(job)) }

    func purgeExpired() async throws {
        let query = CKQuery(recordType: Self.recordType, predicate: NSPredicate(format: "purgeAt < %@", Date() as NSDate))
        let results = try await database.records(matching: query, inZoneWith: zone, desiredKeys: [], resultsLimit: 32)
        let ids = results.matchResults.map(\.0)
        if !ids.isEmpty {
            _ = try await database.modifyRecords(saving: [], deleting: ids, savePolicy: .ifServerRecordUnchanged, atomically: false)
        }
    }

    static func explain(_ error: Error) -> Error {
        guard let error = error as? CKError else { return error }
        switch error.code {
        case .notAuthenticated:
            return MacError.http(503, "Mac ve iPhone’da aynı iCloud hesabıyla giriş yap.")
        case .zoneNotFound, .unknownItem:
            return MacError.http(503, "Mac’in iCloud eşleştirmesi bulunamadı. MacCommand’i Mac’te aç.")
        case .badContainer, .missingEntitlement, .permissionFailure:
            return MacError.http(503, "Bu sürümün iCloud erişimi hazır değil.")
        case .quotaExceeded:
            return MacError.http(507, "iCloud’da bu aktarım için yer kalmadı.")
        default:
            return MacError.http(503, "iCloud bağlantısı geçici olarak kullanılamıyor. İşlemin durumunu kontrol et.")
        }
    }
}

let cloudAssetLimit = 38 * 1024 * 1024

final class CloudPacketWriter {
    private let folder: URL
    private var handle: FileHandle?
    private var size = 0
    private(set) var urls: [URL] = []

    init(folder: URL) { self.folder = folder }
    deinit { try? handle?.close() }

    func append(_ frame: Data) throws {
        let count = frame.count + 4
        if handle == nil || size + count > cloudAssetLimit {
            try close()
            guard urls.count < 2 else { throw MacError.invalidResponse }
            let url = folder.appendingPathComponent("request-\(urls.count).packet")
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            else { throw CocoaError(.fileWriteUnknown) }
            handle = try FileHandle(forWritingTo: url)
            urls.append(url)
            size = 0
        }
        var length = UInt32(frame.count).bigEndian
        try handle?.write(contentsOf: withUnsafeBytes(of: &length) { Data($0) })
        try handle?.write(contentsOf: frame)
        size += count
    }

    func close() throws {
        try handle?.close()
        handle = nil
    }
}

actor CloudPacketReader {
    private var urls: ArraySlice<URL>
    private var handle: FileHandle?

    init(urls: [URL]) throws {
        guard (1...2).contains(urls.count) else { throw MacError.invalidResponse }
        for url in urls {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard (1...cloudAssetLimit).contains(size) else { throw MacError.invalidResponse }
        }
        self.urls = urls[...]
    }

    func next() throws -> Data {
        while true {
            try Task.checkCancellation()
            if handle == nil {
                guard let url = urls.popFirst() else { throw MacError.invalidResponse }
                handle = try FileHandle(forReadingFrom: url)
            }
            if let prefix = try handle?.read(upToCount: 4), !prefix.isEmpty {
                guard prefix.count == 4 else { throw MacError.invalidResponse }
                let size = prefix.reduce(0) { ($0 << 8) | Int($1) }
                guard (36...RelayCipher.maxPlaintext + 36).contains(size),
                      let frame = try handle?.read(upToCount: size), frame.count == size else {
                    throw MacError.invalidResponse
                }
                return frame
            }
            try handle?.close()
            handle = nil
        }
    }
}
