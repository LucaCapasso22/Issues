import Foundation

public enum GitHubAuthentication: Sendable {
    case cli
    case token(String)
}

public enum GitHubClientError: Error, LocalizedError, Sendable {
    case invalidToken
    case invalidRepository
    case authenticationFailed
    case projectAccessDenied
    case projectWriteAccessDenied
    case repositoryIssuesWriteAccessDenied(String)
    case issueCreationUncertain(String)
    case invalidResponse
    case graphQL(String)
    case transport(String)
    case cliUnavailable
    case cliTimedOut
    case cliFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidToken:
            return "The GitHub token is empty. Enter a token that can access the project."
        case .invalidRepository:
            return "Enter a repository as owner/name."
        case .authenticationFailed:
            return "GitHub authentication failed. Check the token or run `gh auth status`."
        case .projectAccessDenied:
            return "The project is not accessible. Grant the `read:project` scope (and `read:org` if the organization requires it), or run `gh auth refresh -s read:project`."
        case .projectWriteAccessDenied:
            return "GitHub denied the project change. Grant the `project` scope and project write access, and make sure the token also has repository Issues write access when creating an issue."
        case .repositoryIssuesWriteAccessDenied(let repository):
            return "GitHub cannot create an issue in \(repository). Make sure Issues are enabled, grant repository Issues write access, and grant the `project` scope to add it to the project."
        case .issueCreationUncertain(let detail):
            return "GitHub did not confirm whether the issue was created. Check the repository before retrying to avoid a duplicate. \(detail)"
        case .invalidResponse:
            return "GitHub returned an invalid response. Try again shortly."
        case .graphQL(let message):
            return "GitHub GraphQL: \(message)"
        case .transport(let message):
            return "Could not connect to GitHub: \(message)"
        case .cliUnavailable:
            return "GitHub CLI is unavailable. Install `gh` or choose token authentication."
        case .cliTimedOut:
            return "GitHub CLI did not respond within 20 seconds. Check `gh auth status` and try again."
        case .cliFailed(let message):
            return "GitHub CLI did not complete the request: \(message). Check `gh auth status`; reads need `read:project`, while changes need `project` and repository Issues write access."
        }
    }
}

typealias GitHubTokenTransport = @Sendable (URLRequest) async throws -> (Data, Int)
typealias GitHubCLITransport = @Sendable (Data) async throws -> Data

public struct GitHubClient: Sendable {
    private let tokenTransport: GitHubTokenTransport
    private let cliTransport: GitHubCLITransport
    private let now: @Sendable () -> Date

