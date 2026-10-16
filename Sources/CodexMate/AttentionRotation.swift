import Foundation

/// Picks the next chat for the "Next Chat Needing Attention" shortcut.
enum AttentionRotation {
    struct Candidates: Equatable {
        var orderedIDs: [String]
        var waitingIDs: Set<String>
        var unreadIDs: Set<String>
        var currentID: String?
    }

    static func next(_ candidates: Candidates) -> String? {
        next(
            orderedIDs: candidates.orderedIDs,
            waitingIDs: candidates.waitingIDs,
            unreadIDs: candidates.unreadIDs,
            currentID: candidates.currentID
        )
    }

    /// Walks `orderedIDs` from just after the current chat and wraps around. The current chat is
    /// skipped while it only waits for input, since the user is already looking at it.
    static func next(
        orderedIDs: [String],
        waitingIDs: Set<String>,
        unreadIDs: Set<String>,
        currentID: String?
    ) -> String? {
        var attentionIDs = waitingIDs.union(unreadIDs)
        if let currentID, !unreadIDs.contains(currentID) {
            attentionIDs.remove(currentID)
        }
        guard !orderedIDs.isEmpty else {
            return nil
        }

        let startIndex = orderedIDs.firstIndex(where: { $0 == currentID }).map { $0 + 1 } ?? 0
        for offset in 0..<orderedIDs.count {
            let id = orderedIDs[(startIndex + offset) % orderedIDs.count]
            if attentionIDs.contains(id) {
                return id
            }
        }
        return nil
    }
}
