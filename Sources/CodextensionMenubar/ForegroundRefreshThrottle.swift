import Foundation

struct ForegroundRefreshThrottle: Equatable {
    let minimumInterval: TimeInterval
    private(set) var lastTriggeredAt: Date?

    init(minimumInterval: TimeInterval = 1, lastTriggeredAt: Date? = nil) {
        self.minimumInterval = max(0, minimumInterval)
        self.lastTriggeredAt = lastTriggeredAt
    }

    mutating func shouldTrigger(now: Date) -> Bool {
        if let lastTriggeredAt,
           now.timeIntervalSince(lastTriggeredAt) < minimumInterval {
            return false
        }

        lastTriggeredAt = now
        return true
    }
}
