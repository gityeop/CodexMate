import SwiftUI

struct ProjectGraphInspector: View {
    @ObservedObject var store: ProjectGraphStore
    let openThread: (String) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: MateUI.sectionSpacing) {
                    if let snapshot = store.snapshot, let worktree = store.selectedWorktree {
                        Label(store.worktreeName(worktree, in: snapshot), systemImage: "folder.fill")
                            .font(.title3.weight(.semibold))
                        Label(worktree.branch ?? store.text("detached"), systemImage: "arrow.triangle.branch")
                            .font(.callout).textSelection(.enabled)
                        Text(worktree.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        if worktree.isLocked { Label(store.text("locked"), systemImage: "lock") }
                        if worktree.isPrunable { Label(store.text("prunable"), systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                        Button { store.openFolder(worktree.path) } label: {
                            Label(store.text("openFolder"), systemImage: "folder")
                        }.buttonStyle(MateButtonStyle(kind: .secondary))
                        Divider()
                        fileChanges
                        Divider()
                        linkedThreads(proxy: proxy)
                    } else if store.isNonGitProject, let path = store.projectPath {
                        Label(store.projectName, systemImage: "folder.fill")
                            .font(.title3.weight(.semibold))
                        Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Button { store.openFolder(path) } label: {
                            Label(store.text("openProject"), systemImage: "folder")
                        }.buttonStyle(MateButtonStyle(kind: .secondary))
                        Divider()
                        linkedThreads(proxy: proxy)
                    } else {
                        Text(store.text("selectWorktree")).foregroundStyle(.secondary)
                    }
                    if let commit = store.selectedCommit {
                        Divider()
                        Text(store.text("commit")).font(.headline)
                        Text(commit.subject).font(.callout).textSelection(.enabled)
                        ForEach(store.snapshot?.references.filter { $0.commitID == commit.id } ?? [], id: \.name) { reference in
                            Label(reference.name, systemImage: "arrow.triangle.branch").font(.caption).textSelection(.enabled)
                        }
                        Text(commit.id).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Text(commit.author).font(.caption).foregroundStyle(.secondary)
                        Text(commit.date, style: .date).font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(MateUI.sectionSpacing)
            }
            .background(MateUI.panel)
        }
    }

    private func linkedThreads(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: MateUI.spacing) {
            Text(store.text("threads")).font(.headline)
            if let error = store.sourceError {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if store.linkedThreads.isEmpty {
                Text(store.text(store.isNonGitProject ? "noProjectThreads" : "noThreads"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(store.linkedThreads) { thread in
                ProjectThreadCard(title: thread.displayTitle, status: statusText(thread.presentationStatus),
                                  statusColor: statusColor(thread.presentationStatus), openLabel: store.text("openThread"),
                                  focusChanged: { proxy.scrollTo(thread.id, anchor: .center) }) {
                    openThread(thread.id)
                }.id(thread.id)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var fileChanges: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(store.text("changes")).font(.headline)
                Spacer()
                if store.isLoadingChanges { ProgressView().controlSize(.small) }
                else if store.changesError == nil { Text("\(store.changes.count)").foregroundStyle(.secondary) }
            }
            if let error = store.changesError {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            } else if !store.isLoadingChanges && store.changes.isEmpty {
                Label(store.text("clean"), systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary)
            } else {
                DisclosureGroup(store.text("showFiles")) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(store.changes) { change in
                            HStack(alignment: .top, spacing: MateUI.spacing) {
                                Text(change.status).font(.system(size: 12, design: .monospaced)).foregroundStyle(.orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(change.path).font(MateUI.caption).textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if let original = change.originalPath {
                                        Text("← " + original).font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, MateUI.spacing)
                }.font(MateUI.caption).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusColor(_ status: AppStateStore.PresentationStatus) -> Color {
        switch status {
        case .running: .green
        case .waitingForUser: .orange
        case .failed: .red
        case .idle: .secondary
        case .notLoaded: .secondary
        }
    }

    private func statusText(_ status: AppStateStore.PresentationStatus) -> String {
        switch status {
        case .running: store.text("running")
        case .waitingForUser: store.text("waiting")
        case .failed: store.text("failed")
        case .idle: store.text("idle")
        case .notLoaded: store.text("unknown")
        }
    }
}

private struct ProjectThreadCard: View {
    let title: String
    let status: String
    let statusColor: Color
    let openLabel: String
    let focusChanged: () -> Void
    let open: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: MateUI.spacing) {
                Text(title).font(MateUI.font.weight(.medium)).lineLimit(3)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 6, height: 6)
                    Text(status).font(MateUI.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(MateButtonStyle(kind: .card))
        .focused($focused)
        .onChange(of: focused) { if $0 { focusChanged() } }
        .overlay {
            RoundedRectangle(cornerRadius: MateUI.cornerRadius)
                .strokeBorder(focused ? MateUI.focus : .clear, lineWidth: 1).allowsHitTesting(false)
        }
        .help(openLabel)
        .accessibilityLabel(title)
        .accessibilityValue(status)
        .accessibilityHint(openLabel)
    }
}
