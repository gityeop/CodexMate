struct RefreshRequestGate {
    private(set) var isRunning = false
    private(set) var hasQueuedRequest = false

    mutating func beginOrQueue() -> Bool {
        guard !isRunning else {
            hasQueuedRequest = true
            return false
        }

        isRunning = true
        return true
    }

    mutating func finish() -> Bool {
        isRunning = false

        guard hasQueuedRequest else {
            return false
        }

        hasQueuedRequest = false
        return true
    }
}
