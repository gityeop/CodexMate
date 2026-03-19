import XCTest
@testable import CodexMate

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

    func testThreadListResponseFallsBackCreatedAtToUpdatedAtWhenMissing() throws {
        let data = Data(
            """
            {
              "data": [
                {
                  "id": "thread-1",
                  "preview": "Example",
                  "updatedAt": 123,
                  "status": { "type": "notLoaded" },
                  "cwd": "/tmp/example",
                  "name": "Test thread"
                }
              ],
              "nextCursor": null
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(ThreadListResponse.self, from: data)

        XCTAssertEqual(response.data.count, 1)
        XCTAssertEqual(response.data[0].createdAt, 123)
        XCTAssertEqual(response.data[0].updatedAt, 123)
    }

    func testThreadListParamsEncodeCursorAndUpdatedAtSortKey() throws {
        let data = try JSONEncoder().encode(
            ThreadListParams(cursor: "cursor-1", limit: 64, sortKey: .updatedAt, archived: false)
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["cursor"] as? String, "cursor-1")
        XCTAssertEqual(object["limit"] as? Int, 64)
        XCTAssertEqual(object["sortKey"] as? String, "updated_at")
        XCTAssertEqual(object["archived"] as? Bool, false)
    }

    func testThreadUnsubscribeParamsEncodeThreadID() throws {
        let data = try JSONEncoder().encode(ThreadUnsubscribeParams(threadId: "thread-1"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["threadId"] as? String, "thread-1")
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
