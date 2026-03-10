import Foundation

struct VisibleThreadResumePlanner {
    static func threadIDsToResume(
        from sections: [AppStateStore.ProjectSection],
        excluding alreadyResumedThreadIDs: Set<String>
    ) -> [String] {
        var seenThreadIDs = alreadyResumedThreadIDs

        return sections
            .flatMap(\.threads)
            .compactMap { thread in
                guard !seenThreadIDs.contains(thread.id) else {
                    return nil
                }

                seenThreadIDs.insert(thread.id)
                return thread.id
            }
    }
}