    public init() {
        tokenTransport = { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw GitHubClientError.invalidResponse
            }
            return (data, response.statusCode)
        }
        cliTransport = { input in
            try await GitHubCLIProcess.run(input: input)
        }
        now = { Date() }
    }

    init(
        tokenTransport: @escaping GitHubTokenTransport,
        cliTransport: @escaping GitHubCLITransport,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.tokenTransport = tokenTransport
        self.cliTransport = cliTransport
        self.now = now
    }

    public func fetch(
        project: ProjectReference,
        authentication: GitHubAuthentication
    ) async throws -> ProjectSnapshot {
        if case .token(let token) = authentication,
           token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw GitHubClientError.invalidToken
        }

        var cursor: String?
        var visitedCursors = Set<String>()
        var issues: [GitHubIssue] = []
        var projectTitle: String?
        var viewerLogin: String?
        var projectMetadata: ProjectMetadata?
        var repositories = Set<String>()

        repeat {
            let requestBody = try makeRequestBody(project: project, cursor: cursor)
            let responseData = try await perform(
                requestBody: requestBody,
                authentication: authentication
            )
            let page = try decodePage(responseData, project: project)

            if projectTitle == nil { projectTitle = page.title }
            if viewerLogin == nil { viewerLogin = page.viewerLogin }
            if projectMetadata == nil { projectMetadata = page.metadata }
            repositories.formUnion(page.repositories)
            issues.append(contentsOf: page.issues)

            guard page.hasNextPage else {
                cursor = nil
                break
            }
            guard let nextCursor = page.endCursor,
                  !nextCursor.isEmpty,
                  visitedCursors.insert(nextCursor).inserted else {
                throw GitHubClientError.invalidResponse
            }
            cursor = nextCursor
        } while cursor != nil

        guard let projectTitle, let viewerLogin else {
            throw GitHubClientError.invalidResponse
        }
        if var metadata = projectMetadata {
            metadata.repositories = repositories.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            projectMetadata = metadata
        }
        return ProjectSnapshot(
            project: project,
            title: projectTitle,
            viewerLogin: viewerLogin,
            issues: issues,
            fetchedAt: now(),
            metadata: projectMetadata
        )
    }

    public func updateStatus(
        projectID: String,
        itemID: String,
        fieldID: String,
        optionID: String?,
        authentication: GitHubAuthentication
    ) async throws {
        try validateAuthentication(authentication)
        guard !projectID.isEmpty, !itemID.isEmpty, !fieldID.isEmpty else {
            throw GitHubClientError.invalidResponse
        }

        let requestBody: Data
        let responseKey: String
        if let optionID, !optionID.isEmpty {
            requestBody = try makeGraphQLBody(
                query: Self.updateStatusMutation,
                variables: ["projectID": projectID, "itemID": itemID, "fieldID": fieldID, "optionID": optionID]
            )
            responseKey = "updateProjectV2ItemFieldValue"
        } else {
            requestBody = try makeGraphQLBody(
                query: Self.clearStatusMutation,
                variables: ["projectID": projectID, "itemID": itemID, "fieldID": fieldID]
            )
            responseKey = "clearProjectV2ItemFieldValue"
        }

        let response = try await perform(
            requestBody: requestBody,
            authentication: authentication,
            accessDeniedError: .projectWriteAccessDenied
        )
        try decodeMutationConfirmation(response, responseKey: responseKey, accessError: .projectWriteAccessDenied)
    }

    public func createIssue(
        projectID: String,
        repository: String,
        title: String,
        body: String,
        assigneeID: String?,
        statusFieldID: String?,
        statusOptionID: String?,
        authentication: GitHubAuthentication
    ) async throws -> CreatedProjectIssue {
        try validateAuthentication(authentication)
        guard !projectID.isEmpty else { throw GitHubClientError.invalidResponse }
        let repositoryParts = repository.split(separator: "/", omittingEmptySubsequences: false)
        guard repositoryParts.count == 2,
              repositoryParts.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw GitHubClientError.invalidRepository
        }
        let repositoryName = repositoryParts.map(String.init).joined(separator: "/")
        let repositoryRequest = try makeGraphQLBody(
            query: Self.repositoryForIssueQuery,
            variables: ["owner": String(repositoryParts[0]), "name": String(repositoryParts[1])]
        )
        let repositoryResponse = try await perform(
            requestBody: repositoryRequest,
            authentication: authentication,
            accessDeniedError: .repositoryIssuesWriteAccessDenied(repositoryName)
        )
        let resolvedRepository = try decodeRepository(
            repositoryResponse,
            requestedName: repositoryName
        )

        let createRequest = try makeGraphQLBody(
            query: Self.createIssueMutation,
            variables: [
                "repositoryID": resolvedRepository.id,
                "title": title,
                "body": body,
                "assigneeIDs": assigneeID.map { [$0] } ?? []
            ]
        )
        let createResponse: Data
        do {
            createResponse = try await perform(
                requestBody: createRequest,
                authentication: authentication,
                accessDeniedError: .repositoryIssuesWriteAccessDenied(repositoryName)
            )
        } catch {
            throw uncertainCreationError(from: error)
        }

        let created: CreatedIssuePayload
        do {
            created = try decodeCreatedIssue(createResponse, repository: repositoryName)
        } catch let error as GitHubClientError {
            if case .invalidResponse = error { throw uncertainCreationError(from: error) }
            throw error
        }

        var result = CreatedProjectIssue(issueID: created.id, url: created.url, projectItemID: nil, warning: nil)
        do {
            let addRequest = try makeGraphQLBody(
                query: Self.addProjectItemMutation,
                variables: ["projectID": projectID, "contentID": created.id]
            )
            let addResponse = try await perform(
                requestBody: addRequest,
                authentication: authentication,
                accessDeniedError: .projectWriteAccessDenied
            )
            result.projectItemID = try decodeAddedProjectItem(addResponse)
        } catch {
            result.warning = Self.partialSuccessWarning(
                "GitHub could not add the issue to the project. Grant the `project` scope and project write access, then add it manually.",
                error: error
            )
            return result
        }

        if let statusFieldID, !statusFieldID.isEmpty,
           let statusOptionID, !statusOptionID.isEmpty,
           let projectItemID = result.projectItemID {
            do {
                try await updateStatus(
                    projectID: projectID,
                    itemID: projectItemID,
                    fieldID: statusFieldID,
                    optionID: statusOptionID,
                    authentication: authentication
                )
            } catch {
                result.warning = Self.partialSuccessWarning(
                    "The issue was created and added to the project, but GitHub could not set its status. Grant the `project` scope and project write access, then set it manually.",
                    error: error
                )
            }
        }
        return result
    }

    public func fetchIssueComposer(
        repository: String,
        authentication: GitHubAuthentication
    ) async throws -> IssueComposerMetadata {
        try validateAuthentication(authentication)
        let repositoryParts = try Self.repositoryParts(repository)
        let repositoryName = repositoryParts.owner + "/" + repositoryParts.name
        let request = try makeGraphQLBody(
            query: Self.issueComposerMetadataQuery,
            variables: ["owner": repositoryParts.owner, "name": repositoryParts.name]
        )
        let response = try await perform(
            requestBody: request,
            authentication: authentication,
            accessDeniedError: .repositoryIssuesWriteAccessDenied(repositoryName)
        )
        return try decodeIssueComposerMetadata(response, requestedName: repositoryName)
    }

    public func createIssue(
        request: IssueCreationRequest,
        authentication: GitHubAuthentication
    ) async throws -> CreatedProjectIssue {
        try validateAuthentication(authentication)
        guard !request.projectID.isEmpty,
              !request.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !request.additionalProjectIDs.contains(where: { $0.isEmpty }),
              !request.assigneeIDs.contains(where: { $0.isEmpty }),
              !request.labelIDs.contains(where: { $0.isEmpty }),
              (Self.nonempty(request.statusFieldID) == nil) == (Self.nonempty(request.statusOptionID) == nil) else {
            throw GitHubClientError.invalidResponse
        }
        let repositoryParts = try Self.repositoryParts(request.repository)
        let repositoryName = repositoryParts.owner + "/" + repositoryParts.name
        let references = try Self.parsedReferences(for: request, defaultRepository: repositoryName)
        let allProjectIDs = Self.uniqueNonempty([request.projectID] + request.additionalProjectIDs)

        let preflightQuery = Self.issueCreationPreflightQuery(references: references)
        var preflightVariables: [String: Any] = [
            "owner": repositoryParts.owner,
            "name": repositoryParts.name,
            "assigneeIDs": Self.uniqueNonempty(request.assigneeIDs),
            "labelIDs": Self.uniqueNonempty(request.labelIDs),
            "projectIDs": allProjectIDs,
            "milestoneIDs": Self.uniqueNonempty([request.milestoneID].compactMap { $0 }),
            "issueTypeIDs": Self.uniqueNonempty([request.issueTypeID].compactMap { $0 })
        ]
        for (index, reference) in references.enumerated() {
            preflightVariables["ref\(index)Owner"] = reference.owner
            preflightVariables["ref\(index)Name"] = reference.repository
            preflightVariables["ref\(index)Number"] = reference.number
        }
        let preflightRequest = try makeGraphQLBody(query: preflightQuery, variables: preflightVariables)
        let preflightResponse = try await perform(
            requestBody: preflightRequest,
            authentication: authentication,
            accessDeniedError: .repositoryIssuesWriteAccessDenied(repositoryName)
        )
        let preflight = try decodeIssueCreationPreflight(
            preflightResponse,
            request: request,
            requestedName: repositoryName,
            projectIDs: allProjectIDs,
            references: references
        )

        var createVariables: [String: Any] = [
            "repositoryID": preflight.repository.id,
            "title": request.title,
            "body": request.body,
            "assigneeIDs": Self.uniqueNonempty(request.assigneeIDs),
            "labelIDs": Self.uniqueNonempty(request.labelIDs),
            "projectV2IDs": allProjectIDs
        ]
        if let milestoneID = Self.nonempty(request.milestoneID) { createVariables["milestoneID"] = milestoneID }
        if let issueTypeID = Self.nonempty(request.issueTypeID) { createVariables["issueTypeID"] = issueTypeID }
        if let templateFilename = Self.nonempty(request.templateFilename) { createVariables["issueTemplate"] = templateFilename }
        if let parentIndex = references.firstIndex(where: { $0.kind == .parent }) {
            createVariables["parentIssueID"] = preflight.issueIDs[parentIndex]
        }

        let createRequest = try makeGraphQLBody(query: Self.fullCreateIssueMutation, variables: createVariables)
        let createResponse: Data
        do {
            createResponse = try await perform(
                requestBody: createRequest,
                authentication: authentication,
                accessDeniedError: .repositoryIssuesWriteAccessDenied(repositoryName)
            )
        } catch {
            throw uncertainCreationError(from: error)
        }

        let created: CreatedIssuePayload
        var warnings: [String] = []
        if let confirmed = try? decodeCreatedIssueWithoutCheckingErrors(createResponse) {
            created = confirmed
            if let errors = try? JSONDecoder().decode(ErrorEnvelope.self, from: createResponse).errors,
               !errors.isEmpty {
                warnings.append("The issue was created, but GitHub also reported: \(errors.map(\.message).joined(separator: "; "))")
            }
        } else {
            do {
                created = try decodeCreatedIssue(createResponse, repository: repositoryName)
            } catch let error as GitHubClientError {
                if case .invalidResponse = error { throw uncertainCreationError(from: error) }
                throw error
            }
        }
        var createdProjectItems = (try? decodeCreatedProjectItems(createResponse).items) ?? [:]
        if allProjectIDs.contains(where: { createdProjectItems[$0] == nil }) {
            for attempt in 0..<3 {
                if attempt > 0 {
                    do {
                        try await Task.sleep(nanoseconds: attempt == 1 ? 500_000_000 : 1_500_000_000)
                    } catch {
                        break
                    }
                }
                do {
                    let resolutionRequest = try makeGraphQLBody(
                        query: Self.resolveCreatedIssueProjectItemsQuery,
                        variables: ["issueID": created.id]
                    )
                    let resolutionResponse = try await perform(
                        requestBody: resolutionRequest,
                        authentication: authentication,
                        accessDeniedError: .projectAccessDenied
                    )
                    let resolution = try decodeCreatedProjectItemsResolution(resolutionResponse)
                    createdProjectItems.merge(resolution.items) { _, latest in latest }
                    if allProjectIDs.allSatisfy({ createdProjectItems[$0] != nil }) {
                        break
                    }
                    if resolution.hasNextPage {
                        break
                    }
                } catch is CancellationError {
                    break
                } catch {
                    continue
                }
            }
        }
        let projectItemID = createdProjectItems[request.projectID]
        let unconfirmedProjects = allProjectIDs.filter { createdProjectItems[$0] == nil }
        if !unconfirmedProjects.isEmpty {
            let noun = unconfirmedProjects.count == 1 ? "project attachment" : "project attachments"
            warnings.append("The issue was created, but GitHub did not confirm \(unconfirmedProjects.count) requested \(noun). Open the issue and check its projects before retrying.")
        }
        if projectItemID == nil,
           Self.nonempty(request.statusFieldID) != nil,
           Self.nonempty(request.statusOptionID) != nil {
            warnings.append("GitHub did not return the active project item, so its requested status could not be set.")
        }

        if let fieldID = Self.nonempty(request.statusFieldID),
           let optionID = Self.nonempty(request.statusOptionID) {
            if let projectItemID {
                do {
                    try await updateStatus(projectID: request.projectID, itemID: projectItemID, fieldID: fieldID, optionID: optionID, authentication: authentication)
                } catch {
                    warnings.append(Self.partialSuccessWarning("The issue was created, but GitHub could not set its project status.", error: error))
                }
            }
        }

        for (index, reference) in references.enumerated() where reference.kind != .parent {
            let subjectID = reference.kind == .blockedBy ? created.id : preflight.issueIDs[index]
            let blockingID = reference.kind == .blockedBy ? preflight.issueIDs[index] : created.id
            do {
                let dependencyRequest = try makeGraphQLBody(
                    query: Self.addBlockedByMutation,
                    variables: ["subjectID": subjectID, "blockingIssueID": blockingID]
                )
                let dependencyResponse = try await perform(
                    requestBody: dependencyRequest,
                    authentication: authentication,
                    accessDeniedError: .repositoryIssuesWriteAccessDenied(repositoryName)
                )
                try decodeMutationConfirmation(dependencyResponse, responseKey: "addBlockedBy", accessError: .repositoryIssuesWriteAccessDenied(repositoryName))
            } catch {
                warnings.append(Self.partialSuccessWarning("The issue was created, but GitHub could not add the dependency \(reference.displayValue).", error: error))
            }
        }

        return CreatedProjectIssue(
            issueID: created.id,
            url: created.url,
            projectItemID: projectItemID,
            warning: warnings.isEmpty ? nil : warnings.joined(separator: " ")
        )
    }

    public func updateAssignees(
        issueID: String,
        assigneeIDs: [String],
        authentication: GitHubAuthentication
    ) async throws -> [IssueChoice] {
        try validateAuthentication(authentication)
        guard !issueID.isEmpty, !assigneeIDs.contains(where: { $0.isEmpty }) else {
            throw GitHubClientError.invalidResponse
        }
        let request = try makeGraphQLBody(
            query: Self.replaceAssigneesMutation,
            variables: ["issueID": issueID, "assigneeIDs": Self.uniqueNonempty(assigneeIDs)]
        )
        let response = try await perform(
            requestBody: request,
            authentication: authentication,
            accessDeniedError: .projectWriteAccessDenied
        )
        return try decodeUpdatedAssignees(response)
    }

    private func makeRequestBody(project: ProjectReference, cursor: String?) throws -> Data {
        let body = GraphQLRequest(
            query: Self.query(forOrganization: project.isOrganization),
            variables: GraphQLVariables(
                owner: project.owner,
                number: project.number,
                cursor: cursor
            )
        )
        do {
            return try JSONEncoder().encode(body)
        } catch {
            throw GitHubClientError.invalidResponse
        }
    }

    private func perform(
        requestBody: Data,
        authentication: GitHubAuthentication,
        accessDeniedError: GitHubClientError = .projectAccessDenied
    ) async throws -> Data {
        switch authentication {
        case .token(let rawToken):
            let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
            var request = URLRequest(url: URL(string: "https://api.github.com/graphql")!)
            request.httpMethod = "POST"
            request.httpBody = requestBody
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("Issues macOS", forHTTPHeaderField: "User-Agent")
            do {
                let (data, statusCode) = try await tokenTransport(request)
                switch statusCode {
                case 200..<300:
                    return data
                case 401:
                    throw GitHubClientError.authenticationFailed
                case 403:
                    throw accessDeniedError
                default:
                    throw GitHubClientError.transport("HTTP \(statusCode)")
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as GitHubClientError {
                throw error
            } catch {
                throw GitHubClientError.transport(Self.redact(error.localizedDescription, token: token))
            }

        case .cli:
            do {
                return try await cliTransport(requestBody)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as GitHubClientError {
                throw error
            } catch {
                throw GitHubClientError.transport(error.localizedDescription)
            }
        }
    }

    private func decodePage(_ data: Data, project: ProjectReference) throws -> DecodedPage {
        let envelope: GraphQLEnvelope
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            envelope = try decoder.decode(GraphQLEnvelope.self, from: data)
        } catch {
            throw GitHubClientError.invalidResponse
        }

        if let errors = envelope.errors, !errors.isEmpty {
            let messages = errors.map(\.message).joined(separator: "; ")
            let accessText = errors.map { "\($0.type ?? "") \($0.message)" }
                .joined(separator: " ")
                .lowercased()
            if accessText.contains("forbidden") ||
                accessText.contains("not accessible") ||
                accessText.contains("scope") ||
                accessText.contains("permission") {
                throw GitHubClientError.projectAccessDenied
            }
            throw GitHubClientError.graphQL(messages.isEmpty ? "Unknown error" : messages)
        }

        guard let data = envelope.data,
              let projectData = project.isOrganization
                ? data.organization?.projectV2
                : data.user?.projectV2 else {
            throw GitHubClientError.projectAccessDenied
        }

        let returnedProjectURL: URL?
        if let urlString = projectData.url {
            guard let url = URL(string: urlString),
                  url.scheme == "https", url.host?.lowercased() == "github.com",
                  url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    == project.url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) else {
                throw GitHubClientError.invalidResponse
            }
            returnedProjectURL = url
        } else {
            returnedProjectURL = nil
        }

        let statusField = Self.preferredStatusField(from: projectData.fields?.nodes ?? [])
        var repositories = Set(projectData.repositories?.nodes.compactMap { $0?.nameWithOwner } ?? [])
        repositories.formUnion(projectData.items.nodes.compactMap { $0.content?.repository?.nameWithOwner })

        let issues = projectData.items.nodes.compactMap { item -> GitHubIssue? in
            guard item.isArchived == false,
                  let projectItemID = item.id,
                  let content = item.content,
                  content.typeName == "Issue",
                  ["OPEN", "CLOSED"].contains(content.state),
                  let id = content.id,
                  let number = content.number,
                  let title = content.title,
                  let body = content.body,
                  let urlString = content.url,
                  let url = URL(string: urlString),
                  url.scheme == "https",
                  url.host?.lowercased() == "github.com",
                  let repository = content.repository?.nameWithOwner,
                  let updatedAt = content.updatedAt else {
                return nil
            }

            let statusValue: ProjectStatusValue?
            switch statusField?.name.lowercased() {
            case "status": statusValue = item.status
            case "stato": statusValue = item.stato
            default:
                statusValue = [item.status, item.stato].compactMap { $0 }.first {
                    guard let name = $0.field?.name.lowercased() else { return false }
                    return name == "status" || name == "stato"
                }
            }
            return GitHubIssue(
                id: id,
                number: number,
                title: title,
                body: body,
                url: url,
                repository: repository,
                status: statusValue?.displayValue ?? "",
                labels: content.labels?.nodes.compactMap(\.name) ?? [],
                assignees: content.assignees?.nodes.compactMap(\.login) ?? [],
                updatedAt: updatedAt,
                projectItemID: projectItemID
            )
        }

        let metadata = projectData.id.map {
            ProjectMetadata(
                id: $0,
                projectURL: returnedProjectURL,
                statusField: statusField,
                repositories: repositories.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending },
                viewerID: data.viewer.id
            )
        }

        return DecodedPage(
            title: projectData.title,
            viewerLogin: data.viewer.login,
            issues: issues,
            metadata: metadata,
            repositories: repositories,
            hasNextPage: projectData.items.pageInfo.hasNextPage,
            endCursor: projectData.items.pageInfo.endCursor
        )
    }

    private func validateAuthentication(_ authentication: GitHubAuthentication) throws {
        if case .token(let token) = authentication,
           token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw GitHubClientError.invalidToken
        }
    }

    private func makeGraphQLBody(query: String, variables: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(["query": query, "variables": variables]) else {
            throw GitHubClientError.invalidResponse
        }
        do {
            return try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        } catch {
            throw GitHubClientError.invalidResponse
        }
    }

    private func decodeMutationConfirmation(
        _ data: Data,
        responseKey: String,
        accessError: GitHubClientError
    ) throws {
        try throwGraphQLErrors(in: data, accessError: accessError)
        do {
            let envelope = try JSONDecoder().decode(MutationConfirmationEnvelope.self, from: data)
            guard envelope.data?[responseKey] != nil else { throw GitHubClientError.invalidResponse }
        } catch let error as GitHubClientError {
            throw error
        } catch {
            throw GitHubClientError.invalidResponse
        }
    }

    private func decodeRepository(_ data: Data, requestedName: String) throws -> ResolvedRepository {
        try throwGraphQLErrors(
            in: data,
            accessError: .repositoryIssuesWriteAccessDenied(requestedName)
        )
        do {
            let envelope = try JSONDecoder().decode(RepositoryEnvelope.self, from: data)
            guard let repository = envelope.data?.repository,
                  repository.hasIssuesEnabled,
                  repository.viewerCanCreateIssues else {
                throw GitHubClientError.repositoryIssuesWriteAccessDenied(requestedName)
            }
            return repository
        } catch let error as GitHubClientError {
            throw error
        } catch {
            throw GitHubClientError.invalidResponse
        }
    }

    private func decodeCreatedIssue(_ data: Data, repository: String) throws -> CreatedIssuePayload {
        try throwGraphQLErrors(
            in: data,
            accessError: .repositoryIssuesWriteAccessDenied(repository)
        )
        do {
            let envelope = try JSONDecoder().decode(CreateIssueEnvelope.self, from: data)
            guard let issue = envelope.data?.createIssue?.issue,
                  let url = URL(string: issue.url),
                  url.scheme == "https",
                  url.host?.lowercased() == "github.com" else {
                throw GitHubClientError.invalidResponse
            }
            return CreatedIssuePayload(id: issue.id, url: url)
        } catch let error as GitHubClientError {
            throw error
        } catch {
            throw GitHubClientError.invalidResponse
        }
    }

    private func decodeCreatedIssueWithoutCheckingErrors(_ data: Data) throws -> CreatedIssuePayload {
        let envelope = try JSONDecoder().decode(CreateIssueEnvelope.self, from: data)
        guard let issue = envelope.data?.createIssue?.issue,
              let url = URL(string: issue.url),
              url.scheme == "https", url.host?.lowercased() == "github.com" else {
            throw GitHubClientError.invalidResponse
        }
        return CreatedIssuePayload(id: issue.id, url: url)
    }

    private func decodeAddedProjectItem(_ data: Data) throws -> String {
        try throwGraphQLErrors(in: data, accessError: .projectWriteAccessDenied)
        do {
            let envelope = try JSONDecoder().decode(AddProjectItemEnvelope.self, from: data)
            guard let id = envelope.data?.addProjectV2ItemById?.item?.id, !id.isEmpty else {
                throw GitHubClientError.invalidResponse
            }
            return id
        } catch let error as GitHubClientError {
            throw error
        } catch {
            throw GitHubClientError.invalidResponse
        }
    }

    private func decodeIssueComposerMetadata(_ data: Data, requestedName: String) throws -> IssueComposerMetadata {
        try throwGraphQLErrors(in: data, accessError: .projectAccessDenied)
        let envelope: ComposerMetadataEnvelope
        do {
            envelope = try JSONDecoder().decode(ComposerMetadataEnvelope.self, from: data)
        } catch {
            throw GitHubClientError.invalidResponse
        }
        guard let repository = envelope.data?.repository,
              repository.hasIssuesEnabled else {
            throw GitHubClientError.repositoryIssuesWriteAccessDenied(requestedName)
        }

        var warnings: [String] = []
        func warnIfTruncated(_ pageInfo: PageInfo?, _ name: String) {
            if pageInfo?.hasNextPage == true {
                warnings.append("GitHub returned only the first 100 \(name); refine the repository data on GitHub to see the complete list.")
            }
        }
        warnIfTruncated(repository.assignableUsers.pageInfo, "assignable users")
        warnIfTruncated(repository.labels?.pageInfo, "labels")
        warnIfTruncated(repository.milestones?.pageInfo, "open milestones")
        warnIfTruncated(repository.issueTypes?.pageInfo, "issue types")
        warnIfTruncated(repository.projectsV2.pageInfo, "repository projects")
        warnIfTruncated(repository.owner.ownerProjects.pageInfo, "owner projects")
        for template in repository.issueTemplates ?? [] {
            warnIfTruncated(template.assignees.pageInfo, "assignees for template \(template.filename)")
            warnIfTruncated(template.labels?.pageInfo, "labels for template \(template.filename)")
        }

        let projects = (repository.projectsV2.nodes + repository.owner.ownerProjects.nodes)
            .compactMap { $0 }
            .reduce(into: [String: ComposerProject]()) { result, project in
                guard !project.id.isEmpty, !project.title.isEmpty,
                      let url = URL(string: project.url), url.scheme == "https",
                      url.host?.lowercased() == "github.com" else { return }
                result[project.id] = ComposerProject(id: project.id, title: project.title, url: project.url)
            }
            .values
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        return IssueComposerMetadata(
            repository: repository.nameWithOwner,
            repositoryID: repository.id,
            assignees: repository.assignableUsers.nodes.compactMap { node in
                node.map { IssueChoice(id: $0.id, name: $0.login) }
            },
            labels: repository.labels?.nodes.compactMap { node in
                node.map { IssueChoice(id: $0.id, name: $0.name) }
            } ?? [],
            milestones: repository.milestones?.nodes.compactMap { node in
                node.map { IssueChoice(id: $0.id, name: $0.title) }
            } ?? [],
            issueTypes: repository.issueTypes?.nodes.compactMap { node in
                node.map { IssueChoice(id: $0.id, name: $0.name) }
            } ?? [],
            projects: projects,
            templates: (repository.issueTemplates ?? []).map {
                ComposerTemplate(
                    filename: $0.filename,
                    name: $0.name,
                    about: $0.about ?? "",
                    body: $0.body ?? "",
                    title: $0.title ?? "",
                    assigneeIDs: $0.assignees.nodes.compactMap { $0?.id },
                    labelIDs: $0.labels?.nodes.compactMap { $0?.id } ?? [],
                    issueTypeID: $0.type?.id
                )
            },
            canWrite: ["TRIAGE", "WRITE", "MAINTAIN", "ADMIN"].contains(repository.viewerPermission ?? ""),
            warnings: warnings
        )
    }

    private func decodeIssueCreationPreflight(
        _ data: Data,
        request: IssueCreationRequest,
        requestedName: String,
        projectIDs: [String],
        references: [ParsedIssueReference]
    ) throws -> IssueCreationPreflight {
        try throwGraphQLErrors(in: data, accessError: .repositoryIssuesWriteAccessDenied(requestedName))
        let envelope: IssueCreationPreflightEnvelope
        do {
            envelope = try JSONDecoder().decode(IssueCreationPreflightEnvelope.self, from: data)
        } catch {
            throw GitHubClientError.invalidResponse
        }
        guard let data = envelope.data,
              let repository = data.repository,
              repository.hasIssuesEnabled,
              repository.viewerCanCreateIssues else {
            throw GitHubClientError.repositoryIssuesWriteAccessDenied(requestedName)
        }
        try Self.requireNodes(data.assignees, expectedIDs: Self.uniqueNonempty(request.assigneeIDs), type: "User")
        try Self.requireNodes(data.labels, expectedIDs: Self.uniqueNonempty(request.labelIDs), type: "Label")
        try Self.requireNodes(data.projects, expectedIDs: projectIDs, type: "ProjectV2")
        try Self.requireNodes(data.milestones, expectedIDs: Self.uniqueNonempty([request.milestoneID].compactMap { $0 }), type: "Milestone")
        try Self.requireNodes(data.issueTypes, expectedIDs: Self.uniqueNonempty([request.issueTypeID].compactMap { $0 }), type: "IssueType")
        if let filename = Self.nonempty(request.templateFilename),
           !repository.issueTemplates.contains(where: { $0.filename == filename }) {
            throw GitHubClientError.graphQL("The selected issue template is not available in \(requestedName).")
        }
        var issueIDs: [String] = []
        for index in references.indices {
            guard let issue = data.references["ref\(index)"]??.issue,
                  !issue.id.isEmpty else {
                throw GitHubClientError.graphQL("Issue reference \(references[index].displayValue) was not found or is not accessible.")
            }
            issueIDs.append(issue.id)
        }
        return IssueCreationPreflight(repository: repository, issueIDs: issueIDs)
    }

    private func decodeCreatedProjectItems(_ data: Data) throws -> DecodedCreatedProjectItems {
        let envelope = try JSONDecoder().decode(FullCreateIssueEnvelope.self, from: data)
        guard let connection = envelope.data?.createIssue?.issue?.projectItems else {
            throw GitHubClientError.invalidResponse
        }
        let items = connection.nodes.compactMap { $0 }.reduce(into: [:]) { result, item in
            result[item.project.id] = item.id
        }
        return DecodedCreatedProjectItems(items: items, hasNextPage: connection.pageInfo?.hasNextPage == true)
    }

    private func decodeCreatedProjectItemsResolution(_ data: Data) throws -> DecodedCreatedProjectItems {
        try throwGraphQLErrors(in: data, accessError: .projectAccessDenied)
        let envelope = try JSONDecoder().decode(CreatedProjectItemsResolutionEnvelope.self, from: data)
        guard let connection = envelope.data?.node?.projectItems else {
            throw GitHubClientError.invalidResponse
        }
        let items = connection.nodes.compactMap { $0 }.reduce(into: [:]) { result, item in
            result[item.project.id] = item.id
        }
        return DecodedCreatedProjectItems(items: items, hasNextPage: connection.pageInfo?.hasNextPage == true)
    }

    private func decodeUpdatedAssignees(_ data: Data) throws -> [IssueChoice] {
        try throwGraphQLErrors(in: data, accessError: .projectWriteAccessDenied)
        do {
            let envelope = try JSONDecoder().decode(UpdateAssigneesEnvelope.self, from: data)
            guard let assignees = envelope.data?.updateIssue?.issue?.assignees,
                  !assignees.pageInfo.hasNextPage else {
                throw GitHubClientError.invalidResponse
            }
            return assignees.nodes.compactMap { node in
                node.map { IssueChoice(id: $0.id, name: $0.login) }
            }
        } catch let error as GitHubClientError {
            throw error
        } catch {
            throw GitHubClientError.invalidResponse
        }
    }

    private func throwGraphQLErrors(in data: Data, accessError: GitHubClientError) throws {
        let envelope: ErrorEnvelope
        do {
            envelope = try JSONDecoder().decode(ErrorEnvelope.self, from: data)
        } catch {
            throw GitHubClientError.invalidResponse
        }
        guard let errors = envelope.errors, !errors.isEmpty else { return }
        let messages = errors.map(\.message).joined(separator: "; ")
        let accessText = errors.map { "\($0.type ?? "") \($0.message)" }
            .joined(separator: " ")
            .lowercased()
        if accessText.contains("forbidden") || accessText.contains("not accessible") ||
            accessText.contains("scope") || accessText.contains("permission") {
            throw accessError
        }
        throw GitHubClientError.graphQL(messages.isEmpty ? "Unknown error" : messages)
    }

    private func uncertainCreationError(from error: Error) -> GitHubClientError {
        if let error = error as? GitHubClientError {
            switch error {
            case .authenticationFailed, .projectAccessDenied, .projectWriteAccessDenied,
                 .repositoryIssuesWriteAccessDenied, .invalidToken, .invalidRepository, .graphQL:
                return error
            default:
                return .issueCreationUncertain(Self.safeErrorDetail(error))
            }
        }
        if error is CancellationError {
            return .issueCreationUncertain("The request ended before a confirmation was received.")
        }
        return .issueCreationUncertain(Self.safeErrorDetail(error))
    }

    private static func safeErrorDetail(_ error: Error) -> String {
        let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? "No confirmation was received." : detail
    }

    private static func partialSuccessWarning(_ message: String, error: Error) -> String {
        let detail = safeErrorDetail(error)
        return detail.isEmpty ? message : "\(message) GitHub reported: \(detail)"
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func uniqueNonempty(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func repositoryParts(_ repository: String) throws -> (owner: String, name: String) {
        let parts = repository.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw GitHubClientError.invalidRepository
        }
        return (String(parts[0]), String(parts[1]))
    }

    private static func parsedReferences(
        for request: IssueCreationRequest,
        defaultRepository: String
    ) throws -> [ParsedIssueReference] {
        var result: [ParsedIssueReference] = []
        if let parent = nonempty(request.parentIssue) {
            result.append(try parsedReference(parent, kind: .parent, defaultRepository: defaultRepository))
        }
        for value in request.blockedBy {
            result.append(try parsedReference(value, kind: .blockedBy, defaultRepository: defaultRepository))
        }
        for value in request.blocking {
            result.append(try parsedReference(value, kind: .blocking, defaultRepository: defaultRepository))
        }
        var seen = Set<String>()
        guard result.allSatisfy({ seen.insert("\($0.kind.rawValue):\($0.owner.lowercased())/\($0.repository.lowercased())#\($0.number)").inserted }) else {
            throw GitHubClientError.graphQL("Duplicate issue references are not allowed.")
        }
        return result
    }

    private static func parsedReference(
        _ value: String,
        kind: IssueReferenceKind,
        defaultRepository: String
    ) throws -> ParsedIssueReference {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let number = Int(trimmed), number > 0 {
            let parts = try repositoryParts(defaultRepository)
            return ParsedIssueReference(kind: kind, owner: parts.owner, repository: parts.name, number: number, displayValue: trimmed)
        }
        guard let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "github.com",
              url.query == nil,
              url.fragment == nil else {
            throw GitHubClientError.graphQL("Issue reference \(trimmed) must be a positive issue number or a full https://github.com/owner/repo/issues/N URL.")
        }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 4, parts[2] == "issues", let number = Int(parts[3]), number > 0,
              !parts[0].isEmpty, !parts[1].isEmpty else {
            throw GitHubClientError.graphQL("Issue reference \(trimmed) must be a positive issue number or a full https://github.com/owner/repo/issues/N URL.")
        }
        return ParsedIssueReference(kind: kind, owner: parts[0], repository: parts[1], number: number, displayValue: trimmed)
    }

    private static func requireNodes(_ nodes: [GraphQLNode?], expectedIDs: [String], type: String) throws {
        let actual = Set<String>(nodes.compactMap { node in
            guard node?.typeName == type else { return nil }
            return node?.id
        })
        guard actual == Set(expectedIDs) else {
            throw GitHubClientError.graphQL("One or more selected \(type) IDs are invalid or inaccessible.")
        }
    }

    private static func issueCreationPreflightQuery(references: [ParsedIssueReference]) -> String {
        let variableDefinitions = references.indices.map {
            "$ref\($0)Owner: String!, $ref\($0)Name: String!, $ref\($0)Number: Int!"
        }.joined(separator: ", ")
        let referenceQueries = references.indices.map {
            "ref\($0): repository(owner: $ref\($0)Owner, name: $ref\($0)Name) { issue(number: $ref\($0)Number) { id } }"
        }.joined(separator: "\n")
        let optionalVariables = variableDefinitions.isEmpty ? "" : ", \(variableDefinitions)"
        return """
        query IssueCreationPreflight(
          $owner: String!, $name: String!, $assigneeIDs: [ID!]!, $labelIDs: [ID!]!,
          $projectIDs: [ID!]!, $milestoneIDs: [ID!]!, $issueTypeIDs: [ID!]!\(optionalVariables)
        ) {
          repository(owner: $owner, name: $name) {
            id nameWithOwner hasIssuesEnabled viewerCanCreateIssues viewerPermission
            issueTemplates { filename }
          }
          assignees: nodes(ids: $assigneeIDs) { __typename id }
          labels: nodes(ids: $labelIDs) { __typename id }
          projects: nodes(ids: $projectIDs) { __typename id }
          milestones: nodes(ids: $milestoneIDs) { __typename id }
          issueTypes: nodes(ids: $issueTypeIDs) { __typename id }
          \(referenceQueries)
        }
        """
    }

    private static func preferredStatusField(from nodes: [ProjectFieldNode?]) -> ProjectStatusField? {
        let fields = nodes.compactMap { node -> ProjectStatusField? in
            guard node?.typeName == "ProjectV2SingleSelectField",
                  let id = node?.id,
                  let name = node?.name else { return nil }
            return ProjectStatusField(
                id: id,
                name: name,
                options: node?.options?.compactMap {
                    guard let id = $0?.id, let name = $0?.name else { return nil }
                    return ProjectStatusOption(id: id, name: name)
                } ?? []
            )
        }
        return fields.first { $0.name.caseInsensitiveCompare("Status") == .orderedSame }
            ?? fields.first { $0.name.caseInsensitiveCompare("Stato") == .orderedSame }
    }

    private static func redact(_ message: String, token: String) -> String {
        guard !token.isEmpty else { return message }
        return message.replacingOccurrences(of: token, with: "[REDACTED]")
    }

    private static func query(forOrganization: Bool) -> String {
        let ownerSelection = forOrganization
            ? "organization(login: $owner)"
            : "user(login: $owner)"
        return """
        query IssuesProjectSnapshot($owner: String!, $number: Int!, $cursor: String) {
          viewer { id login }
          \(ownerSelection) {
            projectV2(number: $number) {
              title
              id
              url
              fields(first: 100) {
                nodes {
                  __typename
                  ... on ProjectV2SingleSelectField { id name options { id name } }
                }
              }
              repositories(first: 100) { nodes { nameWithOwner } }
              items(first: 100, after: $cursor) {
                pageInfo { hasNextPage endCursor }
                nodes {
                  id
                  isArchived
                  fieldValueByName(name: "Status") {
                    ... on ProjectV2ItemFieldSingleSelectValue { name field { ...ProjectFieldName } }
                    ... on ProjectV2ItemFieldTextValue { text field { ...ProjectFieldName } }
                    ... on ProjectV2ItemFieldIterationValue { title field { ...ProjectFieldName } }
                    ... on ProjectV2ItemFieldMultiSelectValue { value field { ...ProjectFieldName } }
                  }
                  statoValue: fieldValueByName(name: "Stato") {
                    ... on ProjectV2ItemFieldSingleSelectValue { name field { ...ProjectFieldName } }
                  }
                  content {
                    __typename
                    ... on Issue {
                      id number title body url state updatedAt
                      repository { nameWithOwner }
                      labels(first: 100) { nodes { name } }
                      assignees(first: 100) { nodes { login } }
                    }
                    ... on PullRequest { id }
                    ... on DraftIssue { id }
                  }
                }
              }
            }
          }
        }

        fragment ProjectFieldName on ProjectV2FieldConfiguration {
          ... on ProjectV2Field { name }
          ... on ProjectV2IterationField { name }
          ... on ProjectV2MultiSelectField { name }
          ... on ProjectV2SingleSelectField { name }
        }
        """
    }

    private static let updateStatusMutation = """
    mutation UpdateProjectStatus($projectID: ID!, $itemID: ID!, $fieldID: ID!, $optionID: String!) {
      updateProjectV2ItemFieldValue(input: {
        projectId: $projectID, itemId: $itemID, fieldId: $fieldID,
        value: { singleSelectOptionId: $optionID }
      }) { projectV2Item { id } }
    }
    """

    private static let clearStatusMutation = """
    mutation ClearProjectStatus($projectID: ID!, $itemID: ID!, $fieldID: ID!) {
      clearProjectV2ItemFieldValue(input: {
        projectId: $projectID, itemId: $itemID, fieldId: $fieldID
      }) { projectV2Item { id } }
    }
    """

    private static let repositoryForIssueQuery = """
    query IssueCreationRepository($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) {
        id nameWithOwner hasIssuesEnabled viewerCanCreateIssues viewerPermission
      }
    }
    """

    private static let issueComposerMetadataQuery = """
    query IssueComposerMetadata($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) {
        id nameWithOwner hasIssuesEnabled viewerCanCreateIssues viewerPermission
        assignableUsers(first: 100) {
          pageInfo { hasNextPage endCursor }
          nodes { id login }
        }
        labels(first: 100) {
          pageInfo { hasNextPage endCursor }
          nodes { id name }
        }
        milestones(first: 100, states: [OPEN]) {
          pageInfo { hasNextPage endCursor }
          nodes { id title }
        }
        issueTypes(first: 100) {
          pageInfo { hasNextPage endCursor }
          nodes { id name }
        }
        projectsV2(first: 100, minPermissionLevel: READ) {
          pageInfo { hasNextPage endCursor }
          nodes { id title url }
        }
        issueTemplates {
          filename name about body title type { id }
          assignees(first: 100) {
            pageInfo { hasNextPage endCursor }
            nodes { id login }
          }
          labels(first: 100) {
            pageInfo { hasNextPage endCursor }
            nodes { id name }
          }
        }
        owner {
          ... on Organization {
            ownerProjects: projectsV2(first: 100, minPermissionLevel: READ) {
              pageInfo { hasNextPage endCursor }
              nodes { id title url }
            }
          }
          ... on User {
            ownerProjects: projectsV2(first: 100, minPermissionLevel: READ) {
              pageInfo { hasNextPage endCursor }
              nodes { id title url }
            }
          }
        }
      }
    }
    """

    private static let fullCreateIssueMutation = """
    mutation CreateRepositoryIssue(
      $repositoryID: ID!, $title: String!, $body: String!, $assigneeIDs: [ID!],
      $labelIDs: [ID!], $milestoneID: ID, $issueTypeID: ID, $issueTemplate: String,
      $parentIssueID: ID, $projectV2IDs: [ID!]
    ) {
      createIssue(input: {
        repositoryId: $repositoryID, title: $title, body: $body,
        assigneeIds: $assigneeIDs, labelIds: $labelIDs, milestoneId: $milestoneID,
        issueTypeId: $issueTypeID, issueTemplate: $issueTemplate,
        parentIssueId: $parentIssueID, projectV2Ids: $projectV2IDs
      }) {
        issue {
          id url
          projectItems(first: 100) {
            pageInfo { hasNextPage endCursor }
            nodes { id project { id } }
          }
        }
      }
    }
    """

    private static let resolveCreatedIssueProjectItemsQuery = """
    query ResolveCreatedIssueProjectItems($issueID: ID!) {
      node(id: $issueID) {
        ... on Issue {
          projectItems(first: 100) {
            pageInfo { hasNextPage endCursor }
            nodes { id project { id } }
          }
        }
      }
    }
    """

    private static let addBlockedByMutation = """
    mutation AddIssueDependency($subjectID: ID!, $blockingIssueID: ID!) {
      addBlockedBy(input: { issueId: $subjectID, blockingIssueId: $blockingIssueID }) {
        issue { id }
        blockingIssue { id }
      }
    }
    """

    private static let replaceAssigneesMutation = """
    mutation ReplaceIssueAssignees($issueID: ID!, $assigneeIDs: [ID!]) {
      updateIssue(input: { id: $issueID, assigneeIds: $assigneeIDs }) {
        issue {
          assignees(first: 100) {
            pageInfo { hasNextPage endCursor }
            nodes { id login }
          }
        }
      }
    }
    """

    private static let createIssueMutation = """
    mutation CreateRepositoryIssue($repositoryID: ID!, $title: String!, $body: String!, $assigneeIDs: [ID!]) {
      createIssue(input: {
        repositoryId: $repositoryID, title: $title, body: $body, assigneeIds: $assigneeIDs
      }) { issue { id url } }
    }
    """

    private static let addProjectItemMutation = """
    mutation AddIssueToProject($projectID: ID!, $contentID: ID!) {
      addProjectV2ItemById(input: { projectId: $projectID, contentId: $contentID }) {
        item { id }
      }
    }
    """
}

