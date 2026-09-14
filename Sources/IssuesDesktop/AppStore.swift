import AppKit
import Combine
import IssuesCore

protocol GitHubFetching: Sendable {
    func fetch(project: ProjectReference, authentication: GitHubAuthentication) async throws -> ProjectSnapshot
}

extension GitHubClient: GitHubFetching {}

protocol GitHubMutating: Sendable {
    func updateStatus(projectID: String, itemID: String, fieldID: String, optionID: String?, authentication: GitHubAuthentication) async throws
    func createIssue(projectID: String, repository: String, title: String, body: String, assigneeID: String?, statusFieldID: String?, statusOptionID: String?, authentication: GitHubAuthentication) async throws -> CreatedProjectIssue
}

extension GitHubClient: GitHubMutating {}

protocol GitHubIssueEditing: Sendable {
    func fetchIssueComposer(repository: String, authentication: GitHubAuthentication) async throws -> IssueComposerMetadata
    func createIssue(request: IssueCreationRequest, authentication: GitHubAuthentication) async throws -> CreatedProjectIssue
    func updateAssignees(issueID: String, assigneeIDs: [String], authentication: GitHubAuthentication) async throws -> [IssueChoice]
}

extension GitHubClient: GitHubIssueEditing {}


struct SavedProject: Codable, Equatable, Sendable {
    let url: String
    var title: String
}

struct ProjectStatusVisibility: Equatable, Sendable {
    let name: String
    let visible: Bool
}

@MainActor
final class AppStore: ObservableObject {
    @Published var projectURL = ""
    @Published private(set) var projects: [SavedProject] = []
    @Published var useCLI = true
    @Published var tokenInput = ""
    @Published var onlyMine = true
    @Published var search = ""
    @Published var selectedIssueID: String?
    @Published var pinnedIssueID: String?
    @Published var alwaysOnTop = true
    @Published var showSettings = false
    @Published var inProgressStatuses = "In progress, Doing"
    @Published var todoStatuses = "Todo, To do, Backlog, Ready"
    @Published private(set) var snapshot: ProjectSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isDemo = false
    @Published private(set) var isConfigured = false
    @Published private(set) var hasSavedToken = false
    @Published private(set) var isMutating = false
    @Published private(set) var mutationError: String?
    @Published private(set) var mutationNotice: String?
    @Published private(set) var createdIssueURL: URL?
    @Published private(set) var creationRevision = 0

    @Published private(set) var pendingProjectURL: String?
    @Published private(set) var composerRepository = ""
    @Published private(set) var composerMetadata: IssueComposerMetadata?
    @Published private(set) var composerLoading = false
    @Published private(set) var composerError: String?
    private var composerTask: Task<Void, Never>?
    private var composerGeneration = 0
    @Published private(set) var attachmentError: String?
    @Published private var attachmentRevision = 0
    private var attachmentContexts: [String: [PendingIssueAttachment]] = [:]

    private let defaults: UserDefaults
    private let client: any GitHubFetching
    private let cacheURLOverride: URL?
    private var generation = 0
    private var timer: Timer?
    private var requestTask: Task<Void, Never>?
    private var mutationTask: Task<Void, Never>?
    private var hiddenStatusNamesByProject: [String: Set<String>] = [:]
    private var demoHiddenStatusNamesByProject: [String: Set<String>] = [:]
    private var persistedProjects: [SavedProject] = []
    private var legacyCacheURL: URL {
        if let cacheURLOverride { return cacheURLOverride }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Issues", isDirectory: true).appendingPathComponent("project-cache.json")
    }

