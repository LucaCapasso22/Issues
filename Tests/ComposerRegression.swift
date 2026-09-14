import AppKit
import Foundation
import IssuesCore

private enum ComposerRegressionError: Error { case failed(String) }

private actor ComposerService: GitHubFetching, GitHubIssueEditing {
    var currentAssignees = ["tester"]
    var assignments = 0
    var creations = 0
    var lastRequest: IssueCreationRequest?

    func fetch(project: ProjectReference, authentication: GitHubAuthentication) async throws -> ProjectSnapshot {
        ProjectSnapshot(project: project, title: "Project \(project.number)", viewerLogin: "tester", issues: [
            GitHubIssue(id: "shared-issue", number: 1, title: "Shared issue", body: "Complete description", url: URL(string: "https://github.com/test/repo/issues/1")!, repository: "test/repo", status: "Ready", labels: [], assignees: currentAssignees, updatedAt: Date(), projectItemID: "item-\(project.number)")
        ], fetchedAt: Date(), metadata: ProjectMetadata(id: "project-\(project.number)", statusField: ProjectStatusField(id: "status", name: "Status", options: [ProjectStatusOption(id: "ready", name: "Ready")]), repositories: ["test/repo"], viewerID: "me"))
    }

    func fetchIssueComposer(repository: String, authentication: GitHubAuthentication) async throws -> IssueComposerMetadata {
        if repository == "test/slow" { try? await Task.sleep(nanoseconds: 80_000_000) }
        return IssueComposerMetadata(repository: repository, repositoryID: "repo", assignees: [IssueChoice(id: "me", name: "tester"), IssueChoice(id: "other", name: "colleague")], labels: [IssueChoice(id: "bug", name: "bug")], milestones: [IssueChoice(id: "release", name: "Release")], issueTypes: [IssueChoice(id: "task", name: "Task")], projects: [ComposerProject(id: "extra", title: "Roadmap", url: "https://github.com/users/tester/projects/3")], templates: [], canWrite: true, warnings: [])
    }

    func updateAssignees(issueID: String, assigneeIDs: [String], authentication: GitHubAuthentication) async throws -> [IssueChoice] {
        assignments += 1
        try await Task.sleep(nanoseconds: 30_000_000)
        let choices = assigneeIDs.map { IssueChoice(id: $0, name: $0 == "me" ? "tester" : "colleague") }
        currentAssignees = choices.map(\.name)
        return choices
    }

    func createIssue(request: IssueCreationRequest, authentication: GitHubAuthentication) async throws -> CreatedProjectIssue {
        creations += 1; lastRequest = request
        try await Task.sleep(nanoseconds: 30_000_000)
        return CreatedProjectIssue(issueID: "created", url: URL(string: "https://github.com/test/repo/issues/2")!, projectItemID: "created-item", warning: nil)
    }
}

@MainActor
func runComposerRegressions() async throws {
    func require(_ value: Bool, _ message: String) throws {
        if !value { throw ComposerRegressionError.failed(message) }
    }
    func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<600 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw ComposerRegressionError.failed("Timed out")
    }
    let suite = "Issues.ComposerRegression.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
    let service = ComposerService()
    let store = AppStore(defaults: defaults, client: service, cacheURL: folder.appendingPathComponent("cache.json"))
    store.startConnect(projectURL: "https://github.com/users/tester/projects/1", useCLI: true, token: "")
    try await waitFor { store.isConfigured && !store.isLoading }

    store.loadComposer(repository: "test/slow")
    await Task.yield()
    store.loadComposer(repository: "test/repo")
    try await waitFor { store.composerMetadata != nil && !store.composerLoading }
    try await Task.sleep(nanoseconds: 100_000_000)
    try require(store.composerMetadata?.repository == "test/repo", "Late metadata crossed repository boundary")

    store.selectedIssueID = "shared-issue"
    store.onlyMine = true
    store.updateAssignees(issueID: "shared-issue", assigneeIDs: ["other"])
    store.updateAssignees(issueID: "shared-issue", assigneeIDs: [])
    try await waitFor { !store.isMutating && !store.isLoading }
    let assignments = await service.assignments
    try require(assignments == 1, "Duplicate assignment write was sent")
    try require(store.accountIssues.isEmpty, "Mine filter retained an issue assigned to another user")
    try require((store.webState(mode: "main")["detailIssue"] as? [String: Any])?["id"] as? String == "shared-issue", "Assignment removed open detail")

    let message: [String: Any] = ["repository": "test/repo", "title": "New issue", "body": "Full **Markdown** description", "optionID": "ready", "assigneeIDs": ["other"], "labelIDs": ["bug"], "milestoneID": "release", "issueTypeID": "task", "additionalProjectIDs": ["extra"], "parentIssue": "1", "blockedBy": ["3"], "blocking": ["4"]]
    store.createComposedIssue(message)
    store.createComposedIssue(message)
    try await waitFor { !store.isMutating && !store.isLoading }
    let created = await service.creations
    let request = await service.lastRequest
    try require(created == 1 && store.creationRevision == 1, "Duplicate creation or lost revision")
    try require(request?.assigneeIDs == ["other"] && request?.labelIDs == ["bug"] && request?.milestoneID == "release" && request?.issueTypeID == "task", "Composer fields were lost")
    try require(request?.additionalProjectIDs == ["extra"] && request?.parentIssue == "1" && request?.blockedBy == ["3"] && request?.blocking == ["4"], "Project or relationship fields were lost")

    var foreign = message; foreign["repository"] = "test/other"
    store.createComposedIssue(foreign)
    try require(store.mutationError != nil && !store.isMutating, "Cross-repository metadata was accepted")
    foreign = message; foreign["assigneeIDs"] = ["foreign-id"]
    store.createComposedIssue(foreign)
    try require(store.mutationError != nil && !store.isMutating, "Unknown assignee ID was accepted")
    print("Composer desktop regressions passed")
}
