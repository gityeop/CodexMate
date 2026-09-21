import Foundation

struct GitGraphLayout {
    struct Segment: Equatable {
        let from: Int
        let to: Int
        let startsAtNode: Bool
        let endsAtNode: Bool
        let color: Int
    }

    struct Row: Identifiable {
        let commit: GitCommit
        let column: Int
        let color: Int
        let segments: [Segment]
        var id: String { commit.id }
    }

    let rows: [Row]
    let columnCount: Int

    init(commits: [GitCommit]) {
        var lanes: [(id: String, color: Int)] = []
        var nextColor = 0
        var rows: [Row] = []
        var width = 1
        for commit in commits {
            let hasIncoming = lanes.contains { $0.id == commit.id }
            if !hasIncoming {
                lanes.append((commit.id, nextColor))
                nextColor += 1
            }
            let before = lanes
            let column = before.firstIndex { $0.id == commit.id }!
            let color = before[column].color
            lanes.remove(at: column)
            for (index, parent) in commit.parents.enumerated() where !lanes.contains(where: { $0.id == parent }) {
                let parentColor = index == 0 ? color : nextColor
                if index > 0 { nextColor += 1 }
                lanes.insert((parent, parentColor), at: min(column + index, lanes.count))
            }
            var segments: [Segment] = []
            for (index, lane) in before.enumerated() where lane.id != commit.id {
                let destination = lanes.firstIndex { $0.id == lane.id }!
                segments.append(Segment(from: index, to: destination, startsAtNode: false, endsAtNode: false, color: lane.color))
            }
            if hasIncoming {
                segments.append(Segment(from: column, to: column, startsAtNode: false, endsAtNode: true, color: color))
            }
            for parent in commit.parents {
                let destination = lanes.firstIndex { $0.id == parent }!
                segments.append(Segment(from: column, to: destination, startsAtNode: true, endsAtNode: false, color: lanes[destination].color))
            }
            width = max(width, before.count, lanes.count)
            rows.append(Row(commit: commit, column: column, color: color, segments: segments))
        }
        self.rows = rows
        self.columnCount = width
    }
}
