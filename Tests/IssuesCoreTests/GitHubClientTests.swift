import Foundation
@testable import IssuesCore
#if canImport(XCTest)
import XCTest
#endif

enum GitHubClientFixtureTests {
    static func runAll() async throws {
        try await tokenFetchPaginatesAndFilters()
        try await projectResponseURLMustMatchRequestedReference()
        try await userProjectUsesUserOwnerSelection()
        try await cliFetchPaginates()
        try await graphQLErrorIsActionableAndRedacted()
        try await missingProjectIsActionable()
        try await httpAuthenticationFailureIsActionableAndRedacted()
        try await cancellationPropagates()
        try await updateStatusUsesRealIDs()
        try await clearStatusUsesClearMutation()
        try await writeScopeErrorIsActionable()
        try await createIssueRunsInRequiredOrder()
        try await createIssuePreservesURLWhenProjectAttachFails()
        try await createIssuePreservesItemWhenStatusFails()
        try await uncertainCreationIsNotRetried()
        try await composerMetadataMapsActualChoicesAndWarnsOnTruncation()
        try await fullCreateResolvesReferencesBeforeCreating()
        try await delayedProjectItemsAreReadBeforeStatus()
        try await permanentlyMissingProjectItemsRetainWarning()
        try await dependencyFailurePreservesCreatedURL()
        try await updateAssigneesReplacesAndReturnsAuthoritativeList()
        try await statoSingleSelectIsSupported()
    }

