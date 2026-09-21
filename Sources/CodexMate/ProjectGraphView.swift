import SwiftUI

struct ProjectGraphView: View {
    @ObservedObject var store: ProjectGraphStore
    let openThread: (String) -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(.tint)
                Text(store.projectName).font(.headline)
                Text("Git Graph").foregroundStyle(.secondary)
                Spacer()
                if store.isLoading { ProgressView().controlSize(.small) }
                Button(action: { store.refresh() }) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(MateButtonStyle(kind: .ghost, iconOnly: true))
                    .help(store.text("refresh")).accessibilityLabel(store.text("refresh"))
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(store.isLoading || store.projectPath == nil)
                Button(action: openSettings) { Image(systemName: "gearshape") }
                    .buttonStyle(MateButtonStyle(kind: .ghost, iconOnly: true))
                    .help(AppStrings.shared.text("menu.settings", language: store.language))
                    .accessibilityLabel(AppStrings.shared.text("menu.settings", language: store.language))
            }.font(MateUI.font).padding(.horizontal, 18).padding(.vertical, 8)
                .background(MateUI.panel)
            Divider()
            NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 310)
            } detail: {
                HSplitView {
                    graphContent.frame(minWidth: 430, maxWidth: .infinity, maxHeight: .infinity)
                    ProjectGraphInspector(store: store, openThread: openThread)
                        .frame(minWidth: 260, idealWidth: 290, maxWidth: 380, maxHeight: .infinity)
                }
            }
        }
        .font(MateUI.font)
        .buttonStyle(MateButtonStyle())
        .alert(store.text("error"), isPresented: Binding(get: { store.actionError != nil }, set: { if !$0 { store.actionError = nil } })) {
            Button("OK") { store.actionError = nil }
        } message: { Text(store.actionError ?? "") }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: MateUI.spacing) {
                Text(store.text("projects")).font(MateUI.caption.weight(.medium)).foregroundStyle(.secondary)
                MateSearchField(title: store.text("searchProjects"), clearLabel: store.text("clearSearch"), text: $store.projectQuery)
            }.padding(MateUI.inset)
            List(selection: Binding(get: { store.projectPath }, set: { store.selectProject($0) })) {
                ForEach(store.filteredProjects, id: \.path) { project in
                    Label { Text(project.displayName) } icon: { Image(systemName: "folder").foregroundStyle(.tint) }
                        .tag(project.path).help(project.path)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 100, idealHeight: 175, maxHeight: 200)
            .overlay {
                if store.filteredProjects.isEmpty {
                    Text(store.text("noSearchResults")).font(MateUI.caption).foregroundStyle(.secondary).padding(MateUI.inset)
                }
            }
            Divider()
            worktreeList
            Divider()
            Button { if let path = store.projectPath { store.openFolder(path) } } label: {
                Label(store.text("openProject"), systemImage: "folder")
            }
            .buttonStyle(MateButtonStyle(kind: .ghost))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(MateUI.spacing).disabled(store.projectPath == nil)
        }
        .background(MateUI.panel)
    }

    private var worktreeList: some View {
        List(selection: Binding(get: { store.worktreePath }, set: { store.selectWorktree($0) })) {
            Section(store.text("worktrees") + "  \(store.snapshot?.worktrees.count ?? 0)") {
                if store.isNonGitProject {
                    Text(store.text("noWorktrees"))
                        .font(MateUI.caption).foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else if let snapshot = store.snapshot {
                    ForEach(snapshot.worktrees) { worktree in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: worktree.isMain ? "house" : "folder")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(store.worktreeName(worktree, in: snapshot)).lineLimit(1)
                                Text(worktree.branch ?? store.text("detached"))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .padding(.vertical, 3)
                        .tag(worktree.path)
                        .help(worktree.path)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private var graphContent: some View {
        if let error = store.error {
            message(title: store.text("loadError"), detail: error, icon: "exclamationmark.triangle")
        } else if store.projectPath == nil {
            message(title: store.text("noProject"), detail: store.sourceError ?? store.text("noProjectHelp"), icon: "folder")
        } else if store.isNonGitProject {
            message(title: store.text("nonGitProject"), detail: store.text("nonGitProjectHelp"), icon: "folder")
        } else if let snapshot = store.snapshot {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Git Graph").font(.title2.weight(.semibold))
                    Text("\(snapshot.worktrees.count) " + store.text("worktrees") + " · \(snapshot.references.filter { !$0.isRemote }.count) " + store.text("branches"))
                        .font(.subheadline).foregroundStyle(.secondary)
                }.padding(20)
                Divider()
                if snapshot.commits.isEmpty {
                    message(title: store.text("noCommits"), detail: store.text("noCommitsHelp"), icon: "point.3.connected.trianglepath.dotted")
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            VStack(spacing: 0) {
                                ForEach(store.graph.rows) { row in
                                    GitCommitRow(row: row, graphWidth: CGFloat(store.graph.columnCount) * 18 + 22,
                                                 references: snapshot.references.filter { $0.commitID == row.id },
                                                 worktrees: snapshot.worktrees.filter { $0.head == row.id }, snapshot: snapshot, store: store)
                                    .id(row.id)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .onAppear {
                            if let head = store.selectedWorktree?.head { proxy.scrollTo(head, anchor: .top) }
                        }
                        .onChange(of: store.worktreePath) { _ in
                            if let head = store.selectedWorktree?.head { proxy.scrollTo(head, anchor: .center) }
                        }
                    }
                }
                Divider()
                HStack {
                    Text(store.text("historyLimit"))
                    Spacer()
                    Text(snapshot.loadedAt, style: .time)
                }.font(.caption).foregroundStyle(.secondary).padding(12)
            }.background(MateUI.canvas)
        } else {
            ProgressView(store.text("loading")).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func message(title: String, detail: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            Text(detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
        }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

private struct GitCommitRow: View {
    let row: GitGraphLayout.Row
    let graphWidth: CGFloat
    let references: [GitReference]
    let worktrees: [GitWorktree]
    let snapshot: GitRepositorySnapshot
    @ObservedObject var store: ProjectGraphStore
    private static let palette: [Color] = [.teal, .purple, .blue, .orange, .pink, .indigo]
    private func color(_ index: Int) -> Color { Self.palette[index % Self.palette.count] }

    var body: some View {
        HStack(spacing: 10) {
            Canvas { context, size in
                let middle = size.height / 2
                func x(_ column: Int) -> CGFloat { 14 + CGFloat(column) * 18 }
                for segment in row.segments {
                    let start = CGPoint(x: x(segment.from), y: segment.startsAtNode ? middle : 0)
                    let end = CGPoint(x: x(segment.to), y: segment.endsAtNode ? middle : size.height)
                    var path = Path()
                    path.move(to: start)
                    path.addCurve(to: end, control1: CGPoint(x: start.x, y: (start.y + end.y) / 2),
                                  control2: CGPoint(x: end.x, y: (start.y + end.y) / 2))
                    context.stroke(path, with: .color(color(segment.color)), lineWidth: 2)
                }
                let node = CGRect(x: x(row.column) - 4.5, y: middle - 4.5, width: 9, height: 9)
                context.fill(Path(ellipseIn: node), with: .color(color(row.color)))
            }.frame(width: graphWidth, height: 66).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(row.commit.subject).font(.system(size: 13, weight: .medium)).lineLimit(1)
                HStack(spacing: 6) {
                    ForEach(Array(references.prefix(2)), id: \.name) { ref in
                        Text(ref.name).font(.caption).foregroundStyle(ref.isRemote ? Color.secondary : color(row.color))
                            .lineLimit(1)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(color(row.color).opacity(ref.isRemote ? 0.05 : 0.12), in: Capsule())
                    }
                    if references.count > 2 { Text("+\(references.count - 2)").font(.caption).foregroundStyle(.secondary) }
                    ForEach(Array(worktrees.prefix(2))) { worktree in
                        Button { store.selectWorktree(worktree.path) } label: {
                            Label(store.worktreeName(worktree, in: snapshot), systemImage: "folder")
                                .font(.caption).lineLimit(1)
                        }.buttonStyle(.borderless).help(worktree.path)
                    }
                    if worktrees.count > 2 {
                        Text("+\(worktrees.count - 2)").font(.caption).foregroundStyle(.secondary)
                            .help(worktrees.map(\.path).joined(separator: "\n"))
                    }
                    if references.isEmpty && worktrees.isEmpty {
                        Text(row.commit.author).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(String(row.id.prefix(7))).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                .padding(.trailing, 16)
        }
        .frame(height: 66)
        .background(store.selectedCommitID == row.id ? Color.accentColor.opacity(0.10) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { store.selectedCommitID = row.id }
        .accessibilityElement(children: .contain)
    }
}
