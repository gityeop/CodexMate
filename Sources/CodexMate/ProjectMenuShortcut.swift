import Foundation

enum ProjectMenuShortcut {
    private static let keyEquivalents = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]

    static var maxCount: Int {
        keyEquivalents.count
    }

    static func keyEquivalent(for index: Int) -> String? {
        guard keyEquivalents.indices.contains(index) else {
            return nil
        }

        return keyEquivalents[index]
    }

    static func index(for characters: String) -> Int? {
        keyEquivalents.firstIndex(of: characters)
    }
}
