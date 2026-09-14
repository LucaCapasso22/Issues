import Foundation
@testable import IssuesCore
#if canImport(XCTest)
import XCTest
#endif

enum ModelFixtureTests {
    static func runAll() throws {
        try projectReferenceParsesSupportedURLs()
        try projectReferenceRejectsInvalidURLs()
        try unknownStatusMapsToOther()
        try oldCacheDecodesWithoutEditingMetadata()
    }

    static func projectReferenceParsesSupportedURLs() throws {
        try require(
            ProjectReference.parse("https://github.com/orgs/acme/projects/7")
                == ProjectReference(owner: "acme", number: 7, isOrganization: true),
            "organization project URL"
        )
        try require(
            ProjectReference.parse("  https://github.com/users/octocat/projects/2\n")
                == ProjectReference(owner: "octocat", number: 2, isOrganization: false),
            "user project URL"
        )
    }

    static func projectReferenceRejectsInvalidURLs() throws {
        try require(ProjectReference.parse("http://github.com/orgs/acme/projects/7") == nil, "reject HTTP")
        try require(ProjectReference.parse("https://example.com/orgs/acme/projects/7") == nil, "reject foreign host")
        try require(ProjectReference.parse("https://github.com/repos/acme/projects/7") == nil, "reject unsupported route")
        try require(ProjectReference.parse("https://github.com/orgs/acme/projects/0") == nil, "reject project zero")
        try require(ProjectReference.parse("not a url") == nil, "reject malformed URL")
    }

    static func unknownStatusMapsToOther() throws {
        let status = "Waiting for vendor"
        try require(
            StatusMapping.group(for: status, inProgress: StatusMapping.defaultInProgress, todo: StatusMapping.defaultTodo)
                == .other,
            "unknown status group"
        )
        try require(status == "Waiting for vendor", "unknown status value")
    }

    static func oldCacheDecodesWithoutEditingMetadata() throws {
        let oldCache = Data(#"""
        {
          "project": { "owner": "acme", "number": 7, "isOrganization": true },
          "title": "Roadmap",
          "viewerLogin": "octocat",
          "issues": [{
            "id": "I_1", "number": 1, "title": "Cached issue", "body": "",
            "url": "https://github.com/acme/app/issues/1", "repository": "acme/app",
            "status": "Todo", "labels": [], "assignees": [], "updatedAt": 0
          }],
          "fetchedAt": 0
        }
        """#.utf8)
        let snapshot = try JSONDecoder().decode(ProjectSnapshot.self, from: oldCache)
        try require(snapshot.metadata == nil, "old snapshot metadata defaults to nil")
        try require(snapshot.issues.first?.projectItemID == nil, "old issue item ID defaults to nil")
        try require(snapshot.issues.first?.title == "Cached issue", "old cached issue preserved")

        _ = GitHubIssue(
            id: "I_2", number: 2, title: "Source compatible", body: "",
            url: URL(string: "https://github.com/acme/app/issues/2")!, repository: "acme/app",
            status: "", labels: [], assignees: [], updatedAt: Date(timeIntervalSinceReferenceDate: 0)
        )
        _ = ProjectSnapshot(
            project: ProjectReference(owner: "acme", number: 7, isOrganization: true),
            title: "Roadmap", viewerLogin: "octocat", issues: [], fetchedAt: Date(timeIntervalSinceReferenceDate: 0)
        )
    }
}

#if canImport(XCTest)
final class ModelsTests: XCTestCase {
    func testProjectReferenceParsesSupportedURLs() throws { try ModelFixtureTests.projectReferenceParsesSupportedURLs() }
    func testProjectReferenceRejectsInvalidURLs() throws { try ModelFixtureTests.projectReferenceRejectsInvalidURLs() }
    func testUnknownStatusMapsToOther() throws { try ModelFixtureTests.unknownStatusMapsToOther() }
    func testOldCacheDecodesWithoutEditingMetadata() throws { try ModelFixtureTests.oldCacheDecodesWithoutEditingMetadata() }
}
#endif
