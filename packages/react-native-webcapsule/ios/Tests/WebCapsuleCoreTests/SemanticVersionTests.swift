import Foundation
import XCTest
@testable import WebCapsuleCore

final class SemanticVersionTests: XCTestCase {
    func testAcceptsStrictSemVerIncludingLargeNumericIdentifiers() {
        for version in [
            "0.0.0",
            "1.2.3-beta.1",
            "999999999999999999999999999999.0.1",
            "1.0.0-alpha+build.42",
        ] {
            XCTAssertNoThrow(try SemanticVersion.validate(version))
        }
    }

    func testRejectsMalformedSemVer() {
        for version in [
            "", "v1.2.3", "1", "1.2", "01.2.3", "1.02.3", "1.2.03",
            "1.0.0-", "1.0.0-alpha..1", "1.0.0-01", "1.0.0+", "1.0.0+a_1",
        ] {
            assertError(.invalidVersion) { try SemanticVersion.validate(version) }
        }
    }

    func testComparesSemVerPrecedenceWithoutIntegerOverflow() throws {
        let ascending = [
            "1.0.0-alpha",
            "1.0.0-alpha.1",
            "1.0.0-alpha.beta",
            "1.0.0-beta",
            "1.0.0-beta.2",
            "1.0.0-beta.11",
            "1.0.0-rc.1",
            "1.0.0",
            "2.0.0",
            "1000000000000000000000000000000.0.0",
        ]
        for pair in zip(ascending, ascending.dropFirst()) {
            XCTAssertEqual(try SemanticVersion.compare(pair.0, pair.1), .orderedAscending)
            XCTAssertEqual(try SemanticVersion.compare(pair.1, pair.0), .orderedDescending)
        }
        XCTAssertEqual(try SemanticVersion.compare("1.2.3+one", "1.2.3+two"), .orderedSame)
    }

    private func assertError(
        _ code: WebCapsuleErrorCode,
        operation: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual((error as? WebCapsuleError)?.code, code, file: file, line: line)
        }
    }
}