private struct GraphQLRequest: Encodable {
    let query: String
    let variables: GraphQLVariables
}

private struct GraphQLVariables: Encodable {
    let owner: String
    let number: Int
    let cursor: String?

    private enum CodingKeys: String, CodingKey { case owner, number, cursor }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(owner, forKey: .owner)
        try container.encode(number, forKey: .number)
        if let cursor {
            try container.encode(cursor, forKey: .cursor)
        } else {
            try container.encodeNil(forKey: .cursor)
        }
    }
}

private struct GraphQLEnvelope: Decodable {
    let data: GraphQLData?
    let errors: [GraphQLError]?
}

private struct GraphQLError: Decodable {
    let type: String?
    let message: String
}

private struct ErrorEnvelope: Decodable {
    let errors: [GraphQLError]?
}

private struct GraphQLData: Decodable {
    let viewer: Viewer
    let organization: ProjectOwner?
    let user: ProjectOwner?
}

private struct Viewer: Decodable {
    let login: String
    let id: String?
}
private struct ProjectOwner: Decodable { let projectV2: ProjectData? }

private struct ProjectData: Decodable {
    let id: String?
    let title: String
    let url: String?
    let fields: ProjectFields?
    let repositories: RepositoryConnection?
    let items: ProjectItems
}

private struct ProjectFields: Decodable { let nodes: [ProjectFieldNode?] }
private struct ProjectFieldNode: Decodable {
    let typeName: String
    let id: String?
    let name: String?
    let options: [ProjectFieldOption?]?

