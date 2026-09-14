import Foundation
import AppKit
import IssuesCore

private enum HarnessError: Error {
    case expectedFailure
    case assertion(String)
}

private final class CancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: (started: Bool, cancelled: Bool) = (false, false)

    func markStarted() { lock.withLock { values.started = true } }
    func markCancelled() { lock.withLock { values.cancelled = true } }
    var started: Bool { lock.withLock { values.started } }
    var cancelled: Bool { lock.withLock { values.cancelled } }
}

private struct FailingFetcher: GitHubFetching {
    func fetch(project: ProjectReference, authentication: GitHubAuthentication) async throws -> ProjectSnapshot {
        throw HarnessError.expectedFailure
    }
}

private struct BlockingFetcher: GitHubFetching {
    let probe: CancellationProbe

    func fetch(project: ProjectReference, authentication: GitHubAuthentication) async throws -> ProjectSnapshot {
        probe.markStarted()
        do {
            try await Task.sleep(nanoseconds: 30_000_000_000)
        } catch is CancellationError {
            probe.markCancelled()
            throw CancellationError()
        }
        throw HarnessError.expectedFailure
    }
}

private actor EditingService: GitHubFetching, GitHubMutating {
    var updates = 0
    var creations = 0
    var current: ProjectSnapshot

    init() {
        let field = ProjectStatusField(id: "field", name: "Status", options: [
            ProjectStatusOption(id: "todo", name: "Todo"), ProjectStatusOption(id: "doing", name: "In progress")
        ])
        let issue = GitHubIssue(id: "issue", number: 1, title: "Regression issue", body: "Full body",
            url: URL(string: "https://github.com/test/repo/issues/1")!, repository: "test/repo", status: "Todo",
            labels: [], assignees: ["tester"], updatedAt: Date(), projectItemID: "item")
        current = ProjectSnapshot(project: ProjectReference(owner: "tester", number: 1, isOrganization: false),
            title: "Test project", viewerLogin: "tester", issues: [issue], fetchedAt: Date(),
            metadata: ProjectMetadata(id: "project", statusField: field, repositories: ["test/repo"], viewerID: "viewer"))
    }
    func fetch(project: ProjectReference, authentication: GitHubAuthentication) async throws -> ProjectSnapshot { current }
    func updateStatus(projectID: String, itemID: String, fieldID: String, optionID: String?, authentication: GitHubAuthentication) async throws {
        updates += 1
        try await Task.sleep(nanoseconds: 40_000_000)
        current.issues[0].status = optionID == "doing" ? "In progress" : ""
    }
    func createIssue(projectID: String, repository: String, title: String, body: String, assigneeID: String?, statusFieldID: String?, statusOptionID: String?, authentication: GitHubAuthentication) async throws -> CreatedProjectIssue {
        creations += 1
        try await Task.sleep(nanoseconds: 40_000_000)
        return CreatedProjectIssue(issueID: "created", url: URL(string: "https://github.com/test/repo/issues/2")!,
            projectItemID: nil, warning: "Issue created; adding it to the project failed. Open the existing issue instead of creating another.")
    }
}

@main
private struct IssuesDesktopRegression {
    @MainActor
    static func main() async throws {
        try await failedReconnectPreservesCommittedConfiguration()
        try await enteringDemoCancelsAuthenticatedWork()
        try leavingDemoClosesSettings()
        try malformedOnboardingURLKeepsOnboardingVisible()
        try previewGrowsRightAtLeftEdgeWithoutMovingOrb()
        try previewGrowsBelowAtTopEdgeWithoutMovingOrb()
        try await mutationsAreSerializedAndPartialCreationIsPreserved()
        try demoFilteringAndDetailSurviveStatusChanges()
        try hoverSurvivesResizeAndClosesOnDeparture()
        try await runProjectSelectionRegressions()
        try await runComposerRegressions()
        print("IssuesDesktop regression harness passed")
    }