    init(defaults: UserDefaults = .standard, client: any GitHubFetching = GitHubClient(), cacheURL: URL? = nil) {
        self.defaults = defaults
        self.client = client
        self.cacheURLOverride = cacheURL
        restoreSession()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.startRefresh() }
        }
        if ProcessInfo.processInfo.arguments.contains("--demo") {
            enterDemo()
        } else if isConfigured {
            startRefresh()
        }
    }

    var accountIssues: [GitHubIssue] {
        guard let snapshot else { return [] }
        return snapshot.issues.filter { !onlyMine || $0.assignees.contains(where: { $0.caseInsensitiveCompare(snapshot.viewerLogin) == .orderedSame }) }
    }
    var filteredIssues: [GitHubIssue] {
        let value = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let hidden = hiddenStatusesForCurrentProject
        return accountIssues.filter {
            !hidden.contains($0.status) &&
            (value.isEmpty || "\($0.title) \($0.number) \($0.repository)".localizedCaseInsensitiveContains(value))
        }
    }
    var inProgressIssues: [GitHubIssue] { accountIssues.filter { group(for: $0) == .inProgress } }
    var pinnedIssue: GitHubIssue? { accountIssues.first { $0.id == pinnedIssueID } }
    var projectTitle: String { snapshot?.title ?? "Your GitHub project" }
    var statusVisibility: [ProjectStatusVisibility] {
        var names: [String] = []
        var seen = Set<String>()
        func append(_ name: String) {
            let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty, seen.insert(key).inserted else { return }
            names.append(name)
        }
        snapshot?.metadata?.statusField?.options.forEach { append($0.name) }
        snapshot?.issues.forEach { append($0.status) }
        names.append("")
        let hidden = hiddenStatusesForCurrentProject
        return names.map { ProjectStatusVisibility(name: $0, visible: !hidden.contains($0)) }
    }
    var lastSyncLabel: String {
        if isDemo { return "Demo · sample data" }
        if isLoading { return "Syncing…" }
        guard let date = snapshot?.fetchedAt else { return "Not synced yet" }
        let formatter = DateFormatter(); formatter.dateStyle = .short; formatter.timeStyle = .short
        return "Updated \(formatter.string(from: date))"
    }
    func group(for issue: GitHubIssue) -> IssueGroup {
        StatusMapping.group(for: issue.status, inProgress: names(inProgressStatuses), todo: names(todoStatuses))
    }
    func issues(in group: IssueGroup) -> [GitHubIssue] { filteredIssues.filter { self.group(for: $0) == group } }
    private func names(_ value: String) -> Set<String> {
        Set(value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
    }

    func setStatusVisibility(name: String, visible: Bool) {
        guard statusVisibility.contains(where: { $0.name == name }) else { return }
        let key = currentProjectKey
        guard !key.isEmpty else { return }
        if isDemo {
            var hidden = demoHiddenStatusNamesByProject[key] ?? []
            if visible { hidden.remove(name) } else { hidden.insert(name) }
            demoHiddenStatusNamesByProject[key] = hidden
        } else {
            var hidden = hiddenStatusNamesByProject[key] ?? []
            if visible { hidden.remove(name) } else { hidden.insert(name) }
            hiddenStatusNamesByProject[key] = hidden
            saveHiddenStatusPreferences()
        }
        objectWillChange.send()
    }

    func startConnect(projectURL proposedURL: String, useCLI proposedCLI: Bool, token proposedToken: String) {
        guard allowSessionChange() else { return }
        clearMutationFeedback()
        cancelRequest()
        guard let project = ProjectReference.parse(proposedURL) else {
            errorMessage = "Enter a valid GitHub Project URL: https://github.com/users/name/projects/1 or /orgs/name/projects/1."
            return
        }
        let epoch = generation
        let inputToken = proposedToken.trimmingCharacters(in: .whitespacesAndNewlines)
        tokenInput = ""
        isLoading = true
        errorMessage = nil
        requestTask = Task { [weak self] in
            await self?.connect(project: project, useCLI: proposedCLI, inputToken: inputToken, epoch: epoch)
        }
    }

    private func connect(project: ProjectReference, useCLI proposedCLI: Bool, inputToken: String, epoch: Int) async {
        do {
            let authentication: GitHubAuthentication
            if proposedCLI { authentication = .cli }
            else {
                let token = inputToken.isEmpty ? try CredentialStore.load() : inputToken
                guard let token, !token.isEmpty else { throw StoreError.message("Enter a GitHub token with access to this project.") }
                authentication = .token(token)
            }
            let result = try await client.fetch(project: project, authentication: authentication)
            try Task.checkCancellation()
            guard epoch == generation else { return }
            guard projectKey(result.project.url.absoluteString) == projectKey(project.url.absoluteString) else {
                throw StoreError.message("GitHub returned a different project. The current project was kept unchanged.")
            }
            if !proposedCLI, !inputToken.isEmpty { try CredentialStore.save(inputToken) }
            hasSavedToken = (try? CredentialStore.load()) != nil
            let canonicalURL = result.project.url.absoluteString
            projectURL = canonicalURL
            useCLI = proposedCLI
            snapshot = result
            isDemo = false
            isConfigured = true
            showSettings = false
            clearProjectTransientState()
            upsertSavedProject(url: canonicalURL, title: result.title)
            savePreferences()
            try saveCache(result)
        } catch is CancellationError {
            // A newer request or lifecycle transition owns the visible state.
        } catch {
            guard epoch == generation else { return }
            errorMessage = error.localizedDescription
        }
        finishRequest(epoch: epoch)
    }

    func selectProject(url: String) {
        guard allowSessionChange() else { return }
        let candidates = isDemo ? projects : persistedProjects
        guard let saved = candidates.first(where: { projectKey($0.url) == projectKey(url) }),
              let project = ProjectReference.parse(saved.url) else { return }
        if requestTask == nil, projectKey(projectURL) == projectKey(saved.url) { return }
        let demo = isDemo
        cancelRequest()
        pendingProjectURL = saved.url
        let epoch = generation
        let cli = useCLI
        isLoading = true
        errorMessage = nil
        requestTask = Task { [weak self] in
            await self?.select(project: project, useCLI: cli, demo: demo, epoch: epoch)
        }
    }

    private func select(project: ProjectReference, useCLI: Bool, demo: Bool, epoch: Int) async {
        do {
            let result: ProjectSnapshot
            if demo {
                result = demoSnapshot(for: project)
            } else {
                result = try await client.fetch(project: project, authentication: try authentication(useCLI: useCLI))
            }
            try Task.checkCancellation()
            guard epoch == generation else { return }
            guard projectKey(result.project.url.absoluteString) == projectKey(project.url.absoluteString) else {
                throw StoreError.message("GitHub returned a different project. The current project was kept unchanged.")
            }
            projectURL = result.project.url.absoluteString
            snapshot = result
            errorMessage = nil
            clearProjectTransientState()
            if demo {
                projects = demoProjects
            } else {
                upsertSavedProject(url: result.project.url.absoluteString, title: result.title)
                savePreferences()
                try saveCache(result)
            }
        } catch is CancellationError {
            // A newer request owns the visible project.
        } catch {
            guard epoch == generation else { return }
            errorMessage = error.localizedDescription
        }
        finishRequest(epoch: epoch)
    }

    func startRefresh() {
        guard requestTask == nil, !isLoading, !isMutating, !isDemo, isConfigured,
              let project = ProjectReference.parse(projectURL) else { return }
        let epoch = generation
        let cli = useCLI
        isLoading = true
        requestTask = Task { [weak self] in
            await self?.refresh(project: project, useCLI: cli, epoch: epoch)
        }
    }

    private func refresh(project: ProjectReference, useCLI: Bool, epoch: Int) async {
        do {
            let authentication: GitHubAuthentication
            if useCLI { authentication = .cli }
            else {
                guard let token = try CredentialStore.load(), !token.isEmpty else { throw StoreError.message("Your token is unavailable. Reconnect GitHub in Settings.") }
                authentication = .token(token)
            }
            let result = try await client.fetch(project: project, authentication: authentication)
            try Task.checkCancellation()
            guard epoch == generation else { return }
            guard projectKey(result.project.url.absoluteString) == projectKey(project.url.absoluteString) else {
                throw StoreError.message("GitHub returned a different project. The current project was kept unchanged.")
            }
            snapshot = result
            errorMessage = nil
            if !result.issues.contains(where: { $0.id == pinnedIssueID }) { pinnedIssueID = nil; savePreferences() }
            try saveCache(result)
        } catch is CancellationError {
            // A newer request or lifecycle transition owns the visible state.
        } catch {
            guard epoch == generation else { return }
            errorMessage = snapshot == nil ? error.localizedDescription : "Showing the last saved update. \(error.localizedDescription)"
        }
        finishRequest(epoch: epoch)
    }

    func disconnect() {
        guard allowSessionChange() else { return }
        if isDemo { leaveDemo(); return }
        clearMutationFeedback()
        cancelRequest()
        let removedURL = projectURL
        let removedKey = projectKey(removedURL)
        attachmentContexts = attachmentContexts.filter { !$0.key.hasPrefix(removedKey + "|") }
        attachmentRevision += 1
        let isLastProject = persistedProjects.filter { projectKey($0.url) != removedKey }.isEmpty
        if isLastProject {
            do { try CredentialStore.delete() }
            catch { errorMessage = "Could not remove the token from Keychain: \(error.localizedDescription)"; return }
        }
        persistedProjects.removeAll { projectKey($0.url) == removedKey }
        projects = persistedProjects
        hiddenStatusNamesByProject.removeValue(forKey: removedKey)
        savePersistedProjects()
        saveHiddenStatusPreferences()
        try? removeCache(for: removedURL)

        if let next = persistedProjects.first, let reference = ProjectReference.parse(next.url) {
            projectURL = reference.url.absoluteString
            snapshot = loadCache(for: reference)
            isConfigured = true; isLoading = false; isDemo = false
            errorMessage = nil; showSettings = false; tokenInput = ""
            clearProjectTransientState()
            savePreferences()
            startRefresh()
            return
        }

        hasSavedToken = false
        isConfigured = false; isLoading = false; isDemo = false
        snapshot = nil; pinnedIssueID = nil; selectedIssueID = nil; search = ""; tokenInput = ""
        projectURL = ""; errorMessage = nil; showSettings = false
        defaults.removeObject(forKey: "projectURL")
        defaults.removeObject(forKey: "pinnedIssueID")
        try? removeLegacyCache()
    }

    func savePreferences() {
        guard !isDemo else { return }
        if isConfigured {
            defaults.set(projectURL, forKey: "projectURL")
            defaults.set(useCLI, forKey: "useCLI")
            savePersistedProjects()
        }
        defaults.set(onlyMine, forKey: "onlyMine")
        defaults.set(alwaysOnTop, forKey: "alwaysOnTop")
        defaults.set(pinnedIssueID, forKey: "pinnedIssueID")
        defaults.set(inProgressStatuses, forKey: "inProgressStatuses")
        defaults.set(todoStatuses, forKey: "todoStatuses")
    }
    func pin(_ issue: GitHubIssue) {
        pinnedIssueID = issue.id
        savePreferences()
        NotificationCenter.default.post(name: .issuesShowFocus, object: nil)
    }
    func openOnGitHub(_ issue: GitHubIssue) {
        guard issue.url.scheme == "https", issue.url.host == "github.com" else { return }
        NSWorkspace.shared.open(issue.url)
    }
    func openProject() { if let project = snapshot?.project, !isDemo { NSWorkspace.shared.open(project.url) } }

    func enterDemo() {
        guard allowSessionChange() else { return }
        clearMutationFeedback()
        cancelRequest()
        isDemo = true; isConfigured = true; errorMessage = nil; showSettings = false
        selectedIssueID = nil; search = ""; onlyMine = true
        inProgressStatuses = "In progress, Doing"; todoStatuses = "Todo, To do, Backlog, Ready"
        projects = demoProjects
        projectURL = demoProjects[0].url
        snapshot = demoSnapshot(for: ProjectReference(owner: "demo", number: 1, isOrganization: false))
        pinnedIssueID = "demo-42"
    }
    func leaveDemo() {
        guard allowSessionChange() else { return }
        clearMutationFeedback()
        cancelRequest()
        isDemo = false; errorMessage = nil; showSettings = false; search = ""; selectedIssueID = nil
        restoreSession()
        if isConfigured { startRefresh() }
    }

    private func cancelRequest() {
        pendingProjectURL = nil
        cancelComposerLoad(clear: false)
        generation += 1
        requestTask?.cancel()
        requestTask = nil
        isLoading = false
    }

    private func allowSessionChange() -> Bool {
        guard !isMutating else {
            mutationError = "Please wait for the GitHub update to finish before switching projects or accounts."
            return false
        }
        return true
    }

    func clearMutationFeedback() {
        guard !isMutating else { return }
        mutationError = nil; mutationNotice = nil; createdIssueURL = nil
    }

    private func authentication() throws -> GitHubAuthentication {
        try authentication(useCLI: useCLI)
    }

    func changeStatus(issueID: String, optionID: String) {
        guard !isMutating else { return }
        guard pendingProjectURL == nil else { mutationError = "Wait for the selected project to finish loading."; return }
        clearMutationFeedback()
        guard let issue = snapshot?.issues.first(where: { $0.id == issueID }),
              let metadata = snapshot?.metadata, let field = metadata.statusField,
              optionID.isEmpty || field.options.contains(where: { $0.id == optionID }) else {
            mutationError = "Refresh the project to load its available status options."
            return
        }
        let option = field.options.first { $0.id == optionID }
        if isDemo {
            setLocalStatus(issueID: issueID, name: option?.name ?? "")
            mutationNotice = "Status updated in demo."
            return
        }
        guard let itemID = issue.projectItemID, let writer = client as? any GitHubMutating else {
            mutationError = "Refresh this issue before changing its project status."
            return
        }
        cancelRequest()
        isMutating = true
        mutationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await writer.updateStatus(projectID: metadata.id, itemID: itemID, fieldID: field.id,
                                              optionID: optionID.isEmpty ? nil : optionID, authentication: self.authentication())
                self.setLocalStatus(issueID: issueID, name: option?.name ?? "")
                self.mutationError = nil
                self.mutationNotice = "Status saved to GitHub."
                self.saveMutationCache()
            } catch { self.mutationError = error.localizedDescription }
            self.isMutating = false; self.mutationTask = nil
            self.startRefresh()
        }
    }

    func createIssue(repository rawRepository: String, title rawTitle: String, body: String, assignToMe: Bool, optionID: String) {
        guard !isMutating else { return }
        guard pendingProjectURL == nil else { mutationError = "Wait for the selected project to finish loading."; return }
        clearMutationFeedback()
        let repository = rawRepository.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = repository.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2, components.allSatisfy({ !$0.isEmpty && $0.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil }) else {
            mutationError = "Enter a repository in owner/repository format."
            return
        }
        guard !title.isEmpty, title.count <= 256, body.utf8.count <= 65_536 else {
            mutationError = "Add a title of up to 256 characters and a description smaller than 64 KB."
            return
        }
        guard let metadata = snapshot?.metadata, !metadata.id.isEmpty else {
            mutationError = "Connect and refresh your project before creating an issue."
            return
        }
        guard optionID.isEmpty || metadata.statusField?.options.contains(where: { $0.id == optionID }) == true else {
            mutationError = "Choose an available project status."
            return
        }
        guard !assignToMe || metadata.viewerID != nil else {
            mutationError = "Refresh your GitHub profile before assigning the issue to yourself."
            return
        }
        let statusName = metadata.statusField?.options.first(where: { $0.id == optionID })?.name ?? ""
        if isDemo {
            let number = (snapshot?.issues.map(\.number).max() ?? 0) + 1
            let issue = GitHubIssue(id: "demo-\(UUID().uuidString)", number: number, title: title, body: body,
                url: URL(string: "https://github.com/\(repository)/issues/\(number)")!, repository: repository, status: statusName,
                labels: [], assignees: assignToMe ? [snapshot?.viewerLogin ?? "demo"] : [], updatedAt: Date(), projectItemID: "demo-item-\(number)")
            snapshot?.issues.insert(issue, at: 0)
            creationRevision += 1
            mutationNotice = "Issue created in demo. Nothing was sent to GitHub."
            return
        }
        guard let writer = client as? any GitHubMutating else {
            mutationError = "This connection does not support issue creation."
            return
        }
        cancelRequest()
        isMutating = true
        mutationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await writer.createIssue(projectID: metadata.id, repository: repository, title: title,
                    body: body, assigneeID: assignToMe ? metadata.viewerID : nil,
                    statusFieldID: metadata.statusField?.id, statusOptionID: optionID.isEmpty ? nil : optionID,
                    authentication: self.authentication())
                self.createdIssueURL = result.url
                self.mutationError = nil
                self.creationRevision += 1
                self.mutationNotice = result.warning ?? "Issue created and added to the project."
                if self.onlyMine && !assignToMe { self.mutationNotice! += " Switch to Everyone to see unassigned issues." }
            } catch { self.mutationError = error.localizedDescription }
            self.isMutating = false; self.mutationTask = nil
            self.startRefresh()
        }
    }

    private func setLocalStatus(issueID: String, name: String) {
        guard let index = snapshot?.issues.firstIndex(where: { $0.id == issueID }) else { return }
        snapshot?.issues[index].status = name
        snapshot?.issues[index].updatedAt = Date()
    }

    private func saveMutationCache() {
        guard let snapshot, !isDemo else { return }
        do { try saveCache(snapshot) }
        catch { mutationNotice = "Saved to GitHub. The local cache could not be updated." }
    }

    func openCreatedIssue() {
        guard let url = createdIssueURL, url.scheme == "https", url.host == "github.com", !isDemo else { return }
        NSWorkspace.shared.open(url)
    }

    private func finishRequest(epoch: Int) {
        guard epoch == generation else { return }
        pendingProjectURL = nil
        requestTask = nil
        isLoading = false
    }
    private func restoreSession() {
        let restoredURL = defaults.string(forKey: "projectURL") ?? ""
        useCLI = defaults.object(forKey: "useCLI") as? Bool ?? true
        onlyMine = defaults.object(forKey: "onlyMine") as? Bool ?? true
        alwaysOnTop = defaults.object(forKey: "alwaysOnTop") as? Bool ?? true
        pinnedIssueID = defaults.string(forKey: "pinnedIssueID")
        inProgressStatuses = defaults.string(forKey: "inProgressStatuses") ?? "In progress, Doing"
        todoStatuses = defaults.string(forKey: "todoStatuses") ?? "Todo, To do, Backlog, Ready"
        hasSavedToken = (try? CredentialStore.load()) != nil
        hiddenStatusNamesByProject = loadHiddenStatusPreferences()

        var restoredProjects = loadPersistedProjects()
        let legacySnapshot = loadSnapshot(at: legacyCacheURL)
        if let reference = ProjectReference.parse(restoredURL),
           !restoredProjects.contains(where: { projectKey($0.url) == projectKey(reference.url.absoluteString) }) {
            let title = legacySnapshot?.project == reference ? legacySnapshot?.title : nil
            restoredProjects.append(SavedProject(url: reference.url.absoluteString, title: title ?? fallbackTitle(for: reference)))
        }
        persistedProjects = deduplicatedProjects(restoredProjects)
        projects = persistedProjects
        if let matching = persistedProjects.first(where: { projectKey($0.url) == projectKey(restoredURL) }) {
            projectURL = matching.url
        } else {
            projectURL = persistedProjects.first?.url ?? ""
        }
        isConfigured = ProjectReference.parse(projectURL) != nil
        snapshot = ProjectReference.parse(projectURL).flatMap(loadCache(for:))
        if isConfigured { savePersistedProjects() }
    }
    private func saveCache(_ result: ProjectSnapshot) throws {
        let cacheURL = cacheFileURL(for: result.project.url.absoluteString)
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(result)
        try data.write(to: cacheURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
    }

    private var currentProjectKey: String { projectKey(projectURL) }
    private var hiddenStatusesForCurrentProject: Set<String> {
        isDemo ? demoHiddenStatusNamesByProject[currentProjectKey] ?? [] : hiddenStatusNamesByProject[currentProjectKey] ?? []
    }

    private func projectKey(_ url: String) -> String {
        guard let reference = ProjectReference.parse(url) else { return "" }
        return reference.url.absoluteString.lowercased()
    }

    private func fallbackTitle(for project: ProjectReference) -> String {
        "\(project.owner) · Project \(project.number)"
    }

    private func deduplicatedProjects(_ values: [SavedProject]) -> [SavedProject] {
        var result: [SavedProject] = []
        var indices: [String: Int] = [:]
        for value in values {
            guard let reference = ProjectReference.parse(value.url) else { continue }
            let key = projectKey(reference.url.absoluteString)
            let normalized = SavedProject(url: reference.url.absoluteString,
                                          title: value.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallbackTitle(for: reference) : value.title)
            if let index = indices[key] { result[index] = normalized }
            else { indices[key] = result.count; result.append(normalized) }
        }
        return result
    }

    private func upsertSavedProject(url: String, title: String) {
        persistedProjects = deduplicatedProjects(persistedProjects + [SavedProject(url: url, title: title)])
        projects = persistedProjects
        savePersistedProjects()
    }

    private func loadPersistedProjects() -> [SavedProject] {
        guard let data = defaults.data(forKey: "savedProjectsV1"),
              let values = try? JSONDecoder().decode([SavedProject].self, from: data) else { return [] }
        return values
    }

    private func savePersistedProjects() {
        guard !isDemo, let data = try? JSONEncoder().encode(persistedProjects) else { return }
        defaults.set(data, forKey: "savedProjectsV1")
    }

    private func loadHiddenStatusPreferences() -> [String: Set<String>] {
        guard let data = defaults.data(forKey: "hiddenStatusNamesByProjectV1"),
              let values = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return values.mapValues(Set.init)
    }

    private func saveHiddenStatusPreferences() {
        guard !isDemo else { return }
        let values = hiddenStatusNamesByProject.mapValues { Array($0).sorted() }
        if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: "hiddenStatusNamesByProjectV1") }
    }

    private func cacheFileURL(for projectURL: String) -> URL {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in projectKey(projectURL).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return legacyCacheURL.deletingLastPathComponent()
            .appendingPathComponent("project-caches", isDirectory: true)
            .appendingPathComponent(String(format: "%016llx.json", hash))
    }

    private func loadSnapshot(at url: URL) -> ProjectSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ProjectSnapshot.self, from: data)
    }

    private func loadCache(for project: ProjectReference) -> ProjectSnapshot? {
        let specificURL = cacheFileURL(for: project.url.absoluteString)
        if let saved = loadSnapshot(at: specificURL), saved.project == project { return saved }
        guard let legacy = loadSnapshot(at: legacyCacheURL), legacy.project == project else { return nil }
        try? saveCache(legacy)
        return legacy
    }

    private func removeCache(for projectURL: String) throws {
        let url = cacheFileURL(for: projectURL)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    private func removeLegacyCache() throws {
        if FileManager.default.fileExists(atPath: legacyCacheURL.path) { try FileManager.default.removeItem(at: legacyCacheURL) }
    }

    private func clearProjectTransientState() {
        cancelComposerLoad(clear: true)
        selectedIssueID = nil
        pinnedIssueID = nil
        search = ""
        mutationError = nil
        mutationNotice = nil
        createdIssueURL = nil
    }

    private func authentication(useCLI: Bool) throws -> GitHubAuthentication {
        if useCLI { return .cli }
        guard let token = try CredentialStore.load(), !token.isEmpty else {
            throw StoreError.message("Your GitHub token is unavailable. Reconnect in Settings.")
        }
        return .token(token)
    }

    private var demoProjects: [SavedProject] {
        [
            SavedProject(url: ProjectReference(owner: "demo", number: 1, isOrganization: false).url.absoluteString,
                         title: "Website · Current sprint"),
            SavedProject(url: ProjectReference(owner: "demo", number: 2, isOrganization: false).url.absoluteString,
                         title: "Mobile app · Launch")
        ]
    }

    private func demoSnapshot(for project: ProjectReference) -> ProjectSnapshot {
        if project.number == 2 {
            let field = ProjectStatusField(id: "demo-mobile-status", name: "Status", options: [
                ProjectStatusOption(id: "demo-ready", name: "Ready"),
                ProjectStatusOption(id: "demo-review", name: "In review"),
                ProjectStatusOption(id: "demo-mobile-done", name: "Done")
            ])
            let values: [(Int, String, String)] = [
                (18, "Prepare App Store screenshots", "Ready"),
                (16, "Review onboarding analytics", "In review"),
                (12, "Finish accessibility labels", "Done"),
                (9, "Choose the launch note", "")
            ]
            let issues = values.map { number, title, status in
                GitHubIssue(id: "demo-mobile-\(number)", number: number, title: title, body: "Demo project item.",
                    url: URL(string: "https://github.com/example/mobile/issues/\(number)")!, repository: "example/mobile",
                    status: status, labels: ["launch"], assignees: ["demo"], updatedAt: Date(), projectItemID: "demo-mobile-item-\(number)")
            }
            return ProjectSnapshot(project: project, title: "Mobile app · Launch", viewerLogin: "demo", issues: issues, fetchedAt: Date(),
                metadata: ProjectMetadata(id: "demo-mobile-project", statusField: field, repositories: ["example/mobile"], viewerID: "demo-viewer"))
        }

        let examples: [(Int, String, String, String, String)] = [
            (42, "Fix GitHub sign-in", "web-app", "bug", "After returning from GitHub, restore the page where sign-in started."),
            (38, "Refine mobile navigation", "web-app", "interface", "Keep menu spacing and behavior consistent on smaller screens."),
            (47, "Add the project empty state", "web-app", "interface", "Show a helpful message when a project has no items yet."),
            (45, "Fix search filters", "web-app", "bug", "Preserve selected filters when returning to search results."),
            (36, "Build the settings page", "web-app", "feature", "Bring account preferences together in a simple settings page."),
            (31, "Update the installation guide", "docs", "documentation", "Review the first steps and requirements for running the project.")
        ]
        let issues = examples.enumerated().map { offset, value in
            GitHubIssue(id: "demo-\(value.0)", number: value.0, title: value.1, body: value.4,
                        url: URL(string: "https://github.com")!, repository: value.2,
                        status: offset < 2 ? "In progress" : "Todo", labels: [value.3],
                        assignees: offset == 5 ? ["teammate"] : ["demo"], updatedAt: Date(), projectItemID: "demo-item-\(value.0)")
        }
        let field = ProjectStatusField(id: "demo-status", name: "Status", options: [
            ProjectStatusOption(id: "demo-todo", name: "Todo"),
            ProjectStatusOption(id: "demo-progress", name: "In progress"),
            ProjectStatusOption(id: "demo-done", name: "Done")
        ])
        return ProjectSnapshot(project: project, title: "Website · Current sprint", viewerLogin: "demo", issues: issues, fetchedAt: Date(),
            metadata: ProjectMetadata(id: "demo-project", statusField: field, repositories: ["example/web-app", "example/docs"], viewerID: "demo-viewer"))
    }

    func webState(mode: String) -> [String: Any] {
        func issueState(_ issue: GitHubIssue) -> [String: Any] {
            ["id": issue.id, "number": issue.number, "title": issue.title, "body": issue.body,
             "url": issue.url.absoluteString, "repository": issue.repository, "status": issue.status,
             "labels": issue.labels, "assignees": issue.assignees, "group": group(for: issue).rawValue]
        }
        let rows = accountIssues.map(issueState)
        let selectedIssue = snapshot?.issues.first { $0.id == selectedIssueID }
        let detail = selectedIssue.map(issueState)
        let metadata = snapshot?.metadata
        let canEditStatus = selectedIssue != nil && (isDemo || (
            metadata?.id.isEmpty == false && metadata?.statusField?.id.isEmpty == false &&
            selectedIssue?.projectItemID?.isEmpty == false
        ))
        let options: [[String: String]] = metadata?.statusField?.options.map { ["id": $0.id, "name": $0.name] } ?? []
        let projectRows = projects.map { ["url": $0.url, "title": $0.title] }
        let visibilityRows: [[String: Any]] = statusVisibility.map { ["name": $0.name, "visible": $0.visible] }
        return ["mode": mode, "projectTitle": projectTitle, "projectURL": projectURL,
                "pendingProjectURL": pendingProjectURL as Any? ?? NSNull(),
                "viewerLogin": snapshot?.viewerLogin ?? "", "isConfigured": isConfigured,
                "isDemo": isDemo, "isLoading": isLoading, "errorMessage": errorMessage as Any? ?? NSNull(),
                "lastSyncLabel": lastSyncLabel, "onlyMine": onlyMine, "search": search,
                "selectedIssueID": selectedIssueID as Any? ?? NSNull(), "pinnedIssueID": pinnedIssueID as Any? ?? NSNull(),
                "alwaysOnTop": alwaysOnTop, "showSettings": showSettings, "useCLI": useCLI,
                "hasSavedToken": hasSavedToken, "inProgressStatuses": inProgressStatuses,
                "todoStatuses": todoStatuses, "projects": projectRows,
                "statusVisibility": visibilityRows, "issues": rows,
                "detailIssue": detail as Any? ?? NSNull(), "statusOptions": options,
                "statusFieldName": metadata?.statusField?.name ?? "Status",
                "canEditStatus": canEditStatus,
                "repositories": metadata?.repositories ?? [],
                "isMutating": isMutating, "mutationError": mutationError as Any? ?? NSNull(),
                "mutationNotice": mutationNotice as Any? ?? NSNull(),
                "createdIssueURL": createdIssueURL?.absoluteString as Any? ?? NSNull(),
                "creationRevision": creationRevision,
                "composerRepository": composerRepository,
                "composerLoading": composerLoading,
                "composerError": composerError as Any? ?? NSNull(),
                "attachmentError": attachmentError as Any? ?? NSNull(),
                "composerAttachments": currentAttachments.map { ["id": $0.id, "name": $0.url.lastPathComponent, "size": $0.size] as [String: Any] },
                "composerMetadata": composerMetadata.flatMap { try? JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) } ?? NSNull()]
    }
}

