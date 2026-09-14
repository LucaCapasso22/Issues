import Foundation
import IssuesCore

private enum ProjectSelectionHarnessError: Error {
    case expectedFailure
    case assertion(String)
}

private actor ProjectSelectionFetcher: GitHubFetching {
    private var snapshots: [Int: ProjectSnapshot]
    private var delays: [Int: UInt64] = [:]
    private var failures = Set<Int>()
    private var started = Set<Int>()

    init(snapshots: [Int: ProjectSnapshot]) { self.snapshots = snapshots }

    func setDelay(_ nanoseconds: UInt64, project number: Int) { delays[number] = nanoseconds }
    func setFailure(_ enabled: Bool, project number: Int) {
        if enabled { failures.insert(number) } else { failures.remove(number) }
    }
    func didStart(_ number: Int) -> Bool { started.contains(number) }

    func fetch(project: ProjectReference, authentication: GitHubAuthentication) async throws -> ProjectSnapshot {
        started.insert(project.number)
        if let delay = delays[project.number] { try await Task.sleep(nanoseconds: delay) }
        if failures.contains(project.number) { throw ProjectSelectionHarnessError.expectedFailure }
        guard let snapshot = snapshots[project.number] else { throw ProjectSelectionHarnessError.expectedFailure }
        return snapshot
    }
}

@MainActor
func runProjectSelectionRegressions() async throws {
    try await migrationAndCanonicalDeduplication()
    try await failedAndStaleSwitchesPreserveCommittedProject()
    try await visibilityAndCachesAreProjectSpecific()
    try demoProjectsStayEphemeral()
}

@MainActor
private func migrationAndCanonicalDeduplication() async throws {
    let fixture = try ProjectSelectionFixture(name: "migration")
    defer { fixture.cleanUp() }
    let first = makeProjectSnapshot(number: 1, title: "Legacy roadmap", statuses: ["Ready", "Done"])
    fixture.defaults.set(first.project.url.absoluteString, forKey: "projectURL")
    try JSONEncoder().encode(first).write(to: fixture.legacyCacheURL, options: .atomic)

    let fetcher = ProjectSelectionFetcher(snapshots: [1: first])
    let store = AppStore(defaults: fixture.defaults, client: fetcher, cacheURL: fixture.legacyCacheURL)
    try projectSelectionRequire(store.projects == [SavedProject(url: first.project.url.absoluteString, title: first.title)], "legacy project was not migrated")
    try projectSelectionRequire(store.snapshot?.title == first.title, "legacy cache was not restored")
    let migratedCaches = fixture.legacyCacheURL.deletingLastPathComponent().appendingPathComponent("project-caches")
    try projectSelectionRequire(((try? FileManager.default.contentsOfDirectory(atPath: migratedCaches.path)) ?? []).contains(where: { $0.hasSuffix(".json") }), "legacy cache was not migrated to project-specific storage")

    store.startConnect(projectURL: "https://github.com/users/ACME/projects/1?tab=board", useCLI: true, token: "")
    try await projectSelectionWait { !store.isLoading }
    try projectSelectionRequire(store.projects.count == 1, "canonical project URL created a duplicate")
    try projectSelectionRequire(store.projects[0].url.lowercased() == first.project.url.absoluteString.lowercased(), "canonical URL was not persisted")
}