    private enum CodingKeys: String, CodingKey {
        case typeName = "__typename"
        case id, name, options
    }
}
private struct ProjectFieldOption: Decodable {
    let id: String?
    let name: String?
}

private struct ProjectItems: Decodable {
    let pageInfo: PageInfo
    let nodes: [ProjectItem]
}

private struct PageInfo: Decodable {
    let hasNextPage: Bool
    let endCursor: String?
}

private struct ProjectItem: Decodable {
    let id: String?
    let isArchived: Bool?
    let status: ProjectStatusValue?
    let stato: ProjectStatusValue?
    let content: ProjectContent?

    private enum CodingKeys: String, CodingKey {
        case isArchived
        case id
        case status = "fieldValueByName"
        case stato = "statoValue"
        case content
    }
}

private struct ProjectStatusValue: Decodable {
    let name: String?
    let text: String?
    let title: String?
    let value: String?
    let field: ProjectFieldName?

    var displayValue: String? { name ?? text ?? title ?? value }
}

private struct ProjectFieldName: Decodable { let name: String }

private struct ProjectContent: Decodable {
    let typeName: String
    let id: String?
    let number: Int?
    let title: String?
    let body: String?
    let url: String?
    let state: String?
    let updatedAt: Date?
    let repository: RepositoryName?
    let labels: LabelConnection?
    let assignees: AssigneeConnection?