    static func userProjectUsesUserOwnerSelection() async throws {
        let response = Data(#"{"data":{"viewer":{"login":"octocat"},"user":{"projectV2":{"title":"Personal","items":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}"#.utf8)
        let recorder = RequestRecorder(responses: [response])
        let client = GitHubClient(
            tokenTransport: { request in (try await recorder.nextResponse(for: request), 200) },
            cliTransport: { _ in throw FixtureTestFailure("CLI transport should not be used") }
        )

        let snapshot = try await client.fetch(
            project: ProjectReference(owner: "octocat", number: 2, isOrganization: false),
            authentication: .token("token")
        )

        try require(snapshot.title == "Personal", "user project title")
        let body = String(decoding: try unwrap(await recorder.requestBodies().first, "user request body"), as: UTF8.self)
        try require(body.contains("user(login: $owner)"), "user owner selection")
        try require(!body.contains("organization(login: $owner)"), "organization owner excluded")
    }

    static func tokenFetchPaginatesAndFilters() async throws {
        let recorder = RequestRecorder(responses: [Self.firstPage, Self.secondPage])
        let fetchedAt = Date(timeIntervalSince1970: 1_789_382_400)
        let client = GitHubClient(
            tokenTransport: { request in
                let response = try await recorder.nextResponse(for: request)
                return (response, 200)
            },
            cliTransport: { _ in throw FixtureTestFailure("CLI transport should not be used") },
            now: { fetchedAt }
        )

        let snapshot = try await client.fetch(
            project: ProjectReference(owner: "acme", number: 7, isOrganization: true),
            authentication: .token("  secret-token\n")
        )

        try require(snapshot.title == "Roadmap", "project title")
        try require(snapshot.viewerLogin == "octocat", "viewer login")
        try require(snapshot.fetchedAt == fetchedAt, "fetch timestamp")
        try require(snapshot.issues.map(\.number) == [11, 12, 16], "open and closed issue order")
        try require(snapshot.issues[0].status == "Doing", "status")
        try require(snapshot.issues[0].labels == ["bug", "urgent"], "labels")
        try require(snapshot.issues[0].assignees == ["octocat"], "assignees")
        try require(snapshot.issues[0].projectItemID == "PVTI_open", "project item ID")
        try require(snapshot.issues[1].id == "I_closed", "closed repository issue included")
        try require(snapshot.issues[2].status == "Unfamiliar state", "unfamiliar status")
        try require(snapshot.metadata?.id == "PVT_roadmap", "project node ID")
        try require(snapshot.metadata?.projectURL?.absoluteString == "https://github.com/orgs/acme/projects/7", "project identity comes from GitHub response")
        try require(snapshot.metadata?.viewerID == "U_octocat", "viewer node ID")
        try require(snapshot.metadata?.statusField == ProjectStatusField(
            id: "PVTF_status",
            name: "Status",
            options: [
                ProjectStatusOption(id: "OPT_todo", name: "Todo"),
                ProjectStatusOption(id: "OPT_doing", name: "Doing")
            ]
        ), "real status field and options")
        try require(snapshot.metadata?.repositories == ["acme/api", "acme/app"], "linked and item repositories")

        let bodies = await recorder.requestBodies()
        try require(bodies.count == 2, "request count")
        try require(try cursor(in: bodies[0]) == .some(nil), "first cursor")
        try require(try cursor(in: bodies[1]) == .some("cursor-1"), "second cursor")
        let firstBody = String(decoding: bodies[0], as: UTF8.self)
        let authorizationValues = await recorder.authorizationValues()
        try require(authorizationValues == ["Bearer secret-token", "Bearer secret-token"], "trimmed bearer header")
        try require(firstBody.contains("fieldValueByName"), "direct status lookup")
        try require(firstBody.contains("Status"), "status field name")
        try require(!firstBody.localizedCaseInsensitiveContains("mutation"), "read-only query")
        try require(!firstBody.contains("secret-token"), "token excluded from request body")
    }

    static func projectResponseURLMustMatchRequestedReference() async throws {
        let response = Data(#"{"data":{"viewer":{"id":"U_1","login":"octocat"},"organization":{"projectV2":{"id":"PVT_1","title":"Wrong","url":"https://github.com/orgs/acme/projects/99","items":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}"#.utf8)
        let client = GitHubClient(
            tokenTransport: { _ in (response, 200) },
            cliTransport: { _ in Data() }
        )
        do {
            _ = try await client.fetch(project: ProjectReference(owner: "acme", number: 7, isOrganization: true), authentication: .token("token"))
            throw FixtureTestFailure("Mismatched project URL was accepted")
        } catch let error as GitHubClientError {
            guard case .invalidResponse = error else { throw error }
        }
    }

    static func cliFetchPaginates() async throws {
        let recorder = DataRecorder(responses: [Self.firstPage, Self.secondPage])
        let client = GitHubClient(
            tokenTransport: { _ in throw FixtureTestFailure("Token transport should not be used") },
            cliTransport: { body in await recorder.nextResponse(recording: body) },
            now: { Date(timeIntervalSince1970: 0) }
        )

        let snapshot = try await client.fetch(
            project: ProjectReference(owner: "acme", number: 7, isOrganization: true),
            authentication: .cli
        )

        try require(snapshot.issues.map(\.number) == [11, 12, 16], "CLI open and closed issue order")
        let bodies = await recorder.values()
        try require(bodies.count == 2, "CLI request count")
        try require(try cursor(in: bodies[1]) == .some("cursor-1"), "CLI second cursor")
    }

    static func graphQLErrorIsActionableAndRedacted() async throws {
        let response = Data(#"{"errors":[{"type":"FORBIDDEN","message":"Resource not accessible by integration"}]}"#.utf8)
        let client = GitHubClient(
            tokenTransport: { _ in (response, 200) },
            cliTransport: { _ in Data() }
        )

        do {
            _ = try await client.fetch(
                project: ProjectReference(owner: "acme", number: 7, isOrganization: true),
                authentication: .token("never-show-this-token")
            )
            throw FixtureTestFailure("Expected GraphQL fetch to fail")
        } catch {
            let message = error.localizedDescription
            try require(message.contains("read:project"), "GraphQL scope guidance")
            try require(!message.contains("never-show-this-token"), "GraphQL token redaction")
        }
    }

    static func missingProjectIsActionable() async throws {
        let response = Data(#"{"data":{"viewer":{"login":"octocat"},"organization":{"projectV2":null}}}"#.utf8)
        let client = GitHubClient(
            tokenTransport: { _ in (response, 200) },
            cliTransport: { _ in Data() }
        )

        do {
            _ = try await client.fetch(
                project: ProjectReference(owner: "acme", number: 7, isOrganization: true),
                authentication: .token("token")
            )
            throw FixtureTestFailure("Expected missing project fetch to fail")
        } catch {
            try require(error.localizedDescription.contains("read:project"), "missing project scope guidance")
        }
    }

    static func httpAuthenticationFailureIsActionableAndRedacted() async throws {
        let client = GitHubClient(
            tokenTransport: { _ in (Data(), 401) },
            cliTransport: { _ in Data() }
        )

        do {
            _ = try await client.fetch(
                project: ProjectReference(owner: "acme", number: 7, isOrganization: true),
                authentication: .token("private-token")
            )
            throw FixtureTestFailure("Expected HTTP fetch to fail")
        } catch {
            try require(error.localizedDescription.localizedCaseInsensitiveContains("token"), "HTTP auth guidance")
            try require(!error.localizedDescription.contains("private-token"), "HTTP token redaction")
        }
    }

    static func cancellationPropagates() async throws {
        let client = GitHubClient(
            tokenTransport: { _ in throw FixtureTestFailure("Token transport should not be used") },
            cliTransport: { _ in throw CancellationError() }
        )

        do {
            _ = try await client.fetch(
                project: ProjectReference(owner: "acme", number: 7, isOrganization: true),
                authentication: .cli
            )
            throw FixtureTestFailure("Expected cancellation")
        } catch is CancellationError {
            return
        } catch {
            throw FixtureTestFailure("Cancellation was wrapped as \(error.localizedDescription)")
        }
    }

    static func updateStatusUsesRealIDs() async throws {
        let response = Data(#"{"data":{"updateProjectV2ItemFieldValue":{"projectV2Item":{"id":"PVTI_1"}}}}"#.utf8)
        let recorder = RequestRecorder(responses: [response])
        let client = GitHubClient(
            tokenTransport: { request in (try await recorder.nextResponse(for: request), 200) },
            cliTransport: { _ in throw FixtureTestFailure("CLI transport should not be used") }
        )

        try await client.updateStatus(
            projectID: "PVT_1",
            itemID: "PVTI_1",
            fieldID: "PVTF_status",
            optionID: "OPT_doing",
            authentication: .token("token")
        )

        let body = try requestObject(try unwrap(await recorder.requestBodies().first, "update request"))
        let query = try unwrap(body["query"] as? String, "update query")
        let variables = try unwrap(body["variables"] as? [String: Any], "update variables")
        try require(query.contains("updateProjectV2ItemFieldValue"), "status update mutation")
        try require(query.contains("singleSelectOptionId"), "single-select status value")
        try require(variables["projectID"] as? String == "PVT_1", "update project ID")
        try require(variables["itemID"] as? String == "PVTI_1", "update item ID")
        try require(variables["fieldID"] as? String == "PVTF_status", "update field ID")
        try require(variables["optionID"] as? String == "OPT_doing", "update option ID")
    }

    static func clearStatusUsesClearMutation() async throws {
        let response = Data(#"{"data":{"clearProjectV2ItemFieldValue":{"projectV2Item":{"id":"PVTI_1"}}}}"#.utf8)
        let recorder = RequestRecorder(responses: [response])
        let client = GitHubClient(
            tokenTransport: { request in (try await recorder.nextResponse(for: request), 200) },
            cliTransport: { _ in throw FixtureTestFailure("CLI transport should not be used") }
        )

        try await client.updateStatus(
            projectID: "PVT_1",
            itemID: "PVTI_1",
            fieldID: "PVTF_status",
            optionID: nil,
            authentication: .token("token")
        )

        let body = try requestObject(try unwrap(await recorder.requestBodies().first, "clear request"))
        let query = try unwrap(body["query"] as? String, "clear query")
        let variables = try unwrap(body["variables"] as? [String: Any], "clear variables")
        try require(query.contains("clearProjectV2ItemFieldValue"), "status clear mutation")
        try require(!query.contains("updateProjectV2ItemFieldValue"), "clear does not update with a guessed value")
        try require(variables["optionID"] == nil, "clear omits option ID")
    }

    static func writeScopeErrorIsActionable() async throws {
        let response = Data(#"{"errors":[{"type":"FORBIDDEN","message":"Resource not accessible by integration"}]}"#.utf8)
        let client = GitHubClient(
            tokenTransport: { _ in (response, 200) },
            cliTransport: { _ in Data() }
        )
        do {
            try await client.updateStatus(
                projectID: "PVT_1",
                itemID: "PVTI_1",
                fieldID: "PVTF_status",
                optionID: "OPT_doing",
                authentication: .token("token")
            )
            throw FixtureTestFailure("Expected write scope failure")
        } catch {
            try require(error.localizedDescription.contains("`project`"), "project write scope guidance")
            try require(error.localizedDescription.contains("Issues write access"), "repository Issues guidance")
        }
    }

    static func createIssueRunsInRequiredOrder() async throws {
        let recorder = RequestRecorder(responses: [repositoryResponse, createdIssueResponse, addedItemResponse, updatedStatusResponse])
        let client = GitHubClient(
            tokenTransport: { request in (try await recorder.nextResponse(for: request), 200) },
            cliTransport: { _ in throw FixtureTestFailure("CLI transport should not be used") }
        )

        let result = try await client.createIssue(
            projectID: "PVT_1",
            repository: "acme/app",
            title: "Fixture issue",
            body: "First line\n\nSecond line",
            assigneeID: "U_octocat",
            statusFieldID: "PVTF_status",
            statusOptionID: "OPT_todo",
            authentication: .token("token")
        )

        try require(result.issueID == "I_created", "created issue ID")
        try require(result.url.absoluteString == "https://github.com/acme/app/issues/42", "created issue URL")
        try require(result.projectItemID == "PVTI_created", "created project item ID")
        try require(result.warning == nil, "full success has no warning")

        let bodies = await recorder.requestBodies()
        try require(bodies.count == 4, "repository, create, add, status request count")
        let queries = try bodies.map { body -> String in
            let object = try requestObject(body)
            return try unwrap(object["query"] as? String, "ordered query")
        }
        try require(queries[0].contains("IssueCreationRepository"), "repository resolution first")
        try require(queries[0].contains("viewerCanCreateIssues"), "repository issue permission check")
        try require(queries[0].contains("viewerPermission"), "repository permission resolution")
        try require(queries[1].contains("createIssue"), "issue creation second")
        try require(queries[2].contains("addProjectV2ItemById"), "project attach third")
        try require(queries[3].contains("updateProjectV2ItemFieldValue"), "status update fourth")

        let createVariables = try unwrap(try requestObject(bodies[1])["variables"] as? [String: Any], "create variables")
        try require(createVariables["repositoryID"] as? String == "R_app", "resolved repository ID")
        try require(createVariables["title"] as? String == "Fixture issue", "create title")
        try require(createVariables["body"] as? String == "First line\n\nSecond line", "create body")
        try require(createVariables["assigneeIDs"] as? [String] == ["U_octocat"], "viewer assignee ID")

        let addVariables = try unwrap(try requestObject(bodies[2])["variables"] as? [String: Any], "add variables")
        try require(addVariables["projectID"] as? String == "PVT_1", "add project ID")
        try require(addVariables["contentID"] as? String == "I_created", "add created issue ID")
    }

    static func createIssuePreservesURLWhenProjectAttachFails() async throws {
        let forbidden = Data(#"{"errors":[{"type":"FORBIDDEN","message":"Resource not accessible by integration"}]}"#.utf8)
        let recorder = RequestRecorder(responses: [repositoryResponse, createdIssueResponse, forbidden])
        let client = GitHubClient(
            tokenTransport: { request in (try await recorder.nextResponse(for: request), 200) },
            cliTransport: { _ in Data() }
        )

        let result = try await client.createIssue(
            projectID: "PVT_1", repository: "acme/app", title: "Fixture issue", body: "",
            assigneeID: nil, statusFieldID: "PVTF_status", statusOptionID: "OPT_todo",
            authentication: .token("token")
        )
        try require(result.url.absoluteString == "https://github.com/acme/app/issues/42", "partial success URL")
        try require(result.projectItemID == nil, "attach failure has no item ID")
        try require(result.warning?.contains("could not add") == true, "attach warning")
        let requestCount = await recorder.requestBodies().count
        try require(requestCount == 3, "no status request after attach failure")
    }

    static func createIssuePreservesItemWhenStatusFails() async throws {
        let forbidden = Data(#"{"errors":[{"type":"FORBIDDEN","message":"Resource not accessible by integration"}]}"#.utf8)
        let recorder = RequestRecorder(responses: [repositoryResponse, createdIssueResponse, addedItemResponse, forbidden])
        let client = GitHubClient(
            tokenTransport: { request in (try await recorder.nextResponse(for: request), 200) },
            cliTransport: { _ in Data() }
        )

        let result = try await client.createIssue(
            projectID: "PVT_1", repository: "acme/app", title: "Fixture issue", body: "",
            assigneeID: nil, statusFieldID: "PVTF_status", statusOptionID: "OPT_todo",
            authentication: .token("token")
        )
        try require(result.projectItemID == "PVTI_created", "status failure preserves item ID")
        try require(result.warning?.contains("could not set its status") == true, "status warning")
    }

    static func uncertainCreationIsNotRetried() async throws {
        let recorder = UncertainCreationRecorder(repositoryResponse: repositoryResponse)
        let client = GitHubClient(
            tokenTransport: { request in try await recorder.respond(to: request) },
            cliTransport: { _ in Data() }
        )
        do {
            _ = try await client.createIssue(
                projectID: "PVT_1", repository: "acme/app", title: "Fixture issue", body: "",
                assigneeID: nil, statusFieldID: nil, statusOptionID: nil,
                authentication: .token("token")
            )
            throw FixtureTestFailure("Expected uncertain creation failure")
        } catch {
            try require(error.localizedDescription.contains("before retrying"), "duplicate prevention guidance")
            let requestCount = await recorder.requestCount()
            try require(requestCount == 2, "creation sent exactly once")
        }
    }

    static func composerMetadataMapsActualChoicesAndWarnsOnTruncation() async throws {
        let recorder = RequestRecorder(responses: [composerMetadataResponse])
        let client = GitHubClient(
            tokenTransport: { request in (try await recorder.nextResponse(for: request), 200) },
            cliTransport: { _ in Data() }
        )
        let metadata = try await client.fetchIssueComposer(repository: "acme/app", authentication: .token("token"))
        try require(metadata.repositoryID == "R_app", "composer repository ID")
        try require(metadata.assignees == [IssueChoice(id: "U_octocat", name: "octocat")], "actual assignable user")
        try require(metadata.labels == [IssueChoice(id: "L_bug", name: "bug")], "actual label")
        try require(metadata.milestones == [IssueChoice(id: "M_v1", name: "Version 1")], "open milestone")
        try require(metadata.issueTypes == [IssueChoice(id: "IT_bug", name: "Bug")], "issue type")
        try require(Set(metadata.projects.map(\.id)) == Set(["PVT_linked", "PVT_owner"]), "linked and owner projects")
        try require(metadata.projects.first(where: { $0.id == "PVT_linked" })?.url == "https://github.com/orgs/acme/projects/1", "actual project URL")
        try require(metadata.templates.first?.assigneeIDs == ["U_octocat"], "template assignee IDs")
        try require(metadata.templates.first?.labelIDs == ["L_bug"], "template label IDs")
        try require(metadata.templates.first?.issueTypeID == "IT_bug", "template issue type")
        try require(metadata.canWrite == false, "READ permission does not imply metadata editing")
        try require(metadata.warnings.contains(where: { $0.contains("labels") }), "truncation warning")
    }

    static func fullCreateResolvesReferencesBeforeCreating() async throws {
        let recorder = RequestRecorder(responses: [fullPreflightResponse, fullCreatedIssueResponse, updatedStatusResponse, dependencyResponse, dependencyResponse])
        let client = GitHubClient(
            tokenTransport: { request in (try await recorder.nextResponse(for: request), 200) },
            cliTransport: { _ in Data() }
        )
        let result = try await client.createIssue(
            request: IssueCreationRequest(
                projectID: "PVT_1", repository: "acme/app", title: "Complete", body: "Body",
                assigneeIDs: ["U_octocat"], labelIDs: ["L_bug"], milestoneID: "M_v1",
                issueTypeID: "IT_bug", templateFilename: "bug.yml", additionalProjectIDs: ["PVT_2"],
                parentIssue: "9", blockedBy: ["https://github.com/acme/other/issues/10"], blocking: ["11"],
                statusFieldID: "PVTF_status", statusOptionID: "OPT_todo"
            ),
            authentication: .token("token")
        )
        try require(result.url.absoluteString == "https://github.com/acme/app/issues/42", "full create URL")
        try require(result.projectItemID == "PVTI_created", "active project item")
        try require(result.warning == nil, "full create warning")

        let bodies = await recorder.requestBodies()
        try require(bodies.count == 5, "preflight, create, status, and dependency count")
        let preflightQuery = try unwrap(try requestObject(bodies[0])["query"] as? String, "preflight query")
        try require(preflightQuery.contains("IssueCreationPreflight"), "preflight precedes create")
        try require(preflightQuery.contains("ref0") && preflightQuery.contains("ref1") && preflightQuery.contains("ref2"), "all references resolved together")
        let createVariables = try unwrap(try requestObject(bodies[1])["variables"] as? [String: Any], "full create variables")
        try require(createVariables["assigneeIDs"] as? [String] == ["U_octocat"], "multiple assignee input")
        try require(createVariables["labelIDs"] as? [String] == ["L_bug"], "label input")
        try require(createVariables["milestoneID"] as? String == "M_v1", "milestone input")
        try require(createVariables["issueTypeID"] as? String == "IT_bug", "issue type input")
        try require(createVariables["issueTemplate"] as? String == "bug.yml", "template input")
        try require(createVariables["parentIssueID"] as? String == "I_parent", "resolved parent input")
        try require(createVariables["projectV2IDs"] as? [String] == ["PVT_1", "PVT_2"], "all project IDs")
        let blockedByVariables = try unwrap(try requestObject(bodies[3])["variables"] as? [String: Any], "blocked-by variables")
        try require(blockedByVariables["subjectID"] as? String == "I_created", "new issue blocked subject")
        try require(blockedByVariables["blockingIssueID"] as? String == "I_blocker", "resolved blocking issue")
        let blockingVariables = try unwrap(try requestObject(bodies[4])["variables"] as? [String: Any], "blocking variables")
        try require(blockingVariables["subjectID"] as? String == "I_blocked", "resolved blocked issue")
        try require(blockingVariables["blockingIssueID"] as? String == "I_created", "new issue blocks target")
    }

    static func dependencyFailurePreservesCreatedURL() async throws {
        let forbidden = Data(#"{"errors":[{"type":"FORBIDDEN","message":"Resource not accessible by integration"}]}"#.utf8)
        let recorder = RequestRecorder(responses: [dependencyPreflightResponse, fullCreatedIssueResponse, forbidden])
        let client = GitHubClient(
            tokenTransport: { request in (try await recorder.nextResponse(for: request), 200) },
            cliTransport: { _ in Data() }
        )
        let result = try await client.createIssue(
            request: IssueCreationRequest(projectID: "PVT_1", repository: "acme/app", title: "Partial", body: "", blockedBy: ["10"]),
            authentication: .token("token")
        )
        try require(result.url.absoluteString == "https://github.com/acme/app/issues/42", "dependency failure preserves URL")
        try require(result.warning?.contains("could not add the dependency") == true, "dependency failure warning")
        let requestCount = await recorder.requestBodies().count
        try require(requestCount == 3, "dependency is not retried")
    }

    static func delayedProjectItemsAreReadBeforeStatus() async throws {
        let recorder = RequestRecorder(responses: [simplePreflightResponse, createdWithoutProjectItemsResponse, emptyResolvedProjectItemsResponse, resolvedProjectItemsResponse, updatedStatusResponse])
        let client = GitHubClient(
            tokenTransport: { request in (try await recorder.nextResponse(for: request), 200) },
            cliTransport: { _ in Data() }
        )
        let result = try await client.createIssue(
            request: IssueCreationRequest(
                projectID: "PVT_1", repository: "acme/app", title: "Delayed association", body: "",
                statusFieldID: "PVTF_status", statusOptionID: "OPT_todo"
            ),
            authentication: .token("token")
        )
        try require(result.projectItemID == "PVTI_created", "post-create read resolves active project item")
        try require(result.warning == nil, "resolved eventual consistency does not warn")
        let bodies = await recorder.requestBodies()
        try require(bodies.count == 5, "bounded recovery reads before status")
        let recoveryQuery = try unwrap(try requestObject(bodies[2])["query"] as? String, "recovery query")
        try require(recoveryQuery.contains("ResolveCreatedIssueProjectItems"), "project item recovery read")
        try require(recoveryQuery.contains("projectItems"), "recovery reads authoritative associations")
        let statusQuery = try unwrap(try requestObject(bodies[4])["query"] as? String, "status query")
        try require(statusQuery.contains("updateProjectV2ItemFieldValue"), "status follows resolved project item")
    }

    static func permanentlyMissingProjectItemsRetainWarning() async throws {
        let recorder = RequestRecorder(responses: [
            simplePreflightResponse, createdWithoutProjectItemsResponse,
            emptyResolvedProjectItemsResponse, emptyResolvedProjectItemsResponse, emptyResolvedProjectItemsResponse
        ])
        let client = GitHubClient(
            tokenTransport: { request in (try await recorder.nextResponse(for: request), 200) },
            cliTransport: { _ in Data() }
        )
        let result = try await client.createIssue(
            request: IssueCreationRequest(
                projectID: "PVT_1", repository: "acme/app", title: "Missing association", body: "",
                statusFieldID: "PVTF_status", statusOptionID: "OPT_todo"
            ),
            authentication: .token("token")
        )
        try require(result.url.absoluteString == "https://github.com/acme/app/issues/42", "permanent absence preserves confirmed URL")
        try require(result.projectItemID == nil, "permanent absence has no active item")
        try require(result.warning?.contains("did not confirm 1 requested project attachment") == true, "project warning retained")
        try require(result.warning?.contains("status could not be set") == true, "status warning retained")
        let bodies = await recorder.requestBodies()
        try require(bodies.count == 5, "project item reads are bounded to three")
        try require(bodies.dropFirst(2).allSatisfy { body in
            (try? requestObject(body)["query"] as? String)?.contains("ResolveCreatedIssueProjectItems") == true
        }, "no status mutation when project item remains absent")
    }

    static func updateAssigneesReplacesAndReturnsAuthoritativeList() async throws {
        let response = Data(#"{"data":{"updateIssue":{"issue":{"assignees":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}"#.utf8)
        let recorder = RequestRecorder(responses: [response])
        let client = GitHubClient(
            tokenTransport: { request in (try await recorder.nextResponse(for: request), 200) },
            cliTransport: { _ in Data() }
        )
        let authoritative = try await client.updateAssignees(issueID: "I_1", assigneeIDs: [], authentication: .token("token"))
        try require(authoritative.isEmpty, "authoritative cleared assignment")
        let body = try unwrap(await recorder.requestBodies().first, "assignee request")
        let variables = try unwrap(try requestObject(body)["variables"] as? [String: Any], "assignee variables")
        try require(variables["assigneeIDs"] as? [String] == [], "empty array replaces and clears")
        let query = try unwrap(try requestObject(body)["query"] as? String, "assignee query")
        try require(query.contains("updateIssue") && query.contains("assigneeIds"), "replace mutation")
    }

    static func statoSingleSelectIsSupported() async throws {
        let response = Data(#"""
        {"data":{"viewer":{"id":"U_1","login":"octocat"},"organization":{"projectV2":{
          "id":"PVT_1","title":"Roadmap",
          "fields":{"nodes":[
            {"__typename":"ProjectV2SingleSelectField","id":"PVTF_priority","name":"Priority","options":[{"id":"OPT_high","name":"High"}]},
            {"__typename":"ProjectV2SingleSelectField","id":"PVTF_stato","name":"Stato","options":[{"id":"OPT_fare","name":"Da fare"}]}
          ]},
          "repositories":{"nodes":[]},
          "items":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{
            "id":"PVTI_1","isArchived":false,"fieldValueByName":null,
            "statoValue":{"name":"Da fare","field":{"name":"Stato"}},
            "content":{"__typename":"Issue","id":"I_1","number":1,"title":"Fixture","body":"","url":"https://github.com/acme/app/issues/1","state":"OPEN","updatedAt":"2026-09-14T10:00:00Z","repository":{"nameWithOwner":"acme/app"},"labels":{"nodes":[]},"assignees":{"nodes":[]}}
          }]}
        }}}}
        """#.utf8)
        let client = GitHubClient(
            tokenTransport: { _ in (response, 200) },
            cliTransport: { _ in Data() }
        )
        let snapshot = try await client.fetch(
            project: ProjectReference(owner: "acme", number: 7, isOrganization: true),
            authentication: .token("token")
        )
        try require(snapshot.metadata?.statusField?.id == "PVTF_stato", "Stato field ID")
        try require(snapshot.issues.first?.status == "Da fare", "Stato value")
        try require(snapshot.metadata?.statusField?.name != "Priority", "Priority is not guessed as status")
    }

    private static func cursor(in body: Data) throws -> String?? {
        let object: [String: Any] = try unwrap(JSONSerialization.jsonObject(with: body) as? [String: Any], "request object")
        let variables: [String: Any] = try unwrap(object["variables"] as? [String: Any], "variables")
        guard let value = variables["cursor"] else { return nil }
        if value is NSNull { return .some(nil) }
        return .some(try unwrap(value as? String, "cursor string"))
    }

    private static let repositoryResponse = Data(#"{"data":{"repository":{"id":"R_app","nameWithOwner":"acme/app","hasIssuesEnabled":true,"viewerCanCreateIssues":true,"viewerPermission":"WRITE"}}}"#.utf8)
    private static let createdIssueResponse = Data(#"{"data":{"createIssue":{"issue":{"id":"I_created","url":"https://github.com/acme/app/issues/42"}}}}"#.utf8)
    private static let addedItemResponse = Data(#"{"data":{"addProjectV2ItemById":{"item":{"id":"PVTI_created"}}}}"#.utf8)
    private static let updatedStatusResponse = Data(#"{"data":{"updateProjectV2ItemFieldValue":{"projectV2Item":{"id":"PVTI_created"}}}}"#.utf8)
    private static let dependencyResponse = Data(#"{"data":{"addBlockedBy":{"issue":{"id":"I_created"},"blockingIssue":{"id":"I_blocker"}}}}"#.utf8)
    private static let simplePreflightResponse = Data(#"{"data":{"repository":{"id":"R_app","nameWithOwner":"acme/app","hasIssuesEnabled":true,"viewerCanCreateIssues":true,"viewerPermission":"WRITE","issueTemplates":[]},"assignees":[],"labels":[],"projects":[{"__typename":"ProjectV2","id":"PVT_1"}],"milestones":[],"issueTypes":[]}}"#.utf8)
    private static let createdWithoutProjectItemsResponse = Data(#"{"data":{"createIssue":{"issue":{"id":"I_created","url":"https://github.com/acme/app/issues/42","projectItems":{"nodes":[]}}}}}"#.utf8)
    private static let emptyResolvedProjectItemsResponse = Data(#"{"data":{"node":{"projectItems":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}"#.utf8)
    private static let resolvedProjectItemsResponse = Data(#"{"data":{"node":{"projectItems":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"PVTI_created","project":{"id":"PVT_1"}}]}}}}"#.utf8)
    private static let fullCreatedIssueResponse = Data(#"{"data":{"createIssue":{"issue":{"id":"I_created","url":"https://github.com/acme/app/issues/42","projectItems":{"nodes":[{"id":"PVTI_created","project":{"id":"PVT_1"}},{"id":"PVTI_other","project":{"id":"PVT_2"}}]}}}}}"#.utf8)
    private static let fullPreflightResponse = Data(#"{"data":{"repository":{"id":"R_app","nameWithOwner":"acme/app","hasIssuesEnabled":true,"viewerCanCreateIssues":true,"viewerPermission":"WRITE","issueTemplates":[{"filename":"bug.yml"}]},"assignees":[{"__typename":"User","id":"U_octocat"}],"labels":[{"__typename":"Label","id":"L_bug"}],"projects":[{"__typename":"ProjectV2","id":"PVT_1"},{"__typename":"ProjectV2","id":"PVT_2"}],"milestones":[{"__typename":"Milestone","id":"M_v1"}],"issueTypes":[{"__typename":"IssueType","id":"IT_bug"}],"ref0":{"issue":{"id":"I_parent"}},"ref1":{"issue":{"id":"I_blocker"}},"ref2":{"issue":{"id":"I_blocked"}}}}"#.utf8)
    private static let dependencyPreflightResponse = Data(#"{"data":{"repository":{"id":"R_app","nameWithOwner":"acme/app","hasIssuesEnabled":true,"viewerCanCreateIssues":true,"viewerPermission":"WRITE","issueTemplates":[]},"assignees":[],"labels":[],"projects":[{"__typename":"ProjectV2","id":"PVT_1"}],"milestones":[],"issueTypes":[],"ref0":{"issue":{"id":"I_blocker"}}}}"#.utf8)
    private static let composerMetadataResponse = Data(#"""
    {"data":{"repository":{
      "id":"R_app","nameWithOwner":"acme/app","hasIssuesEnabled":true,"viewerCanCreateIssues":true,"viewerPermission":"READ",
      "assignableUsers":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"U_octocat","login":"octocat"}]},
      "labels":{"pageInfo":{"hasNextPage":true,"endCursor":"more"},"nodes":[{"id":"L_bug","name":"bug"}]},
      "milestones":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"M_v1","title":"Version 1"}]},
      "issueTypes":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"IT_bug","name":"Bug"}]},
      "projectsV2":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"PVT_linked","title":"Linked","url":"https://github.com/orgs/acme/projects/1"}]},
      "issueTemplates":[{"filename":"bug.yml","name":"Bug","about":"Report a bug","body":"Body","title":"[Bug] ","type":{"id":"IT_bug","name":"Bug"},"assignees":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"U_octocat","login":"octocat"}]},"labels":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"L_bug","name":"bug"}]}}],
      "owner":{"ownerProjects":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"PVT_owner","title":"Owner","url":"https://github.com/orgs/acme/projects/2"},{"id":"PVT_linked","title":"Linked","url":"https://github.com/orgs/acme/projects/1"}]}}
    }}}
    """#.utf8)

    private static let firstPage = Data(#"""
    {
      "data": {
        "viewer": { "id": "U_octocat", "login": "octocat" },
        "organization": {
          "projectV2": {
            "id": "PVT_roadmap",
            "title": "Roadmap",
            "url": "https://github.com/orgs/acme/projects/7",
            "fields": {
              "nodes": [
                { "__typename": "ProjectV2SingleSelectField", "id": "PVTF_priority", "name": "Priority", "options": [{ "id": "OPT_high", "name": "High" }] },
                { "__typename": "ProjectV2SingleSelectField", "id": "PVTF_status", "name": "Status", "options": [{ "id": "OPT_todo", "name": "Todo" }, { "id": "OPT_doing", "name": "Doing" }] }
              ]
            },
            "repositories": { "nodes": [{ "nameWithOwner": "acme/api" }] },
            "items": {
              "pageInfo": { "hasNextPage": true, "endCursor": "cursor-1" },
              "nodes": [
                {
                  "id": "PVTI_open",
                  "isArchived": false,
                  "fieldValueByName": { "name": "Doing", "field": { "name": "Status" } },
                  "content": {
                    "__typename": "Issue", "id": "I_open", "number": 11,
                    "title": "Fix sync", "body": "Details", "url": "https://github.com/acme/app/issues/11",
                    "state": "OPEN", "updatedAt": "2026-09-14T10:00:00Z",
                    "repository": { "nameWithOwner": "acme/app" },
                    "labels": { "nodes": [{ "name": "bug" }, { "name": "urgent" }] },
                    "assignees": { "nodes": [{ "login": "octocat" }] }
                  }
                },
                {
                  "id": "PVTI_closed", "isArchived": false, "fieldValueByName": null,
                  "content": { "__typename": "Issue", "id": "I_closed", "number": 12, "title": "Done", "body": "", "url": "https://github.com/acme/app/issues/12", "state": "CLOSED", "updatedAt": "2026-09-14T09:00:00Z", "repository": { "nameWithOwner": "acme/app" }, "labels": { "nodes": [] }, "assignees": { "nodes": [] } }
                },
                { "id": "PVTI_pr", "isArchived": false, "fieldValueByName": null, "content": { "__typename": "PullRequest", "id": "PR_1" } },
                {
                  "id": "PVTI_archived", "isArchived": true, "fieldValueByName": null,
                  "content": { "__typename": "Issue", "id": "I_archived", "number": 13, "title": "Archived", "body": "", "url": "https://github.com/acme/app/issues/13", "state": "OPEN", "updatedAt": "2026-09-14T08:00:00Z", "repository": { "nameWithOwner": "acme/app" }, "labels": { "nodes": [] }, "assignees": { "nodes": [] } }
                },
                { "id": "PVTI_draft", "isArchived": false, "fieldValueByName": null, "content": { "__typename": "DraftIssue", "id": "DI_1" } }
              ]
            }
          }
        }
      }
    }
    """#.utf8)

    private static let secondPage = Data(#"""
    {
      "data": {
        "viewer": { "id": "U_octocat", "login": "octocat" },
        "organization": {
          "projectV2": {
            "id": "PVT_roadmap",
            "title": "Roadmap",
            "url": "https://github.com/orgs/acme/projects/7",
            "fields": { "nodes": [] },
            "repositories": { "nodes": [] },
            "items": {
              "pageInfo": { "hasNextPage": false, "endCursor": null },
              "nodes": [
                {
                  "id": "PVTI_unknown_status", "isArchived": false,
                  "fieldValueByName": { "name": "Unfamiliar state", "field": { "name": "Status" } },
                  "content": {
                    "__typename": "Issue", "id": "I_unknown_status", "number": 16,
                    "title": "Investigate", "body": "", "url": "https://github.com/acme/app/issues/16",
                    "state": "OPEN", "updatedAt": "2026-09-14T11:00:00Z",
                    "repository": { "nameWithOwner": "acme/app" },
                    "labels": { "nodes": [] }, "assignees": { "nodes": [] }
                  }
                },
                { "id": "PVTI_unknown", "isArchived": false, "fieldValueByName": null, "content": { "__typename": "Discussion", "id": "D_1" } }
              ]
            }
          }
        }
      }
    }
    """#.utf8)
}

#if canImport(XCTest)
final class GitHubClientTests: XCTestCase {
    func testTokenFetchPaginatesAndFilters() async throws { try await GitHubClientFixtureTests.tokenFetchPaginatesAndFilters() }
    func testProjectResponseURLMustMatchRequestedReference() async throws { try await GitHubClientFixtureTests.projectResponseURLMustMatchRequestedReference() }
    func testUserProjectUsesUserOwnerSelection() async throws { try await GitHubClientFixtureTests.userProjectUsesUserOwnerSelection() }
    func testCLIFetchPaginates() async throws { try await GitHubClientFixtureTests.cliFetchPaginates() }
    func testGraphQLErrorIsActionableAndRedacted() async throws { try await GitHubClientFixtureTests.graphQLErrorIsActionableAndRedacted() }
    func testMissingProjectIsActionable() async throws { try await GitHubClientFixtureTests.missingProjectIsActionable() }
    func testHTTPAuthenticationFailureIsActionableAndRedacted() async throws { try await GitHubClientFixtureTests.httpAuthenticationFailureIsActionableAndRedacted() }
    func testCancellationPropagates() async throws { try await GitHubClientFixtureTests.cancellationPropagates() }
    func testUpdateStatusUsesRealIDs() async throws { try await GitHubClientFixtureTests.updateStatusUsesRealIDs() }
    func testClearStatusUsesClearMutation() async throws { try await GitHubClientFixtureTests.clearStatusUsesClearMutation() }
    func testWriteScopeErrorIsActionable() async throws { try await GitHubClientFixtureTests.writeScopeErrorIsActionable() }
    func testCreateIssueRunsInRequiredOrder() async throws { try await GitHubClientFixtureTests.createIssueRunsInRequiredOrder() }
    func testCreateIssuePreservesURLWhenProjectAttachFails() async throws { try await GitHubClientFixtureTests.createIssuePreservesURLWhenProjectAttachFails() }
    func testCreateIssuePreservesItemWhenStatusFails() async throws { try await GitHubClientFixtureTests.createIssuePreservesItemWhenStatusFails() }
    func testUncertainCreationIsNotRetried() async throws { try await GitHubClientFixtureTests.uncertainCreationIsNotRetried() }
    func testComposerMetadataMapsActualChoicesAndWarnsOnTruncation() async throws { try await GitHubClientFixtureTests.composerMetadataMapsActualChoicesAndWarnsOnTruncation() }
    func testFullCreateResolvesReferencesBeforeCreating() async throws { try await GitHubClientFixtureTests.fullCreateResolvesReferencesBeforeCreating() }
    func testDelayedProjectItemsAreReadBeforeStatus() async throws { try await GitHubClientFixtureTests.delayedProjectItemsAreReadBeforeStatus() }
    func testPermanentlyMissingProjectItemsRetainWarning() async throws { try await GitHubClientFixtureTests.permanentlyMissingProjectItemsRetainWarning() }
    func testDependencyFailurePreservesCreatedURL() async throws { try await GitHubClientFixtureTests.dependencyFailurePreservesCreatedURL() }
    func testUpdateAssigneesReplacesAndReturnsAuthoritativeList() async throws { try await GitHubClientFixtureTests.updateAssigneesReplacesAndReturnsAuthoritativeList() }
    func testStatoSingleSelectIsSupported() async throws { try await GitHubClientFixtureTests.statoSingleSelectIsSupported() }
}
#endif

private actor RequestRecorder {
    private var responses: [Data]
    private var bodies: [Data] = []
    private var authorizations: [String?] = []

    init(responses: [Data]) { self.responses = responses }

    func nextResponse(for request: URLRequest) throws -> Data {
        bodies.append(try unwrap(request.httpBody, "request body"))
        authorizations.append(request.value(forHTTPHeaderField: "Authorization"))
        return responses.removeFirst()
    }

    func requestBodies() -> [Data] { bodies }
    func authorizationValues() -> [String?] { authorizations }
}

private actor DataRecorder {
    private var responses: [Data]
    private var recorded: [Data] = []

    init(responses: [Data]) { self.responses = responses }

    func nextResponse(recording value: Data) -> Data {
        recorded.append(value)
        return responses.removeFirst()
    }

    func values() -> [Data] { recorded }
}

private actor UncertainCreationRecorder {
    private let repositoryResponse: Data
    private var count = 0

    init(repositoryResponse: Data) { self.repositoryResponse = repositoryResponse }

    func respond(to request: URLRequest) throws -> (Data, Int) {
        _ = try unwrap(request.httpBody, "uncertain request body")
        count += 1
        if count == 1 { return (repositoryResponse, 200) }
        throw URLError(.networkConnectionLost)
    }

    func requestCount() -> Int { count }
}

struct FixtureTestFailure: Error, LocalizedError {
    let detail: String
    init(_ detail: String) { self.detail = detail }
    var errorDescription: String? { "Fixture assertion failed: \(detail)" }
}

func require(_ condition: @autoclosure () throws -> Bool, _ detail: String) throws {
    guard try condition() else { throw FixtureTestFailure(detail) }
}

func unwrap<Value>(_ value: Value?, _ detail: String) throws -> Value {
    guard let value else { throw FixtureTestFailure(detail) }
    return value
}

func requestObject(_ body: Data) throws -> [String: Any] {
    try unwrap(JSONSerialization.jsonObject(with: body) as? [String: Any], "request object")
}

#if CORE_TEST_HARNESS
@main struct CoreTestHarness {
    static func main() async throws {
        try await GitHubClientFixtureTests.runAll()
        try await IssueAttachmentFixtureTests.runAll()
        try ModelFixtureTests.runAll()
        print("IssuesCore fixture tests passed")
    }
}
#endif
