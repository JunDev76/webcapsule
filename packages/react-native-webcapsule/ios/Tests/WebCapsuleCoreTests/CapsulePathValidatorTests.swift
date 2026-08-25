import Foundation
import XCTest
@testable import WebCapsuleCore

final class CapsulePathValidatorTests: XCTestCase {
    func testAcceptsRelativeNFCPaths() {
        for path in ["index.html", "assets/app.js", "한글/안내.html", "Ä.js", "ä.js"] {
            XCTAssertNoThrow(try CapsulePathValidator.validate(path))
        }
    }

    func testRejectsEveryUnsafePathClass() {
        let paths = [
            "", "/index.html", "assets/", ".", "..", "./index.html", "assets/../secret",
            "assets\\app.js", "assets//app.js", "assets/%2fsecret", "assets/%2Fsecret",
            "assets/%5csecret", "assets/%5Csecret", "nul\0path", "control\u{7f}.js", "e\u{301}.html",
        ]
        for path in paths {
            assertError(.invalidPath) { try CapsulePathValidator.validate(path) }
        }
    }

    func testRejectsDuplicateCaseAndUnicodeCollisions() {
        assertError(.duplicatePath) { try CapsulePathValidator.validateSet(["a.js", "a.js"]) }
        assertError(.caseCollision) { try CapsulePathValidator.validateSet(["App.js", "app.js"]) }
        assertError(.unicodeCollision) { try CapsulePathValidator.validateSet(["é.html", "e\u{301}.html"]) }
        XCTAssertNoThrow(try CapsulePathValidator.validateSet(["Ä.js", "ä.js"]))
    }

    func testUsesUnsignedUTF8ByteOrdering() {
        XCTAssertNoThrow(try CapsulePathValidator.validateAscendingUTF8Order(["a.js", "z.js", "é.js"]))
        assertError(.invalidOrder) { try CapsulePathValidator.validateAscendingUTF8Order(["é.js", "z.js"]) }
        assertError(.invalidOrder) { try CapsulePathValidator.validateAscendingUTF8Order(["a.js", "a.js"]) }
    }

    func testRejectsFileCountAboveLimitBeforeSetProcessing() {
        let paths = Array(repeating: "a.js", count: CapsulePathValidator.maximumFileCount + 1)
        assertError(.limitExceeded) { try CapsulePathValidator.validateSet(paths) }
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