    private static func hoverSurvivesResizeAndClosesOnDeparture() throws {
        var hover = FloatingHoverState()
        try require(hover.update(now: 0, overBadge: false, insidePreview: true, isPreview: false) == nil, "icon body opened preview without badge hover")
        try require(hover.update(now: 1, overBadge: true, insidePreview: true, isPreview: false) == nil, "hover opened without dwell")
        try require(hover.update(now: 1.2, overBadge: true, insidePreview: true, isPreview: false) == "preview", "badge did not open preview")
        for tick in 0..<200 {
            try require(hover.update(now: 1.3 + Double(tick) * 0.05, overBadge: false, insidePreview: true, isPreview: true) == nil, "DOM/geometry transition closed preview while pointer stayed inside")
        }
        try require(hover.update(now: 12, overBadge: false, insidePreview: false, isPreview: true) == nil, "departure ignored close grace")
        try require(hover.update(now: 12.3, overBadge: false, insidePreview: false, isPreview: true) == "icon", "departure did not close preview")
        try require(hover.update(now: 13, overBadge: false, insidePreview: false, isPreview: false) == nil, "preview reopened after departure")
        _ = hover.update(now: 14, overBadge: true, insidePreview: true, isPreview: false)
        hover.reset()
        try require(hover.update(now: 15, overBadge: true, insidePreview: true, isPreview: false) == nil, "drag carried a stale hover deadline")
    }

    @MainActor
    private static func failedReconnectPreservesCommittedConfiguration() async throws {
        let suite = "IssuesDesktopRegression.failedReconnect"
        guard let defaults = UserDefaults(suiteName: suite) else { throw HarnessError.assertion("cannot create defaults") }
        defaults.removePersistentDomain(forName: suite)
        defaults.set("https://github.com/users/octocat/projects/2", forKey: "projectURL")
        defaults.set(true, forKey: "useCLI")

        let store = AppStore(defaults: defaults, client: FailingFetcher())
        store.startConnect(
            projectURL: "https://github.com/orgs/acme/projects/7",
            useCLI: false,
            token: "invalid-token"
        )
        try await waitUntil { !store.isLoading && store.errorMessage != nil }

        try require(store.projectURL == "https://github.com/users/octocat/projects/2", "failed reconnect replaced committed project URL")
        try require(store.useCLI, "failed reconnect replaced committed authentication mode")
        try require(store.isConfigured, "failed reconnect cleared valid committed configuration")
        defaults.removePersistentDomain(forName: suite)
    }

    @MainActor
    private static func enteringDemoCancelsAuthenticatedWork() async throws {
        let suite = "IssuesDesktopRegression.cancellation"
        guard let defaults = UserDefaults(suiteName: suite) else { throw HarnessError.assertion("cannot create defaults") }
        defaults.removePersistentDomain(forName: suite)
        let probe = CancellationProbe()
        let store = AppStore(defaults: defaults, client: BlockingFetcher(probe: probe))

        store.startConnect(
            projectURL: "https://github.com/users/octocat/projects/2",
            useCLI: true,
            token: ""
        )
        try await waitUntil { probe.started }
        store.enterDemo()
        try await waitUntil { probe.cancelled }

        try require(store.isDemo, "enterDemo did not activate demo state")
        try require(!store.isLoading, "cancelled request left loading active")
        defaults.removePersistentDomain(forName: suite)
    }

    @MainActor
    private static func leavingDemoClosesSettings() throws {
        let suite = "IssuesDesktopRegression.leaveDemo"
        guard let defaults = UserDefaults(suiteName: suite) else { throw HarnessError.assertion("cannot create defaults") }
        defaults.removePersistentDomain(forName: suite)
        let store = AppStore(defaults: defaults, client: FailingFetcher())
        store.enterDemo()
        store.showSettings = true
        store.leaveDemo()
        try require(!store.showSettings, "leaveDemo kept settings open")
        defaults.removePersistentDomain(forName: suite)
    }

    @MainActor
    private static func malformedOnboardingURLKeepsOnboardingVisible() throws {
        let suite = "IssuesDesktopRegression.invalidOnboardingURL"
        guard let defaults = UserDefaults(suiteName: suite) else { throw HarnessError.assertion("cannot create defaults") }
        defaults.removePersistentDomain(forName: suite)
        let store = AppStore(defaults: defaults, client: FailingFetcher())
        store.startConnect(projectURL: "not a GitHub URL", useCLI: true, token: "")
        try require(!store.showSettings, "invalid onboarding URL opened settings")
        try require(store.errorMessage != nil, "invalid onboarding URL did not expose an error")
        defaults.removePersistentDomain(forName: suite)
    }

