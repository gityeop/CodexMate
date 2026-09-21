import AppKit
import Combine

@MainActor
final class ProjectGraphStore: ObservableObject {
    @Published private(set) var projects: [CodexDesktopProjectCatalog.WorkspaceRoot] = []
    @Published private(set) var projectPath: String?
    @Published private(set) var worktreePath: String?
    @Published private(set) var snapshot: GitRepositorySnapshot?
    @Published private(set) var isNonGitProject = false
    @Published private(set) var graph = GitGraphLayout(commits: [])
    @Published private(set) var changes: [GitFileChange] = []
    @Published private(set) var threads: [AppStateStore.ThreadRow] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingChanges = false
    @Published private(set) var error: String?
    @Published private(set) var changesError: String?
    @Published var actionError: String?
    @Published private(set) var sourceError: String?
    @Published private(set) var language: AppLanguage = .system
    @Published var selectedCommitID: String?
    @Published var projectQuery = ""

    private let reader = GitRepositoryReader()
    private let defaults: UserDefaults
    private var loadTask: Task<Void, Never>?
    private var changesTask: Task<Void, Never>?
    private(set) var isVisible = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var projectName: String { projects.first { $0.path == projectPath }?.displayName ?? "CodexMate" }
    var selectedWorktree: GitWorktree? { snapshot?.worktrees.first { $0.path == worktreePath } }
    var selectedCommit: GitCommit? { snapshot?.commits.first { $0.id == selectedCommitID } }

    var filteredProjects: [CodexDesktopProjectCatalog.WorkspaceRoot] {
        projects.compactMap { project in
            ProjectSearch.score(projectQuery, in: project.displayName).map { (project, $0) }
        }.sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.0.displayName.localizedStandardCompare($1.0.displayName) == .orderedAscending
        }.map(\.0)
    }

    var linkedThreads: [AppStateStore.ThreadRow] {
        guard let path = isNonGitProject ? projectPath : worktreePath else { return [] }
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return threads.filter { thread in
            let cwd = URL(fileURLWithPath: thread.cwd).resolvingSymlinksInPath().path
            return !thread.isSubagent && !thread.cwd.isEmpty && CodexDesktopWorktreePath.matches(root: root, path: cwd)
        }.sorted { $0.activityUpdatedAt > $1.activityUpdatedAt }
    }

    func text(_ key: String) -> String { AppStrings.shared.text("graph." + key, language: language) }

    func worktreeName(_ worktree: GitWorktree, in snapshot: GitRepositorySnapshot) -> String {
        if worktree.isMain { return text("original") }
        // SwiftUI can still render an old row after selection clears the current snapshot.
        return snapshot.displayName(for: worktree)
    }

    func update(catalog: CodexDesktopProjectCatalog, threads: [AppStateStore.ThreadRow], language: AppLanguage, sourceError: String?) {
        let projects = catalog.workspaceRoots.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        if self.projects != projects { self.projects = projects }
        if self.threads != threads { self.threads = threads }
        if self.language != language { self.language = language }
        if self.sourceError != sourceError { self.sourceError = sourceError }
        if !projects.contains(where: { $0.path == projectPath }) {
            let saved = defaults.string(forKey: "graphSelectedProjectPath")
            selectProject(projects.first(where: { $0.path == saved })?.path ?? projects.first?.path)
        }
    }

    func setVisible(_ visible: Bool) {
        isVisible = visible
        if visible { refresh() }
        else {
            loadTask?.cancel()
            changesTask?.cancel()
            isLoading = false
            isLoadingChanges = false
        }
    }

    func selectProject(_ path: String?) {
        guard path != projectPath else { return }
        loadTask?.cancel()
        changesTask?.cancel()
        projectPath = path
        defaults.set(path, forKey: "graphSelectedProjectPath")
        worktreePath = nil
        selectedCommitID = nil
        snapshot = nil
        isNonGitProject = false
        graph = GitGraphLayout(commits: [])
        changes = []
        error = nil
        changesError = nil
        isLoading = false
        isLoadingChanges = false
        if isVisible { refresh() }
    }

    func selectWorktree(_ path: String?) {
        worktreePath = path
        selectedCommitID = selectedWorktree?.head
        changes = []
        refreshChanges()
    }

    func refresh() {
        guard isVisible, let path = projectPath, !isLoading else { return }
        isLoading = true
        loadTask = Task { [weak self, reader] in
            do {
                let snapshot = try await reader.load(at: path)
                try Task.checkCancellation()
                guard let self, self.projectPath == path else { return }
                self.isNonGitProject = false
                self.snapshot = snapshot
                self.graph = GitGraphLayout(commits: snapshot.commits)
                self.error = nil
                self.isLoading = false
                if !snapshot.worktrees.contains(where: { $0.path == self.worktreePath }) {
                    self.selectWorktree(snapshot.worktrees.first?.path)
                } else {
                    self.refreshChanges()
                }
            } catch is CancellationError {
                return
            } catch GitRepositoryError.notRepository {
                guard !Task.isCancelled, let self, self.projectPath == path else { return }
                self.snapshot = nil
                self.graph = GitGraphLayout(commits: [])
                self.worktreePath = nil
                self.selectedCommitID = nil
                self.changes = []
                self.error = nil
                self.isNonGitProject = true
                self.isLoading = false
            } catch {
                guard !Task.isCancelled, let self, self.projectPath == path else { return }
                self.isNonGitProject = false
                self.error = error.localizedDescription
                self.snapshot = nil
                self.graph = GitGraphLayout(commits: [])
                self.worktreePath = nil
                self.changes = []
                self.isLoading = false
            }
        }
    }

    private func refreshChanges() {
        changesTask?.cancel()
        guard let path = worktreePath else { return }
        isLoadingChanges = true
        changesError = nil
        changesTask = Task { [weak self, reader] in
            do {
                let changes = try await reader.changes(at: path)
                try Task.checkCancellation()
                guard let self, self.worktreePath == path else { return }
                self.changes = changes
                self.isLoadingChanges = false
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self, self.worktreePath == path else { return }
                self.changes = []
                self.changesError = error.localizedDescription
                self.isLoadingChanges = false
            }
        }
    }

    func openFolder(_ path: String) {
        if !NSWorkspace.shared.open(URL(fileURLWithPath: path)) {
            actionError = text("folderError") + "\n" + path
        }
    }
}