@MainActor
private func failedAndStaleSwitchesPreserveCommittedProject() async throws {
    let fixture = try ProjectSelectionFixture(name: "switching")
    defer { fixture.cleanUp() }
    let snapshots = Dictionary(uniqueKeysWithValues: (1...3).map {
        ($0, makeProjectSnapshot(number: $0, title: "Project \($0)", statuses: ["Ready", "Done"]))
    })
    let fetcher = ProjectSelectionFetcher(snapshots: snapshots)
    let store = AppStore(defaults: fixture.defaults, client: fetcher, cacheURL: fixture.legacyCacheURL)
    for number in 1...3 {
        store.startConnect(projectURL: snapshots[number]!.project.url.absoluteString, useCLI: true, token: "")
        try await projectSelectionWait { !store.isLoading }
    }
    store.selectProject(url: snapshots[1]!.project.url.absoluteString)
    try await projectSelectionWait { !store.isLoading && store.snapshot?.project.number == 1 }

    await fetcher.setDelay(300_000_000, project: 2)
    await fetcher.setDelay(10_000_000, project: 3)
    store.selectedIssueID = "issue-1-0"
    store.pinnedIssueID = "issue-1-0"
    store.search = "Ready"
    store.selectProject(url: snapshots[2]!.project.url.absoluteString)
    try projectSelectionRequire(store.pendingProjectURL == snapshots[2]!.project.url.absoluteString && store.projectURL == snapshots[1]!.project.url.absoluteString, "pending selector lost destination or replaced committed project")
    try await projectSelectionWait { await fetcher.didStart(2) }
    store.selectProject(url: snapshots[3]!.project.url.absoluteString)
    try await projectSelectionWait { !store.isLoading && store.snapshot?.project.number == 3 }
    try await Task.sleep(nanoseconds: 350_000_000)
    try projectSelectionRequire(store.projectURL == snapshots[3]!.project.url.absoluteString, "stale switch replaced the latest project")
    try projectSelectionRequire(store.pendingProjectURL == nil, "completed switch retained pending selection")
    try projectSelectionRequire(store.selectedIssueID == nil && store.pinnedIssueID == nil && store.search.isEmpty, "successful switch retained transient project state")

    await fetcher.setFailure(true, project: 2)
    await fetcher.setDelay(0, project: 2)
    store.selectedIssueID = "issue-3-0"
    store.pinnedIssueID = "issue-3-0"
    store.search = "Ready"
    store.selectProject(url: snapshots[2]!.project.url.absoluteString)
    try await projectSelectionWait { !store.isLoading && store.errorMessage != nil }
    try projectSelectionRequire(store.projectURL == snapshots[3]!.project.url.absoluteString, "failed switch changed the active URL")
    try projectSelectionRequire(store.snapshot?.project.number == 3, "failed switch changed the active snapshot")
    try projectSelectionRequire(store.pendingProjectURL == nil, "failed switch retained pending selection")
    try projectSelectionRequire(store.selectedIssueID == "issue-3-0" && store.pinnedIssueID == "issue-3-0" && store.search == "Ready", "failed switch cleared active project state")
}

@MainActor
private func visibilityAndCachesAreProjectSpecific() async throws {
    let fixture = try ProjectSelectionFixture(name: "visibility")
    defer { fixture.cleanUp() }
    let first = makeProjectSnapshot(number: 1, title: "Delivery", statuses: ["Ready", "In review", "Done", "Blocked", ""])
    let second = makeProjectSnapshot(number: 2, title: "Support", statuses: ["Todo", "Doing"])
    let fetcher = ProjectSelectionFetcher(snapshots: [1: first, 2: second])
    let store = AppStore(defaults: fixture.defaults, client: fetcher, cacheURL: fixture.legacyCacheURL)

    store.startConnect(projectURL: first.project.url.absoluteString, useCLI: true, token: "")
    try await projectSelectionWait { !store.isLoading }
    try projectSelectionRequire(store.statusVisibility.map(\.name) == ["Ready", "In review", "Done", "Blocked", ""], "status visibility order did not follow metadata, extras, and No status")
    store.setStatusVisibility(name: "Done", visible: false)
    try projectSelectionRequire(store.accountIssues.contains(where: { $0.status == "Done" }), "visibility changed account progress input")
    try projectSelectionRequire(!store.filteredIssues.contains(where: { $0.status == "Done" }), "hidden status remained in native filtering")

    store.startConnect(projectURL: second.project.url.absoluteString, useCLI: true, token: "")
    try await projectSelectionWait { !store.isLoading }
    store.setStatusVisibility(name: "Todo", visible: false)
    store.selectProject(url: first.project.url.absoluteString)
    try await projectSelectionWait { !store.isLoading && store.snapshot?.project.number == 1 }
    try projectSelectionRequire(store.statusVisibility.first(where: { $0.name == "Done" })?.visible == false, "first project visibility was not restored")
    try projectSelectionRequire(store.statusVisibility.allSatisfy { $0.name != "Todo" || $0.visible }, "second project visibility leaked into the first")

    let cacheDirectory = fixture.legacyCacheURL.deletingLastPathComponent().appendingPathComponent("project-caches")
    let cachedFiles = (try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)) ?? []
    try projectSelectionRequire(cachedFiles.filter { $0.pathExtension == "json" }.count == 2, "project snapshots did not use separate cache files")

    let restored = AppStore(defaults: fixture.defaults, client: ProjectSelectionFetcher(snapshots: [:]), cacheURL: fixture.legacyCacheURL)
    try projectSelectionRequire(restored.snapshot?.project.number == 1, "selected project cache was not restored")
    try projectSelectionRequire(restored.statusVisibility.first(where: { $0.name == "Done" })?.visible == false, "saved visibility was not restored")
}

