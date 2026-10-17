// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Compression
import Foundation

enum WebExtensionArchiveError: LocalizedError {
    case notAnArchive
    case unsupportedCompression(String)
    case corruptEntry(String)
    case unsafePath(String)

    var errorDescription: String? {
        switch self {
        case .notAnArchive:
            return "This file isn't a valid extension package (.xpi, .zip or .crx)."
        case .unsupportedCompression(let name):
            return "\(name) uses a compression method Culpeo can't read."
        case .corruptEntry(let name):
            return "\(name) inside the package is damaged."
        case .unsafePath(let name):
            return "The package contains an unsafe path: \(name)"
        }
    }
}

/// Minimal ZIP reader for extension packages. Supports stored and deflated entries, which covers
/// every package published on addons.mozilla.org and the Chrome Web Store. CRX headers are stripped.
struct WebExtensionArchive {
    struct Entry {
        let path: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    let data: Data
    let entries: [Entry]

    init(data rawData: Data) throws {
        let data = WebExtensionArchive.stripCRXHeader(rawData)
        self.data = data
        self.entries = try WebExtensionArchive.readCentralDirectory(data)
    }

    /// Extracts every file into `directory`, refusing paths that would escape it.
    func extract(to directory: URL) throws {
        let fileManager = FileManager.default
        let root = directory.standardizedFileURL.path
        for entry in entries {
            let cleanPath = entry.path.replacingOccurrences(of: "\\", with: "/")
            guard !cleanPath.hasPrefix("/"), !cleanPath.split(separator: "/").contains("..") else {
                throw WebExtensionArchiveError.unsafePath(entry.path)
            }
            let destination = directory.appendingPathComponent(cleanPath).standardizedFileURL
            guard destination.path.hasPrefix(root) else {
                throw WebExtensionArchiveError.unsafePath(entry.path)
            }
            if cleanPath.hasSuffix("/") {
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
                continue
            }
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            try contents(of: entry).write(to: destination, options: .atomic)
        }
    }

    func contents(of entry: Entry) throws -> Data {
        let offset = entry.localHeaderOffset
        guard offset + 30 <= data.count, data.readUInt32(at: offset) == 0x04034b50 else {
            throw WebExtensionArchiveError.corruptEntry(entry.path)
        }
        let nameLength = Int(data.readUInt16(at: offset + 26))
        let extraLength = Int(data.readUInt16(at: offset + 28))
        let start = offset + 30 + nameLength + extraLength
        let end = start + entry.compressedSize
        guard end <= data.count else { throw WebExtensionArchiveError.corruptEntry(entry.path) }
        let compressed = data.subdata(in: start..<end)

        switch entry.method {
        case 0:
            return compressed
        case 8:
            return try WebExtensionArchive.inflate(compressed, expectedSize: entry.uncompressedSize, name: entry.path)
        default:
            throw WebExtensionArchiveError.unsupportedCompression(entry.path)
        }
    }

    private static func stripCRXHeader(_ data: Data) -> Data {
        // "Cr24" magic
        guard data.count > 16, data.readUInt32(at: 0) == 0x34327243 else { return data }
        let version = data.readUInt32(at: 4)
        if version == 3 {
            let headerSize = Int(data.readUInt32(at: 8))
            let start = 12 + headerSize
            return start < data.count ? data.subdata(in: start..<data.count) : data
        }
        if version == 2 {
            let keyLength = Int(data.readUInt32(at: 8))
            let signatureLength = Int(data.readUInt32(at: 12))
            let start = 16 + keyLength + signatureLength
            return start < data.count ? data.subdata(in: start..<data.count) : data
        }
        return data
    }

    private static func readCentralDirectory(_ data: Data) throws -> [Entry] {
        guard data.count >= 22 else { throw WebExtensionArchiveError.notAnArchive }
        // Find the End Of Central Directory record, scanning back over a possible comment.
        var eocd = -1
        let lowerBound = max(0, data.count - 22 - 65_535)
        var index = data.count - 22
        while index >= lowerBound {
            if data.readUInt32(at: index) == 0x06054b50 {
                eocd = index
                break
            }
            index -= 1
        }
        guard eocd >= 0 else { throw WebExtensionArchiveError.notAnArchive }

        let entryCount = Int(data.readUInt16(at: eocd + 10))
        var cursor = Int(data.readUInt32(at: eocd + 16))
        var entries: [Entry] = []
        entries.reserveCapacity(entryCount)

        for _ in 0..<entryCount {
            guard cursor + 46 <= data.count, data.readUInt32(at: cursor) == 0x02014b50 else {
                throw WebExtensionArchiveError.notAnArchive
            }
            let method = data.readUInt16(at: cursor + 10)
            let compressedSize = Int(data.readUInt32(at: cursor + 20))
            let uncompressedSize = Int(data.readUInt32(at: cursor + 24))
            let nameLength = Int(data.readUInt16(at: cursor + 28))
            let extraLength = Int(data.readUInt16(at: cursor + 30))
            let commentLength = Int(data.readUInt16(at: cursor + 32))
            let localOffset = Int(data.readUInt32(at: cursor + 42))
            let nameStart = cursor + 46
            guard nameStart + nameLength <= data.count else { throw WebExtensionArchiveError.notAnArchive }
            let nameData = data.subdata(in: nameStart..<(nameStart + nameLength))
            let name = String(data: nameData, encoding: .utf8) ?? String(decoding: nameData, as: UTF8.self)
            entries.append(Entry(path: name,
                                 method: method,
                                 compressedSize: compressedSize,
                                 uncompressedSize: uncompressedSize,
                                 localHeaderOffset: localOffset))
            cursor = nameStart + nameLength + extraLength + commentLength
        }
        return entries
    }

    private static func inflate(_ input: Data, expectedSize: Int, name: String) throws -> Data {
        if expectedSize == 0 { return Data() }
        var output = Data(count: expectedSize)
        let written = output.withUnsafeMutableBytes { (outBuffer: UnsafeMutableRawBufferPointer) -> Int in
            input.withUnsafeBytes { (inBuffer: UnsafeRawBufferPointer) -> Int in
                guard let outBase = outBuffer.bindMemory(to: UInt8.self).baseAddress,
                      let inBase = inBuffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(outBase, expectedSize, inBase, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expectedSize else { throw WebExtensionArchiveError.corruptEntry(name) }
        return output
    }
}

private extension Data {
    func readUInt16(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        let base = startIndex + offset
        return UInt16(self[base]) | (UInt16(self[base + 1]) << 8)
    }

    func readUInt32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        let base = startIndex + offset
        return UInt32(self[base])
            | (UInt32(self[base + 1]) << 8)
            | (UInt32(self[base + 2]) << 16)
            | (UInt32(self[base + 3]) << 24)
    }
}