    private enum CodingKeys: String, CodingKey {
        case typeName = "__typename"
        case id, number, title, body, url, state, updatedAt, repository, labels, assignees
    }
}

private struct RepositoryName: Decodable { let nameWithOwner: String }
private struct RepositoryConnection: Decodable { let nodes: [RepositoryName?] }
private struct LabelConnection: Decodable { let nodes: [LabelNode] }
private struct LabelNode: Decodable { let name: String? }
private struct AssigneeConnection: Decodable { let nodes: [AssigneeNode] }
private struct AssigneeNode: Decodable { let login: String? }

private struct DecodedPage {
    let title: String
    let viewerLogin: String
    let issues: [GitHubIssue]
    let metadata: ProjectMetadata?
    let repositories: Set<String>
    let hasNextPage: Bool
    let endCursor: String?
}

private struct MutationConfirmationEnvelope: Decodable {
    let data: [String: MutationConfirmation?]?
}
private struct MutationConfirmation: Decodable {}

private struct RepositoryEnvelope: Decodable {
    let data: RepositoryEnvelopeData?
}
private struct RepositoryEnvelopeData: Decodable { let repository: ResolvedRepository? }
private struct ResolvedRepository: Decodable {
    let id: String
    let nameWithOwner: String
    let hasIssuesEnabled: Bool
    let viewerCanCreateIssues: Bool
    let viewerPermission: String?
}

