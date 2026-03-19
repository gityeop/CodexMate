import Foundation

struct RefreshSchedulingPolicy: Equatable {
    private enum Interval {
        static let fastDesktopActivity: TimeInterval = 1
        static let idleDesktopActivity: TimeInterval = 5
        static let menuThreadList: TimeInterval = 5
        static let activeThreadList: TimeInterval = 15
        static let idleThreadList: TimeInterval = 60
    }

    let desktopActivityInterval: TimeInterval
    let threadListInterval: TimeInterval

    var timerInterval: TimeInterval {
        min(desktopActivityInterval, threadListInterval)
    }

    static func current(
        isMenuOpen: Bool,
        overallStatus: AppStateStore.OverallStatus,
        hasRecentThreads: Bool
    ) -> RefreshSchedulingPolicy {
        if isMenuOpen {
            return RefreshSchedulingPolicy(
                desktopActivityInterval: Interval.fastDesktopActivity,
                threadListInterval: Interval.menuThreadList
            )
        }

        if !hasRecentThreads {
            return RefreshSchedulingPolicy(
                desktopActivityInterval: Interval.idleDesktopActivity,
                threadListInterval: Interval.menuThreadList
            )
        }

        if overallStatus == .running {
            return RefreshSchedulingPolicy(
                desktopActivityInterval: Interval.fastDesktopActivity,
                threadListInterval: Interval.activeThreadList
            )
        }

        return RefreshSchedulingPolicy(
            desktopActivityInterval: Interval.idleDesktopActivity,
            threadListInterval: Interval.idleThreadList
        )
    }

    func shouldRefreshDesktopActivity(now: Date, lastRequestedAt: Date?) -> Bool {
        shouldRefresh(now: now, lastRequestedAt: lastRequestedAt, minimumInterval: desktopActivityInterval)
    }

    func shouldRefreshThreadList(now: Date, lastRequestedAt: Date?) -> Bool {
        shouldRefresh(now: now, lastRequestedAt: lastRequestedAt, minimumInterval: threadListInterval)
    }

    private func shouldRefresh(
        now: Date,
        lastRequestedAt: Date?,
        minimumInterval: TimeInterval
    ) -> Bool {
        guard let lastRequestedAt else {
            return true
        }

        return now.timeIntervalSince(lastRequestedAt) >= minimumInterval
    }
}
