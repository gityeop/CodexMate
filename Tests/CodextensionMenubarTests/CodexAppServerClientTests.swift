import XCTest
@testable import CodextensionMenubar

final class CodexAppServerClientTests: XCTestCase {
    func testDescribeDecodingErrorIncludesMissingKeyAndPath() {
        let error = DecodingError.keyNotFound(
            DynamicCodingKey(stringValue: "preview")!,
            .init(
                codingPath: [
                    DynamicCodingKey(stringValue: "data")!,
                    DynamicCodingKey(intValue: 12)!
                ],
                debugDescription: "missing"
            )
        )

        XCTAssertEqual(
            describeDecodingError(error),
            "missing key 'preview' at data.[12]"
        )
    }

    func testDescribeDecodingErrorUsesRootForEmptyPath() {
        let error = DecodingError.valueNotFound(
            String.self,
            .init(codingPath: [], debugDescription: "missing")
        )

        XCTAssertEqual(
            describeDecodingError(error),
            "missing value at <root>"
        )
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}