private struct CreateIssueEnvelope: Decodable { let data: CreateIssueData? }
private struct CreateIssueData: Decodable { let createIssue: CreateIssueMutationPayload? }
private struct CreateIssueMutationPayload: Decodable { let issue: CreatedIssueResponse? }
private struct CreatedIssueResponse: Decodable {
    let id: String
    let url: String
}
private struct CreatedIssuePayload {
    let id: String
    let url: URL
}

private struct ComposerMetadataEnvelope: Decodable { let data: ComposerMetadataData? }
private struct ComposerMetadataData: Decodable { let repository: ComposerRepository? }
private struct ComposerRepository: Decodable {
    let id: String
    let nameWithOwner: String
    let hasIssuesEnabled: Bool
    let viewerCanCreateIssues: Bool
    let viewerPermission: String?
    let assignableUsers: ComposerUserConnection
    let labels: ComposerLabelConnection?
    let milestones: ComposerMilestoneConnection?
    let issueTypes: ComposerIssueTypeConnection?
    let projectsV2: ComposerProjectConnection
    let issueTemplates: [ComposerTemplateResponse]?
    let owner: ComposerOwner
}
private struct ComposerOwner: Decodable { let ownerProjects: ComposerProjectConnection }
private struct ComposerUserConnection: Decodable {
    let pageInfo: PageInfo
    let nodes: [ComposerUserNode?]
}
private struct ComposerUserNode: Decodable { let id: String; let login: String }
private struct ComposerLabelConnection: Decodable {
    let pageInfo: PageInfo
    let nodes: [ComposerLabelNode?]
}
private struct ComposerLabelNode: Decodable { let id: String; let name: String }
private struct ComposerMilestoneConnection: Decodable {
    let pageInfo: PageInfo
    let nodes: [ComposerMilestoneNode?]
}
private struct ComposerMilestoneNode: Decodable { let id: String; let title: String }
private struct ComposerIssueTypeConnection: Decodable {
    let pageInfo: PageInfo
    let nodes: [ComposerIssueTypeNode?]
}
private struct ComposerIssueTypeNode: Decodable { let id: String; let name: String }
private struct ComposerProjectConnection: Decodable {
    let pageInfo: PageInfo
    let nodes: [ComposerProjectNode?]
}
private struct ComposerProjectNode: Decodable { let id: String; let title: String; let url: String }
private struct ComposerTemplateResponse: Decodable {
    let filename: String
    let name: String
    let about: String?
    let body: String?
    let title: String?
    let assignees: ComposerUserConnection
    let labels: ComposerLabelConnection?
    let type: ComposerIssueTypeNode?
}

