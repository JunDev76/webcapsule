import Foundation
import XCTest
@testable import WebCapsuleCore

final class StrictJSONTests: XCTestCase {
    func testRejectsDuplicateKeysAtEveryDepth() {
        assertError(.duplicateJSONKey) { try StrictJSON.parse(Data(#"{"a":1,"a":2}"#.utf8)) }
        assertError(.duplicateJSONKey) { try StrictJSON.parse(Data(#"{"a":{"x":1,"x":2}}"#.utf8)) }
        assertError(.duplicateJSONKey) { try StrictJSON.parse(Data(#"[{"x":1,"x":2}]"#.utf8)) }
    }

    func testRejectsMalformedUTF8EscapesSurrogatesAndTrailingInput() {
        assertError(.invalidJSONValue) { try StrictJSON.parse(Data([0x7B, 0x22, 0xFF, 0x22, 0x3A, 0x31, 0x7D])) }
        assertError(.invalidJSONValue) { try StrictJSON.parse(Data(#"{"a":"\q"}"#.utf8)) }
        assertError(.invalidJSONValue) { try StrictJSON.parse(Data(#"{"a":"\uD800"}"#.utf8)) }
        assertError(.invalidJSONValue) { try StrictJSON.parse(Data(#"{"a":"\uDC00"}"#.utf8)) }
        assertError(.invalidJSONValue) { try StrictJSON.parse(Data(#"{"a":1} true"#.utf8)) }
    }

    func testDecodesValidSurrogatePairAndRejectsNonIntegerNumbers() throws {
        let value = try StrictJSON.parse(Data(#"{"value":"\uD83D\uDE00"}"#.utf8))
        guard case let .object(object) = value,
              case let .string(string)? = object["value"] else {
            return XCTFail("Expected decoded string")
        }
        XCTAssertEqual(string, "😀")
        assertError(.invalidJSONValue) { try StrictJSON.parse(Data(#"{"value":1.0}"#.utf8)) }
        assertError(.invalidJSONValue) { try StrictJSON.parse(Data(#"{"value":1e2}"#.utf8)) }
        XCTAssertNoThrow(try StrictJSON.parse(Data(#"{"value":9007199254740991}"#.utf8)))
        XCTAssertNoThrow(try StrictJSON.parse(Data(#"{"value":-9007199254740991}"#.utf8)))
        assertError(.invalidJSONValue) { try StrictJSON.parse(Data(#"{"value":9007199254740992}"#.utf8)) }
        assertError(.invalidJSONValue) { try StrictJSON.parse(Data(#"{"value":-9007199254740992}"#.utf8)) }
        assertError(.invalidJSONValue) { try StrictJSON.parse(Data(#"{"value":9223372036854775808}"#.utf8)) }
    }

    private func assertError(
        _ code: WebCapsuleErrorCode,
        operation: () throws -> Any,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual((error as? WebCapsuleError)?.code, code, file: file, line: line)
        }
    }
}
