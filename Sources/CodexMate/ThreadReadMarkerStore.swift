import Foundation

struct ThreadReadMarkerStore: Equatable {
    private(set) var lastReadTerminalAtByThreadID: [String: TimeInterval]

    init(lastReadTerminalAtByThreadID: [String: TimeInterval] = [:]) {
        self.lastReadTerminalAtByThreadID = lastReadTerminalAtByThreadID
    }

    mutating func seedIfNeeded(threadID: String, lastTerminalActivityAt: Date?) -> Bool {
        guard lastReadTerminalAtByThreadID[threadID] == nil else {
            return false
        }
        guard let lastTerminalActivityAt else {
            return false
        }

        lastReadTerminalAtByThreadID[threadID] = lastTerminalActivityAt.timeIntervalSince1970
        return true
    }

    mutating func armUnreadTrackingIfNeeded(threadID: String) -> Bool {
        guard lastReadTerminalAtByThreadID[threadID] == nil else {
            return false
        }

        lastReadTerminalAtByThreadID[threadID] = 0
        return true
    }

    func hasUnreadContent(threadID: String, lastTerminalActivityAt: Date?) -> Bool {
        guard let lastTerminalActivityAt else {
            return false
        }

        let lastReadTerminalAt = lastReadTerminalAtByThreadID[threadID] ?? 0
        return lastTerminalActivityAt.timeIntervalSince1970 > lastReadTerminalAt
    }

    mutating func markRead(threadID: String, lastTerminalActivityAt: Date?) -> Bool {
        guard let lastTerminalActivityAt else {
            return false
        }

        let lastTerminalTimestamp = lastTerminalActivityAt.timeIntervalSince1970
        let existingTimestamp = lastReadTerminalAtByThreadID[threadID] ?? 0
        let newTimestamp = max(existingTimestamp, lastTerminalTimestamp)

        guard existingTimestamp != newTimestamp else {
            return false
        }

        lastReadTerminalAtByThreadID[threadID] = newTimestamp
        return true
    }

    mutating func markReadIfViewedAfterLastTerminalActivity(
        threadID: String,
        lastTerminalActivityAt: Date?,
        viewedAt: Date?
    ) -> Bool {
        guard let lastTerminalActivityAt, let viewedAt, viewedAt >= lastTerminalActivityAt else {
            return false
        }

        return markRead(threadID: threadID, lastTerminalActivityAt: lastTerminalActivityAt)
    }

    mutating func prune(keeping threadIDs: Set<String>, minimumTimestamp: TimeInterval) -> Bool {
        let filteredMarkers = lastReadTerminalAtByThreadID.filter { threadID, timestamp in
            threadIDs.contains(threadID) || timestamp >= minimumTimestamp
        }

        guard filteredMarkers.count != lastReadTerminalAtByThreadID.count else {
            return false
        }

        lastReadTerminalAtByThreadID = filteredMarkers
        return true
    }
}