private enum IssueReferenceKind: String { case parent, blockedBy, blocking }
private struct ParsedIssueReference {
    let kind: IssueReferenceKind
    let owner: String
    let repository: String
    let number: Int
    let displayValue: String
}
private struct GraphQLNode: Decodable {
    let typeName: String
    let id: String
    private enum CodingKeys: String, CodingKey { case typeName = "__typename", id }
}
private struct IssueCreationPreflightEnvelope: Decodable { let data: IssueCreationPreflightData? }
private struct IssueCreationPreflightData: Decodable {
    let repository: PreflightRepository?
    let assignees: [GraphQLNode?]
    let labels: [GraphQLNode?]
    let projects: [GraphQLNode?]
    let milestones: [GraphQLNode?]
    let issueTypes: [GraphQLNode?]
    let references: [String: ReferenceRepository?]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        repository = try container.decodeIfPresent(PreflightRepository.self, forKey: DynamicCodingKey("repository"))
        assignees = try container.decodeIfPresent([GraphQLNode?].self, forKey: DynamicCodingKey("assignees")) ?? []
        labels = try container.decodeIfPresent([GraphQLNode?].self, forKey: DynamicCodingKey("labels")) ?? []
        projects = try container.decodeIfPresent([GraphQLNode?].self, forKey: DynamicCodingKey("projects")) ?? []
        milestones = try container.decodeIfPresent([GraphQLNode?].self, forKey: DynamicCodingKey("milestones")) ?? []
        issueTypes = try container.decodeIfPresent([GraphQLNode?].self, forKey: DynamicCodingKey("issueTypes")) ?? []
        var decoded: [String: ReferenceRepository?] = [:]
        for key in container.allKeys where key.stringValue.hasPrefix("ref") {
            decoded[key.stringValue] = try container.decodeIfPresent(ReferenceRepository.self, forKey: key)
        }
        references = decoded
    }
}
private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
private struct PreflightRepository: Decodable {
    let id: String
    let nameWithOwner: String
    let hasIssuesEnabled: Bool
    let viewerCanCreateIssues: Bool
    let viewerPermission: String?
    let issueTemplates: [PreflightTemplate]
}
private struct PreflightTemplate: Decodable { let filename: String }
private struct ReferenceRepository: Decodable { let issue: ReferenceIssue? }
private struct ReferenceIssue: Decodable { let id: String }
private struct IssueCreationPreflight { let repository: PreflightRepository; let issueIDs: [String] }

