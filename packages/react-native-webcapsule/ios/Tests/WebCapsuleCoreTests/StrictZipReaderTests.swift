import Foundation
import XCTest
@testable import WebCapsuleCore

final class StrictZipReaderTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testParsesCLIProducedFixtureAndExtractsBoundedMetadataAndContent() throws {
        let reader = try StrictZipReader(archiveURL: fixture("valid-minimal"))
        XCTAssertEqual(reader.entries.map(\.name), ["capsule.json", "capsule.sig", "files/index.html"])
        XCTAssertEqual(reader.entries.map(\.compressionMethod), [8, 8, 8])
        XCTAssertEqual(reader.entries.map(\.flags), [0x0800, 0x0800, 0x0808])

        let manifest = try reader.extractData(reader.entries[0], maximumSize: 5 * 1024 * 1024)
        let signature = try reader.extractData(reader.entries[1], maximumSize: 89)
        XCTAssertTrue(String(decoding: manifest, as: UTF8.self).hasSuffix("\n"))
        XCTAssertEqual(signature.count, 89)
        XCTAssertTrue(String(decoding: signature, as: UTF8.self).hasSuffix("\n"))

        let directory = try temporaryDirectory()
        let output = directory.appendingPathComponent("content")
        let observed = try reader.extract(reader.entries[2], to: output, maximumSize: 50 * 1024 * 1024)
        XCTAssertEqual(observed.size, 6)
        XCTAssertEqual(observed.crc32, reader.entries[2].crc32)
        XCTAssertEqual(try Data(contentsOf: output), Data("hello\n".utf8))
    }

    func testMatchesExistingMaliciousFixtureErrorCodesAtArchiveLayer() throws {
        let cases: [(String, WebCapsuleErrorCode)] = [
            ("local-central-filename-mismatch", .invalidArchiveProfile),
            ("raw-backslash", .invalidArchiveProfile),
            ("path-traversal", .invalidArchiveProfile),
            ("ascii-case-collision", .caseCollision),
            ("non-nfc", .invalidPath),
            ("encrypted-bit", .invalidArchiveProfile),
            ("unsupported-flags", .invalidArchiveProfile),
            ("archive-comment", .invalidArchiveProfile),
            ("entry-comment", .invalidArchiveProfile),
            ("central-extra", .invalidArchiveProfile),
            ("local-extra", .invalidArchiveProfile),
            ("wrong-mode", .invalidArchiveProfile),
            ("nonunix-mode", .invalidArchiveProfile),
            ("symlink-mode", .invalidArchiveProfile),
            ("fifo-mode", .invalidArchiveProfile),
            ("store-method", .invalidArchiveProfile),
            ("timestamp-mismatch", .invalidArchiveProfile),
        ]
        for (name, code) in cases {
            assertError(code, label: name) {
                try StrictZipReader(archiveURL: fixture(name))
            }
        }
    }

    func testEnforcesArchiveSizeEntryCountAndMetadataOrder() throws {
        let url = fixture("valid-minimal")
        let size = try Data(contentsOf: url).count
        assertError(.limitExceeded) {
            try StrictZipReader(archiveURL: url, archiveSizeLimit: UInt64(size - 1))
        }
        assertError(.limitExceeded) {
            try StrictZipReader(archiveURL: url, entryCountLimit: 2)
        }

        var bytes = try Data(contentsOf: url)
        let first = try zipRecords(bytes)[0]
        replace(bytes: &bytes, at: first.centralName, with: Data("capsule.sigx".utf8))
        replace(bytes: &bytes, at: first.localName, with: Data("capsule.sigx".utf8))
        assertArchiveError(.invalidOrder, bytes: bytes)
    }

    func testRejectsTruncatedAndInvalidBinaryStructures() throws {
        let original = try Data(contentsOf: fixture("valid-minimal"))
        let records = try zipRecords(original)
        let eocd = try eocdOffset(original)
        let mutations: [(String, (inout Data) -> Void, WebCapsuleErrorCode)] = [
            ("missing EOCD", { $0.removeSubrange(eocd..<$0.count) }, .archiveInvalid),
            ("truncated EOCD", { $0.removeLast(1) }, .invalidArchiveProfile),
            ("bad central signature", { set32(&$0, records[0].central, 0, 0) }, .archiveInvalid),
            ("bad local signature", { set32(&$0, records[0].local, 0, 0) }, .archiveInvalid),
            ("truncated local header", {
                set32(&$0, records[0].central, 42, UInt32(original.count - 10))
            }, .archiveInvalid),
            ("truncated compressed data", {
                set32(&$0, records[0].central, 20, UInt32(original.count))
                set32(&$0, records[0].local, 18, UInt32(original.count))
            }, .archiveInvalid),
            ("central size mismatch", { set32(&$0, eocd, 12, 1) }, .archiveInvalid),
            ("central offset out of bounds", { set32(&$0, eocd, 16, UInt32.max - 1) }, .archiveInvalid),
        ]
        for (name, mutate, code) in mutations {
            var bytes = original
            mutate(&bytes)
            assertArchiveError(code, bytes: bytes, label: name)
        }
    }

    func testRejectsZIP64CommentsMultiDiskAndForbiddenCentralMetadata() throws {
        let original = try Data(contentsOf: fixture("valid-minimal"))
        let records = try zipRecords(original)
        let eocd = try eocdOffset(original)
        let mutations: [(String, (inout Data) -> Void)] = [
            ("disk", { set16(&$0, eocd, 4, 1) }),
            ("central disk", { set16(&$0, eocd, 6, 1) }),
            ("disk count", { set16(&$0, eocd, 8, 1) }),
            ("entry count sentinel", { set16(&$0, eocd, 10, UInt16.max) }),
            ("central size sentinel", { set32(&$0, eocd, 12, UInt32.max) }),
            ("central offset sentinel", { set32(&$0, eocd, 16, UInt32.max) }),
            ("entry compressed sentinel", { set32(&$0, records[0].central, 20, UInt32.max) }),
            ("entry expanded sentinel", { set32(&$0, records[0].central, 24, UInt32.max) }),
            ("entry local offset sentinel", { set32(&$0, records[0].central, 42, UInt32.max) }),
            ("entry disk start", { set16(&$0, records[0].central, 34, 1) }),
            ("entry comment", { set16(&$0, records[0].central, 32, 1) }),
            ("entry central extra", { set16(&$0, records[0].central, 30, 1) }),
            ("version needed ZIP64", { set16(&$0, records[0].central, 6, 45) }),
        ]
        for (name, mutate) in mutations {
            var bytes = original
            mutate(&bytes)
            assertArchiveError(.invalidArchiveProfile, bytes: bytes, label: name)
        }

        var locator = original
        let oldEOCD = try eocdOffset(locator)
        locator.insert(contentsOf: [0x50, 0x4B, 0x06, 0x07] + Array(repeating: 0, count: 16), at: oldEOCD)
        assertArchiveError(.invalidArchiveProfile, bytes: locator, label: "ZIP64 locator")
    }

    func testRejectsUnsupportedFlagsMethodsModesAndDirectories() throws {
        let original = try Data(contentsOf: fixture("valid-minimal"))
        let record = try zipRecords(original)[2]
        let mutations: [(String, (inout Data) -> Void)] = [
            ("encrypted", {
                set16(&$0, record.central, 8, 0x0801)
                set16(&$0, record.local, 6, 0x0801)
            }),
            ("unsupported flag", {
                set16(&$0, record.central, 8, 0x0802)
                set16(&$0, record.local, 6, 0x0802)
            }),
            ("STORE", {
                set16(&$0, record.central, 10, 0)
                set16(&$0, record.local, 8, 0)
            }),
            ("non-Unix", { set16(&$0, record.central, 4, 20) }),
            ("wrong permissions", { set32(&$0, record.central, 38, 0o100600 << 16) }),
            ("directory mode", { set32(&$0, record.central, 38, 0o040755 << 16) }),
            ("symlink mode", { set32(&$0, record.central, 38, 0o120644 << 16) }),
            ("FIFO mode", { set32(&$0, record.central, 38, 0o010644 << 16) }),
        ]
        for (name, mutate) in mutations {
            var bytes = original
            mutate(&bytes)
            assertArchiveError(.invalidArchiveProfile, bytes: bytes, label: name)
        }

        var directoryName = original
        replace(bytes: &directoryName, at: record.centralName, with: Data("files/index.htm/".utf8))
        replace(bytes: &directoryName, at: record.localName, with: Data("files/index.htm/".utf8))
        assertArchiveError(.invalidArchiveProfile, bytes: directoryName, label: "directory name")
    }

    func testRejectsInvalidUTF8UnsafePathsDuplicatesAndCaseCollisions() throws {
        let original = try Data(contentsOf: fixture("valid-minimal"))
        let record = try zipRecords(original)[2]

        var invalidUTF8 = original
        invalidUTF8[record.centralName + 6] = 0xFF
        invalidUTF8[record.localName + 6] = 0xFF
        assertArchiveError(.invalidPath, bytes: invalidUTF8)

        var backslash = original
        replace(bytes: &backslash, at: record.centralName, with: Data("files\\index.html".utf8))
        replace(bytes: &backslash, at: record.localName, with: Data("files\\index.html".utf8))
        assertArchiveError(.invalidArchiveProfile, bytes: backslash)

        var traversal = original
        replace(bytes: &traversal, at: record.centralName, with: Data("files/../evil.tx".utf8))
        replace(bytes: &traversal, at: record.localName, with: Data("files/../evil.tx".utf8))
        assertArchiveError(.invalidArchiveProfile, bytes: traversal)

        var duplicate = try Data(contentsOf: fixture("ascii-case-collision"))
        let duplicateRecords = try zipRecords(duplicate)
        replace(bytes: &duplicate, at: duplicateRecords[3].centralName, with: Data("files/index.html".utf8))
        replace(bytes: &duplicate, at: duplicateRecords[3].localName, with: Data("files/index.html".utf8))
        assertArchiveError(.duplicatePath, bytes: duplicate)

        assertError(.caseCollision) {
            try StrictZipReader(archiveURL: fixture("ascii-case-collision"))
        }
        assertError(.invalidPath) {
            try StrictZipReader(archiveURL: fixture("non-nfc"))
        }
    }

    func testRejectsEveryLocalCentralMismatchClass() throws {
        let original = try Data(contentsOf: fixture("valid-minimal"))
        let record = try zipRecords(original)[0]
        var localVersionDifference = original
        set16(&localVersionDifference, record.local, 4, 19)
        XCTAssertNoThrow(try StrictZipReader(archiveURL: temporaryArchive(localVersionDifference)))

        let mutations: [(String, (inout Data) -> Void)] = [
            ("flags", { set16(&$0, record.local, 6, 0x0808) }),
            ("method", { set16(&$0, record.local, 8, 0) }),
            ("time", { set16(&$0, record.local, 10, 0) }),
            ("date", { set16(&$0, record.local, 12, 0) }),
            ("CRC", { set32(&$0, record.local, 14, 0) }),
            ("compressed size", { set32(&$0, record.local, 18, 0) }),
            ("expanded size", { set32(&$0, record.local, 22, 0) }),
            ("name length", { set16(&$0, record.local, 26, 1) }),
            ("local extra", { set16(&$0, record.local, 28, 1) }),
        ]
        for (name, mutate) in mutations {
            var bytes = original
            mutate(&bytes)
            assertArchiveError(.invalidArchiveProfile, bytes: bytes, label: name)
        }

        var name = original
        name[record.localName] ^= 0x20
        assertArchiveError(.invalidArchiveProfile, bytes: name, label: "name")
    }

    func testEnforcesSignedDataDescriptorContract() throws {
        let original = try Data(contentsOf: fixture("valid-minimal"))
        let record = try zipRecords(original)[2]
        XCTAssertEqual(record.flags, 0x0808)
        let descriptor = record.data + Int(record.compressedSize)

        let mutations: [(String, (inout Data) -> Void)] = [
            ("local CRC nonzero", { set32(&$0, record.local, 14, 1) }),
            ("local compressed nonzero", { set32(&$0, record.local, 18, 1) }),
            ("local expanded nonzero", { set32(&$0, record.local, 22, 1) }),
            ("descriptor signature omitted", { set32(&$0, descriptor, 0, record.crc32) }),
            ("descriptor CRC", { set32(&$0, descriptor, 4, record.crc32 ^ 1) }),
            ("descriptor compressed size", { set32(&$0, descriptor, 8, record.compressedSize + 1) }),
            ("descriptor expanded size", { set32(&$0, descriptor, 12, record.uncompressedSize + 1) }),
        ]
        for (name, mutate) in mutations {
            var bytes = original
            mutate(&bytes)
            assertArchiveError(.invalidArchiveProfile, bytes: bytes, label: name)
        }
    }

    func testRejectsPrependedTrailingAmbiguousGapOverlapAndCentralIntrusionBytes() throws {
        let original = try Data(contentsOf: fixture("valid-minimal"))
        let records = try zipRecords(original)

        var trailing = original
        trailing.append(0)
        assertArchiveError(.invalidArchiveProfile, bytes: trailing, label: "trailing byte")

        var ambiguous = original
        let marker = Data([0x50, 0x4B, 0x05, 0x06])
        ambiguous.replaceSubrange(records[2].data..<(records[2].data + 4), with: marker)
        assertArchiveError(.archiveInvalid, bytes: ambiguous, label: "ambiguous EOCD")

        let prepended = try insertingGap(original, at: 0, updateShiftedLocalOffsets: true)
        assertArchiveError(.invalidArchiveProfile, bytes: prepended, label: "prepended byte")

        let localGap = try insertingGap(original, at: records[1].local, updateShiftedLocalOffsets: true)
        assertArchiveError(.invalidArchiveProfile, bytes: localGap, label: "local gap")

        let centralGap = try insertingGap(original, at: records[0].central, updateShiftedLocalOffsets: false)
        assertArchiveError(.invalidArchiveProfile, bytes: centralGap, label: "central gap")

        var overlap = original
        set32(&overlap, records[1].central, 42, UInt32(records[0].local))
        assertArchiveError(.invalidArchiveProfile, bytes: overlap, label: "overlap")

        var intrusion = original
        let eocd = try eocdOffset(intrusion)
        set32(&intrusion, eocd, 16, UInt32(records[0].central - 1))
        set32(&intrusion, eocd, 12, UInt32(intrusion.count - 22 - (records[0].central - 1)))
        assertArchiveError(.archiveInvalid, bytes: intrusion, label: "central intrusion")
    }

    func testBoundedExtractionRejectsLimitCRCSizeAndCorruptDeflate() throws {
        let validReader = try StrictZipReader(archiveURL: fixture("valid-minimal"))
        assertError(.limitExceeded) {
            try validReader.extractData(validReader.entries[2], maximumSize: 5)
        }

        let original = try Data(contentsOf: fixture("valid-minimal"))
        let metadata = try zipRecords(original)[0]
        var crcMismatch = original
        set32(&crcMismatch, metadata.central, 16, metadata.crc32 ^ 1)
        set32(&crcMismatch, metadata.local, 14, metadata.crc32 ^ 1)
        let crcReader = try StrictZipReader(archiveURL: temporaryArchive(crcMismatch))
        assertError(.archiveInvalid) {
            try crcReader.extractData(crcReader.entries[0], maximumSize: 5 * 1024 * 1024)
        }

        let content = try zipRecords(original)[2]
        let descriptor = content.data + Int(content.compressedSize)
        var sizeMismatch = original
        set32(&sizeMismatch, content.central, 24, content.uncompressedSize + 1)
        set32(&sizeMismatch, descriptor, 12, content.uncompressedSize + 1)
        let sizeReader = try StrictZipReader(archiveURL: temporaryArchive(sizeMismatch))
        assertError(.archiveInvalid) {
            try sizeReader.extractData(sizeReader.entries[2], maximumSize: 50 * 1024 * 1024)
        }

        var corrupt = original
        corrupt[content.data + Int(content.compressedSize / 2)] ^= 0xFF
        let corruptReader = try StrictZipReader(archiveURL: temporaryArchive(corrupt))
        assertError(.archiveInvalid) {
            try corruptReader.extractData(corruptReader.entries[2], maximumSize: 50 * 1024 * 1024)
        }
    }

    func testOutputExtractionNeverOverwritesAndCleansItsPartialFile() throws {
        let reader = try StrictZipReader(archiveURL: fixture("valid-minimal"))
        let otherReader = try StrictZipReader(archiveURL: fixture("valid-minimal"))
        assertError(.invalidArgument) {
            try reader.extractData(otherReader.entries[2], maximumSize: 50 * 1024 * 1024)
        }

        let directory = try temporaryDirectory()
        let existing = directory.appendingPathComponent("existing")
        try Data("keep".utf8).write(to: existing)
        assertError(.storageIOFailed) {
            try reader.extract(reader.entries[2], to: existing, maximumSize: 50 * 1024 * 1024)
        }
        XCTAssertEqual(try Data(contentsOf: existing), Data("keep".utf8))

        var corrupt = try Data(contentsOf: fixture("valid-minimal"))
        let content = try zipRecords(corrupt)[2]
        corrupt[content.data + Int(content.compressedSize / 2)] ^= 0xFF
        let corruptReader = try StrictZipReader(archiveURL: temporaryArchive(corrupt))
        let partial = directory.appendingPathComponent("partial")
        assertError(.archiveInvalid) {
            try corruptReader.extract(
                corruptReader.entries[2],
                to: partial,
                maximumSize: 50 * 1024 * 1024
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    private func fixture(_ name: String) -> URL {
        repositoryRoot
            .appendingPathComponent("fixtures/capsules", isDirectory: true)
            .appendingPathComponent("\(name).capsule")
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("webcapsule-zip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        temporaryDirectories.append(url)
        return url
    }

    private func temporaryArchive(_ bytes: Data) throws -> URL {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("fixture.capsule")
        try bytes.write(to: url)
        return url
    }

    private func assertArchiveError(
        _ code: WebCapsuleErrorCode,
        bytes: Data,
        label: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertError(code, label: label, file: file, line: line) {
            try StrictZipReader(archiveURL: temporaryArchive(bytes))
        }
    }

    private func assertError(
        _ code: WebCapsuleErrorCode,
        label: String = "",
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () throws -> Any
    ) {
        XCTAssertThrowsError(try operation(), label, file: file, line: line) { error in
            XCTAssertEqual((error as? WebCapsuleError)?.code, code, label, file: file, line: line)
        }
    }
}

private struct TestZipRecord {
    let central: Int
    let local: Int
    let centralName: Int
    let localName: Int
    let data: Int
    let flags: UInt16
    let crc32: UInt32
    let compressedSize: UInt32
    let uncompressedSize: UInt32
}

private func eocdOffset(_ bytes: Data) throws -> Int {
    guard bytes.count >= 22 else { throw TestZipError.invalid }
    for offset in stride(from: bytes.count - 22, through: max(0, bytes.count - 65_557), by: -1)
    where read32(bytes, offset) == 0x0605_4B50 {
        return offset
    }
    throw TestZipError.invalid
}

private func zipRecords(_ bytes: Data) throws -> [TestZipRecord] {
    let eocd = try eocdOffset(bytes)
    let count = Int(read16(bytes, eocd + 10))
    var central = Int(read32(bytes, eocd + 16))
    var result: [TestZipRecord] = []
    for _ in 0..<count {
        guard read32(bytes, central) == 0x0201_4B50 else { throw TestZipError.invalid }
        let nameLength = Int(read16(bytes, central + 28))
        let extraLength = Int(read16(bytes, central + 30))
        let commentLength = Int(read16(bytes, central + 32))
        let local = Int(read32(bytes, central + 42))
        let localNameLength = Int(read16(bytes, local + 26))
        let localExtraLength = Int(read16(bytes, local + 28))
        result.append(TestZipRecord(
            central: central,
            local: local,
            centralName: central + 46,
            localName: local + 30,
            data: local + 30 + localNameLength + localExtraLength,
            flags: read16(bytes, central + 8),
            crc32: read32(bytes, central + 16),
            compressedSize: read32(bytes, central + 20),
            uncompressedSize: read32(bytes, central + 24)
        ))
        central += 46 + nameLength + extraLength + commentLength
    }
    return result
}

private func insertingGap(
    _ original: Data,
    at insertionOffset: Int,
    updateShiftedLocalOffsets: Bool
) throws -> Data {
    let oldRecords = try zipRecords(original)
    let oldEOCD = try eocdOffset(original)
    var bytes = original
    bytes.insert(0, at: insertionOffset)
    let shiftedEOCD = oldEOCD + 1
    set32(&bytes, shiftedEOCD, 16, read32(original, oldEOCD + 16) + 1)
    for record in oldRecords {
        let shiftedCentral = record.central + 1
        let oldLocal = UInt32(record.local)
        let local = updateShiftedLocalOffsets && record.local >= insertionOffset ? oldLocal + 1 : oldLocal
        set32(&bytes, shiftedCentral, 42, local)
    }
    return bytes
}

private func replace(bytes: inout Data, at offset: Int, with replacement: Data) {
    bytes.replaceSubrange(offset..<(offset + replacement.count), with: replacement)
}

private func read16(_ bytes: Data, _ offset: Int) -> UInt16 {
    UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
}

private func read32(_ bytes: Data, _ offset: Int) -> UInt32 {
    UInt32(bytes[offset])
        | UInt32(bytes[offset + 1]) << 8
        | UInt32(bytes[offset + 2]) << 16
        | UInt32(bytes[offset + 3]) << 24
}

private func set16(_ bytes: inout Data, _ base: Int, _ offset: Int, _ value: UInt16) {
    bytes[base + offset] = UInt8(truncatingIfNeeded: value)
    bytes[base + offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
}

private func set32(_ bytes: inout Data, _ base: Int, _ offset: Int, _ value: UInt32) {
    bytes[base + offset] = UInt8(truncatingIfNeeded: value)
    bytes[base + offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    bytes[base + offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
    bytes[base + offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
}

private enum TestZipError: Error {
    case invalid
}