private enum StoreError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let value): return value } }
}

extension Notification.Name { static let issuesShowFocus = Notification.Name("IssuesShowFocus") }


extension AppStore {
    private func cancelComposerLoad(clear: Bool) {
        composerGeneration += 1
        composerTask?.cancel(); composerTask = nil; composerLoading = false
        if clear { composerRepository = ""; composerMetadata = nil; composerError = nil }
    }

    func loadComposer(repository raw: String) {
        let repository = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard repository.range(of: "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", options: .regularExpression) != nil else {
            cancelComposerLoad(clear: true)
            composerError = "Choose a repository in owner/repository format."
            return
        }
        if composerRepository.caseInsensitiveCompare(repository) == .orderedSame,
           composerMetadata != nil || composerLoading { return }
        cancelComposerLoad(clear: true)
        composerRepository = repository
        attachmentError = nil
        if isDemo { composerMetadata = demoComposer(repository: repository); return }
        guard let service = client as? any GitHubIssueEditing else {
            composerError = "This connection does not support issue metadata."
            return
        }
        let epoch = composerGeneration
        let projectEpoch = generation
        composerLoading = true
        composerTask = Task { [weak self] in
            guard let self else { return }
            do {
                let metadata = try await service.fetchIssueComposer(repository: repository, authentication: self.authentication())
                try Task.checkCancellation()
                guard epoch == self.composerGeneration, projectEpoch == self.generation else { return }
                guard metadata.repository.caseInsensitiveCompare(repository) == .orderedSame else {
                    throw StoreError.message("GitHub returned metadata for a different repository. Try again.")
                }
                self.composerMetadata = metadata
            } catch is CancellationError { }
            catch {
                guard epoch == self.composerGeneration, projectEpoch == self.generation else { return }
                self.composerError = error.localizedDescription
            }
            guard epoch == self.composerGeneration else { return }
            self.composerLoading = false; self.composerTask = nil
        }
    }