private struct FullCreateIssueEnvelope: Decodable { let data: FullCreateIssueData? }
private struct FullCreateIssueData: Decodable { let createIssue: FullCreateIssuePayload? }
private struct FullCreateIssuePayload: Decodable { let issue: FullCreatedIssue? }
private struct FullCreatedIssue: Decodable {
    let id: String
    let url: String
    let projectItems: CreatedProjectItemConnection?
}
private struct CreatedProjectItemConnection: Decodable {
    let pageInfo: PageInfo?
    let nodes: [CreatedProjectItem?]
}
private struct CreatedProjectItem: Decodable { let id: String; let project: CreatedProjectReference }
private struct CreatedProjectReference: Decodable { let id: String }
private struct DecodedCreatedProjectItems {
    let items: [String: String]
    let hasNextPage: Bool
}
private struct CreatedProjectItemsResolutionEnvelope: Decodable { let data: CreatedProjectItemsResolutionData? }
private struct CreatedProjectItemsResolutionData: Decodable { let node: CreatedProjectItemsResolutionNode? }
private struct CreatedProjectItemsResolutionNode: Decodable { let projectItems: CreatedProjectItemConnection? }

private struct UpdateAssigneesEnvelope: Decodable { let data: UpdateAssigneesData? }
private struct UpdateAssigneesData: Decodable { let updateIssue: UpdateAssigneesPayload? }
private struct UpdateAssigneesPayload: Decodable { let issue: UpdatedAssigneeIssue? }
private struct UpdatedAssigneeIssue: Decodable { let assignees: ComposerUserConnection }

private struct AddProjectItemEnvelope: Decodable { let data: AddProjectItemData? }
private struct AddProjectItemData: Decodable { let addProjectV2ItemById: AddProjectItemPayload? }
private struct AddProjectItemPayload: Decodable { let item: AddedProjectItem? }
private struct AddedProjectItem: Decodable { let id: String }

private enum GitHubCLIProcess {
    static func run(input: Data) async throws -> Data {
        guard let executableURL = findExecutable() else {
            throw GitHubClientError.cliUnavailable
        }
        let cancellation = CLIProcessCancellation()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await Task.detached(priority: .userInitiated) {
                try runBlocking(
                    input: input,
                    executableURL: executableURL,
                    cancellation: cancellation
                )
            }.value
        }, onCancel: {
            cancellation.cancel()
        })
    }

    private static func findExecutable() -> URL? {
        let fixedPaths = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
        let pathEntries = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":", omittingEmptySubsequences: true)
            .map { String($0) + "/gh" } ?? []
        var visited = Set<String>()
        for path in fixedPaths + pathEntries where visited.insert(path).inserted {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    private static func runBlocking(
        input: Data,
        executableURL: URL,
        cancellation: CLIProcessCancellation
    ) throws -> Data {
        let process = Process()
        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()
        let terminated = DispatchSemaphore(value: 0)
        let readers = DispatchGroup()
        let outputResult = LockedResult<Data>()
        let errorResult = LockedResult<Data>()

        process.executableURL = executableURL
        process.arguments = ["api", "graphql", "--input", "-"]
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError
        process.terminationHandler = { _ in terminated.signal() }
        cancellation.register(process)
        defer { cancellation.clear(process) }

        do {
            try process.run()
        } catch {
            throw GitHubClientError.cliUnavailable
        }
        if cancellation.isCancelled {
            process.terminate()
            throw CancellationError()
        }

        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outputResult.set(Result { try standardOutput.fileHandleForReading.readToEnd() ?? Data() })
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errorResult.set(Result { try standardError.fileHandleForReading.readToEnd() ?? Data() })
            readers.leave()
        }

        do {
            try standardInput.fileHandleForWriting.write(contentsOf: input)
            try standardInput.fileHandleForWriting.close()
        } catch {
            process.terminate()
            _ = terminated.wait(timeout: .now() + 2)
            if cancellation.isCancelled { throw CancellationError() }
            throw GitHubClientError.cliFailed("could not send the request")
        }

        guard terminated.wait(timeout: .now() + 20) == .success else {
            process.terminate()
            _ = terminated.wait(timeout: .now() + 2)
            standardOutput.fileHandleForReading.closeFile()
            standardError.fileHandleForReading.closeFile()
            readers.wait()
            if cancellation.isCancelled { throw CancellationError() }
            throw GitHubClientError.cliTimedOut
        }

        readers.wait()
        if cancellation.isCancelled { throw CancellationError() }
        let output = try outputResult.get()
        let errorOutput = try errorResult.get()
        guard process.terminationStatus == 0 else {
            let rawMessage = String(decoding: errorOutput.prefix(1_000), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitHubClientError.cliFailed(rawMessage.isEmpty ? "exit code \(process.terminationStatus)" : rawMessage)
        }
        return output
    }
}

private final class CLIProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        let cancelled = self.cancelled
        lock.unlock()
        return cancelled
    }

    func register(_ process: Process) {
        lock.lock()
        self.process = process
        let cancelled = self.cancelled
        lock.unlock()
        if cancelled && process.isRunning { process.terminate() }
    }

    func clear(_ process: Process) {
        lock.lock()
        if self.process === process { self.process = nil }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()
        if let process, process.isRunning { process.terminate() }
    }
}

private final class LockedResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?

    func set(_ result: Result<Value, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func get() throws -> Value {
        lock.lock()
        let result = self.result
        lock.unlock()
        guard let result else { throw GitHubClientError.invalidResponse }
        return try result.get()
    }
}