    private static func previewGrowsRightAtLeftEdgeWithoutMovingOrb() throws {
        let anchor = NSPoint(x: 72, y: 400)
        let placement = FloatingPanelGeometry.previewPlacement(
            anchor: anchor,
            visibleFrame: NSRect(x: 0, y: 0, width: 1_440, height: 900)
        )
        try require(placement.horizontal == "right", "left-edge preview did not grow right")
        try require(placement.vertical == "above", "preview with upper room did not grow above")
        try require(placement.frame.minX == 8, "right-growing preview moved the orb horizontally")
        try require(placement.frame.minY == 400, "right-growing preview moved the orb vertically")
    }

    private static func previewGrowsBelowAtTopEdgeWithoutMovingOrb() throws {
        let anchor = NSPoint(x: 1_000, y: 828)
        let placement = FloatingPanelGeometry.previewPlacement(
            anchor: anchor,
            visibleFrame: NSRect(x: 0, y: 0, width: 1_440, height: 900)
        )
        try require(placement.horizontal == "left", "preview with left room did not grow left")
        try require(placement.vertical == "below", "top-edge preview did not grow below")
        try require(placement.frame.maxX == 1_000, "below-growing preview moved the orb horizontally")
        try require(placement.frame.maxY == 892, "below-growing preview moved the orb vertically")
    }

    @MainActor
    private static func mutationsAreSerializedAndPartialCreationIsPreserved() async throws {
        let suite = "IssuesDesktopRegression.editing"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let service = EditingService()
        let store = AppStore(defaults: defaults, client: service, cacheURL: directory.appendingPathComponent("cache.json"))
        store.startConnect(projectURL: "https://github.com/users/tester/projects/1", useCLI: true, token: "")
        try await waitUntil { store.isConfigured && !store.isLoading }
        store.changeStatus(issueID: "issue", optionID: "doing")
        store.changeStatus(issueID: "issue", optionID: "todo")
        store.enterDemo()
        try require(!store.isDemo, "a session switch interrupted an in-flight write")
        try await waitUntil { !store.isMutating && !store.isLoading }
        let updateCount = await service.updates
        try require(updateCount == 1, "duplicate status update was submitted")
        try require(store.snapshot?.issues.first?.status == "In progress", "saved status was not reflected locally")

        store.createIssue(repository: "test/repo", title: "Created once", body: "Description", assignToMe: true, optionID: "todo")
        store.createIssue(repository: "test/repo", title: "Created twice", body: "Description", assignToMe: true, optionID: "todo")
        try await waitUntil { !store.isMutating && !store.isLoading }
        let creationCount = await service.creations
        try require(creationCount == 1, "duplicate issue creation was submitted")
        try require(store.creationRevision == 1, "partial creation was not treated as confirmed creation")
        try require(store.createdIssueURL?.absoluteString == "https://github.com/test/repo/issues/2", "partial creation lost the existing issue URL")
        try require(store.mutationNotice?.contains("adding it to the project failed") == true, "partial creation warning was lost")
    }

    @MainActor
    private static func demoFilteringAndDetailSurviveStatusChanges() throws {
        let suite = "IssuesDesktopRegression.demoEditing"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppStore(defaults: defaults, client: FailingFetcher())
        store.enterDemo()
        let mine = store.accountIssues.count
        store.onlyMine = false
        try require(store.accountIssues.count > mine, "Everyone did not include another assignee")
        store.selectedIssueID = "demo-31"
        store.onlyMine = true
        try require((store.webState(mode: "main")["detailIssue"] as? [String: Any])?["id"] as? String == "demo-31", "filtering hid the selected detail")
        store.changeStatus(issueID: "demo-31", optionID: "demo-done")
        try require(store.snapshot?.issues.first(where: { $0.id == "demo-31" })?.status == "Done", "demo status edit failed")
        store.createIssue(repository: "example/web-app", title: "Demo issue", body: String(repeating: "Full paragraph.\n\n", count: 100), assignToMe: false, optionID: "demo-todo")
        try require(store.snapshot?.issues.first?.title == "Demo issue", "demo issue was not created locally")
        try require(store.snapshot?.issues.first?.body.count ?? 0 > 1_000, "long description was truncated")
        try require(store.onlyMine, "creation unexpectedly changed assignment filter")
    }

    @MainActor
    private static func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<600 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw HarnessError.assertion("timed out waiting for asynchronous condition")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw HarnessError.assertion(message) }
    }
}