@MainActor
private func demoProjectsStayEphemeral() throws {
    let fixture = try ProjectSelectionFixture(name: "demo")
    defer { fixture.cleanUp() }
    let live = makeProjectSnapshot(number: 1, title: "Live", statuses: ["Ready"])
    fixture.defaults.set(live.project.url.absoluteString, forKey: "projectURL")
    try JSONEncoder().encode(live).write(to: fixture.legacyCacheURL, options: .atomic)
    let store = AppStore(defaults: fixture.defaults, client: ProjectSelectionFetcher(snapshots: [1: live]), cacheURL: fixture.legacyCacheURL)
    store.enterDemo()
    try projectSelectionRequire(store.projects.count == 2 && store.snapshot?.project.number == 1, "demo did not expose two projects")
    store.selectProject(url: store.projects[1].url)
    // Demo selection is task-backed, so only persistence is asserted synchronously here.
    try projectSelectionRequire(fixture.defaults.string(forKey: "projectURL") == live.project.url.absoluteString, "demo selection changed live configuration")
}

private struct ProjectSelectionFixture {
    let suiteName: String
    let defaults: UserDefaults
    let directory: URL
    var legacyCacheURL: URL { directory.appendingPathComponent("cache.json") }

    init(name: String) throws {
        suiteName = "Issues.ProjectSelectionRegression.\(name).\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { throw ProjectSelectionHarnessError.assertion("could not create isolated defaults") }
        self.defaults = defaults
        defaults.removePersistentDomain(forName: suiteName)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}

private func makeProjectSnapshot(number: Int, title: String, statuses: [String]) -> ProjectSnapshot {
    let project = ProjectReference(owner: "acme", number: number, isOrganization: false)
    let optionNames = statuses.filter { !$0.isEmpty && $0 != "Blocked" }
    let field = ProjectStatusField(id: "field-\(number)", name: "Status", options: optionNames.enumerated().map {
        ProjectStatusOption(id: "option-\(number)-\($0.offset)", name: $0.element)
    })
    let issues = statuses.enumerated().map { index, status in
        GitHubIssue(id: "issue-\(number)-\(index)", number: number * 100 + index, title: "\(status.isEmpty ? "Unscheduled" : status) item", body: "",
            url: URL(string: "https://github.com/acme/repo/issues/\(number * 100 + index)")!, repository: "acme/repo", status: status,
            labels: [], assignees: ["octocat"], updatedAt: Date(timeIntervalSince1970: Double(number * 100 + index)), projectItemID: "item-\(number)-\(index)")
    }
    return ProjectSnapshot(project: project, title: title, viewerLogin: "octocat", issues: issues, fetchedAt: Date(),
        metadata: ProjectMetadata(id: "project-\(number)", statusField: field, repositories: ["acme/repo"], viewerID: "viewer"))
}

@MainActor
private func projectSelectionWait(_ condition: @escaping @MainActor () async -> Bool) async throws {
    for _ in 0..<600 {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw ProjectSelectionHarnessError.assertion("timed out waiting for asynchronous project state")
}

private func projectSelectionRequire(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw ProjectSelectionHarnessError.assertion(message) }
}