    func updateAssignees(issueID: String, assigneeIDs: [String]) {
        guard !isMutating else { return }
        guard pendingProjectURL == nil else { mutationError = "Wait for the selected project to finish loading."; return }
        clearMutationFeedback()
        guard let issue = snapshot?.issues.first(where: { $0.id == issueID }),
              let metadata = composerMetadata,
              metadata.repository.caseInsensitiveCompare(issue.repository) == .orderedSame,
              Set(assigneeIDs).isSubset(of: Set(metadata.assignees.map(\.id))), assigneeIDs.count <= 10 else {
            mutationError = "Load this repository's assignable users before saving."
            return
        }
        let selected = metadata.assignees.filter { assigneeIDs.contains($0.id) }
        if isDemo {
            applyAssignees(issueID: issueID, users: selected)
            mutationNotice = "Assignees updated in demo."
            return
        }
        guard let service = client as? any GitHubIssueEditing else { return }
        cancelRequest(); isMutating = true
        mutationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let users = try await service.updateAssignees(issueID: issueID, assigneeIDs: Array(Set(assigneeIDs)), authentication: self.authentication())
                self.applyAssignees(issueID: issueID, users: users)
                self.mutationError = nil; self.mutationNotice = "Assignees saved to GitHub."
                self.saveMutationCache()
            } catch { self.mutationError = error.localizedDescription }
            self.isMutating = false; self.mutationTask = nil; self.startRefresh()
        }
    }

    private func applyAssignees(issueID: String, users: [IssueChoice]) {
        guard let index = snapshot?.issues.firstIndex(where: { $0.id == issueID }) else { return }
        snapshot?.issues[index].assignees = users.map(\.name)
        snapshot?.issues[index].updatedAt = Date()
    }

    func createComposedIssue(_ message: [String: Any]) {
        guard !isMutating else { return }
        guard pendingProjectURL == nil else { mutationError = "Wait for the selected project to finish loading."; return }
        clearMutationFeedback()
        let repository = (message["repository"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (message["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let body = message["body"] as? String ?? ""
        guard let project = snapshot?.metadata, !project.id.isEmpty,
              let metadata = composerMetadata, metadata.repository.caseInsensitiveCompare(repository) == .orderedSame else {
            mutationError = "Wait for this repository's options to load before creating an issue."
            return
        }
        guard !title.isEmpty, title.count <= 256, body.utf8.count <= 65_536 else {
            mutationError = "Add a title of up to 256 characters and a description smaller than 64 KB."
            return
        }
        func values(_ key: String) -> [String] { Array(Set(message[key] as? [String] ?? [])).sorted() }
        func optional(_ key: String) -> String? {
            let value = (message[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        var assignees = values("assigneeIDs")
        if message["assignToMe"] as? Bool == true, let id = project.viewerID, !assignees.contains(id) { assignees.append(id) }
        let labels = values("labelIDs"), extraProjects = values("additionalProjectIDs")
        let milestone = optional("milestoneID"), type = optional("issueTypeID"), template = optional("templateFilename")
        let status = optional("optionID")
        guard Set(assignees).isSubset(of: Set(metadata.assignees.map(\.id))), assignees.count <= 10,
              Set(labels).isSubset(of: Set(metadata.labels.map(\.id))),
              Set(extraProjects).isSubset(of: Set(metadata.projects.map(\.id))),
              milestone == nil || metadata.milestones.contains(where: { $0.id == milestone }),
              type == nil || metadata.issueTypes.contains(where: { $0.id == type }),
              template == nil || metadata.templates.contains(where: { $0.filename == template }),
              status == nil || project.statusField?.options.contains(where: { $0.id == status }) == true else {
            mutationError = "Some selections belong to another repository or are no longer available. Reload the options."
            return
        }
        let request = IssueCreationRequest(projectID: project.id, repository: repository, title: title, body: body,
            assigneeIDs: assignees, labelIDs: labels, milestoneID: milestone, issueTypeID: type,
            templateFilename: template, additionalProjectIDs: extraProjects, parentIssue: optional("parentIssue"),
            blockedBy: values("blockedBy"), blocking: values("blocking"),
            statusFieldID: project.statusField?.id, statusOptionID: status)
        if isDemo {
            let number = (snapshot?.issues.map(\.number).max() ?? 0) + 1
            let issue = GitHubIssue(id: "demo-\(UUID().uuidString)", number: number, title: title, body: body,
                url: URL(string: "https://github.com/\(repository)/issues/\(number)")!, repository: repository,
                status: project.statusField?.options.first(where: { $0.id == status })?.name ?? "",
                labels: metadata.labels.filter { labels.contains($0.id) }.map(\.name),
                assignees: metadata.assignees.filter { assignees.contains($0.id) }.map(\.name),
                updatedAt: Date(), projectItemID: "demo-item-\(number)")
            snapshot?.issues.insert(issue, at: 0); creationRevision += 1
            attachmentContexts.removeValue(forKey: currentAttachmentContext); attachmentRevision += 1
            mutationNotice = "Issue created in demo. Nothing was sent to GitHub."
            return
        }
        guard let service = client as? any GitHubIssueEditing else { mutationError = "This connection does not support issue creation."; return }
        let attachmentContext = currentAttachmentContext
        let attachments = currentAttachments
        cancelRequest(); isMutating = true
        mutationTask = Task { [weak self] in
            guard let self else { return }
            var creationStarted = false
            do {
                var prepared = request
                for attachment in attachments {
                    let url: String
                    if let uploaded = attachment.uploadedURL { url = uploaded }
                    else {
                        url = try await IssueAttachmentClient().upload(repository: repository, fileURL: attachment.url, authentication: self.authentication())
                        if let index = self.attachmentContexts[attachmentContext]?.firstIndex(where: { $0.id == attachment.id }) {
                            self.attachmentContexts[attachmentContext]?[index].uploadedURL = url
                        }
                    }
                    let name = attachment.url.lastPathComponent.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]").replacingOccurrences(of: "\n", with: " ")
                    let video = ["mp4", "mov", "webm"].contains(attachment.url.pathExtension.lowercased())
                    prepared.body += "\n\n" + (video ? url : "![\(name)](\(url))")
                }
                guard prepared.body.utf8.count <= 65_536 else { throw StoreError.message("The description with attachments exceeds 64 KB. Shorten it before creating the issue.") }
                creationStarted = true
                let result = try await service.createIssue(request: prepared, authentication: self.authentication())
                self.attachmentContexts.removeValue(forKey: attachmentContext); self.attachmentRevision += 1
                self.createdIssueURL = result.url; self.creationRevision += 1; self.mutationError = nil
                self.mutationNotice = result.warning ?? "Issue created and added to the project."
                if self.onlyMine && !assignees.contains(project.viewerID ?? "") {
                    self.mutationNotice! += " Switch to Everyone to see issues assigned to others."
                }
            } catch {
                self.mutationError = error.localizedDescription + (creationStarted ? "" : " No issue was created.")
            }
            self.isMutating = false; self.mutationTask = nil; self.startRefresh()
        }
    }

    func openComposerOnGitHub(_ message: [String: Any]) {
        guard !isMutating else { return }
        let repository = (message["repository"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard repository.range(of: "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", options: .regularExpression) != nil else { return }
        var url = URLComponents(string: "https://github.com/\(repository)/issues/new")!
        var items: [URLQueryItem] = []
        for key in ["title", "body"] {
            if let value = message[key] as? String, !value.isEmpty { items.append(URLQueryItem(name: key, value: value)) }
        }
        if let template = message["templateFilename"] as? String, !template.isEmpty {
            items.append(URLQueryItem(name: "template", value: template))
        }
        if let metadata = composerMetadata, metadata.repository.caseInsensitiveCompare(repository) == .orderedSame {
            for (key, name, choices) in [("assigneeIDs", "assignees", metadata.assignees), ("labelIDs", "labels", metadata.labels)] {
                let ids = message[key] as? [String] ?? []
                let names = choices.filter { ids.contains($0.id) }.map(\.name)
                if !names.isEmpty { items.append(URLQueryItem(name: name, value: names.joined(separator: ","))) }
            }
            if let id = message["milestoneID"] as? String, let choice = metadata.milestones.first(where: { $0.id == id }) {
                items.append(URLQueryItem(name: "milestone", value: choice.name))
            }
        }
        var projectNames: [String] = []
        if let project = snapshot?.project { projectNames.append("\(project.owner)/\(project.number)") }
        if let metadata = composerMetadata, metadata.repository.caseInsensitiveCompare(repository) == .orderedSame {
            let selected = Set(message["additionalProjectIDs"] as? [String] ?? [])
            for item in metadata.projects where selected.contains(item.id) {
                if let project = ProjectReference.parse(item.url) {
                    let name = "\(project.owner)/\(project.number)"
                    if !projectNames.contains(name) { projectNames.append(name) }
                }
            }
        }
        if !projectNames.isEmpty { items.append(URLQueryItem(name: "projects", value: projectNames.joined(separator: ","))) }
        url.queryItems = items
        if (url.url?.absoluteString.utf8.count ?? 0) > 7_000, let body = message["body"] as? String {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(body, forType: .string)
            url.queryItems = items.filter { $0.name != "body" }
            mutationNotice = "Your description was copied. Paste it into GitHub to continue; the draft is still here."
        }
        if let target = url.url, !NSWorkspace.shared.open(target) {
            mutationError = "Could not open GitHub. Your draft is still available here."
        }
    }

    private func demoComposer(repository: String) -> IssueComposerMetadata {
        let me = IssueChoice(id: snapshot?.metadata?.viewerID ?? "demo-viewer", name: snapshot?.viewerLogin ?? "demo")
        return IssueComposerMetadata(repository: repository, repositoryID: "demo-repository", assignees: [me, IssueChoice(id: "demo-teammate", name: "teammate")],
            labels: [IssueChoice(id: "demo-bug", name: "bug"), IssueChoice(id: "demo-enhancement", name: "enhancement")],
            milestones: [IssueChoice(id: "demo-milestone", name: "Next release")],
            issueTypes: [IssueChoice(id: "demo-task", name: "Task"), IssueChoice(id: "demo-feature", name: "Feature")],
            projects: projects.enumerated().map { ComposerProject(id: "demo-project-\($0.offset + 1)", title: $0.element.title, url: $0.element.url) },
            templates: [ComposerTemplate(filename: "bug_report.md", name: "Bug report", about: "Describe a reproducible problem", body: "## What happened?\n\n## Steps to reproduce\n\n## Expected behavior\n", title: "", assigneeIDs: [], labelIDs: ["demo-bug"], issueTypeID: "demo-task")],
            canWrite: true, warnings: [])
    }
}


private struct PendingIssueAttachment {
    let id: String
    let url: URL
    let size: Int
    var uploadedURL: String?
}

extension AppStore {
    private var currentAttachmentContext: String { projectKey(projectURL) + "|" + composerRepository.lowercased() }
    private var currentAttachments: [PendingIssueAttachment] { attachmentContexts[currentAttachmentContext] ?? [] }
    var canChooseAttachments: Bool { !isMutating && composerMetadata?.canWrite == true && !composerLoading }

    func addAttachments(_ urls: [URL]) {
        guard canChooseAttachments else { attachmentError = "Choose a repository with write access before adding images or videos."; return }
        attachmentError = nil
        var values = currentAttachments
        for url in urls {
            do { try IssueAttachmentClient.validate(fileURL: url) }
            catch { attachmentError = error.localizedDescription; continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard !values.contains(where: { $0.url == url }) else { continue }
            guard values.count < 10 else { attachmentError = "Attach up to 10 files to one issue."; break }
            values.append(PendingIssueAttachment(id: UUID().uuidString, url: url, size: size))
        }
        attachmentContexts[currentAttachmentContext] = values; attachmentRevision += 1
    }

    func removeAttachment(id: String) {
        guard !isMutating else { return }
        attachmentContexts[currentAttachmentContext]?.removeAll { $0.id == id }
        attachmentRevision += 1; attachmentError = nil
    }
}
