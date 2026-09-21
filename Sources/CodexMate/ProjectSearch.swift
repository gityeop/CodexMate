import Foundation

enum ProjectSearch {
    /// Ordered character matching: exact, prefix, substring, then compact subsequences.
    static func score(_ query: String, in name: String) -> Int? {
        let query = normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        let name = normalized(name)
        if query.isEmpty { return 0 }
        if name == query { return 0 }
        if name.hasPrefix(query) { return 100 + name.count - query.count }
        if let range = name.range(of: query) { return 1_000 + name.distance(from: name.startIndex, to: range.lowerBound) }

        var cursor = name.startIndex
        var first: String.Index?
        var last = cursor
        for character in query {
            guard let match = name[cursor...].firstIndex(of: character) else { return nil }
            if first == nil { first = match }
            last = match
            cursor = name.index(after: match)
        }
        let start = first!
        let gaps = name.distance(from: start, to: last) + 1 - query.count
        return 10_000 + gaps * 10 + name.distance(from: name.startIndex, to: start)
    }

    private static func normalized(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
