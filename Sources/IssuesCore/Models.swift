import Foundation

public enum IssueGroup: String, Codable, CaseIterable, Sendable {
    case inProgress, todo, other
    public var title: String {
        switch self { case .inProgress: return "In progress"; case .todo: return "To do"; case .other: return "Other statuses" }
    }
}

public struct ProjectReference: Codable, Equatable, Sendable {
    public var owner: String
    public var number: Int
    public var isOrganization: Bool
    public init(owner: String, number: Int, isOrganization: Bool) {
        self.owner = owner; self.number = number; self.isOrganization = isOrganization
    }
    public var url: URL { URL(string: "https://github.com/\(isOrganization ? "orgs" : "users")/\(owner)/projects/\(number)")! }
    public static func parse(_ input: String) -> ProjectReference? {
        guard let url = URL(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host?.lowercased() == "github.com" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 4, ["users", "orgs"].contains(parts[0]), parts[2] == "projects",
              let number = Int(parts[3]), number > 0, !parts[1].isEmpty else { return nil }
        return ProjectReference(owner: parts[1], number: number, isOrganization: parts[0] == "orgs")
    }
}

public struct GitHubIssue: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var number: Int
    public var title: String
    public var body: String
    public var url: URL
    public var repository: String
    public var status: String
    public var labels: [String]
    public var assignees: [String]
    public var updatedAt: Date
    public var projectItemID: String?
    public init(id: String, number: Int, title: String, body: String, url: URL, repository: String, status: String, labels: [String], assignees: [String], updatedAt: Date, projectItemID: String? = nil) {
        self.id=id; self.number=number; self.title=title; self.body=body; self.url=url; self.repository=repository; self.status=status; self.labels=labels; self.assignees=assignees; self.updatedAt=updatedAt; self.projectItemID=projectItemID
    }
}

public struct ProjectStatusOption: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id=id; self.name=name }
}

public struct ProjectStatusField: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var options: [ProjectStatusOption]
    public init(id: String, name: String, options: [ProjectStatusOption]) {
        self.id=id; self.name=name; self.options=options
    }
}

public struct ProjectMetadata: Codable, Equatable, Sendable {
    public var id: String
    public var projectURL: URL?
    public var statusField: ProjectStatusField?
    public var repositories: [String]
    public var viewerID: String?
    public init(id: String, projectURL: URL? = nil, statusField: ProjectStatusField?, repositories: [String], viewerID: String?) {
        self.id=id; self.projectURL=projectURL; self.statusField=statusField; self.repositories=repositories; self.viewerID=viewerID
    }
}

public struct CreatedProjectIssue: Codable, Equatable, Sendable {
    public var issueID: String
    public var url: URL
    public var projectItemID: String?
    public var warning: String?
    public init(issueID: String, url: URL, projectItemID: String?, warning: String?) {
        self.issueID=issueID; self.url=url; self.projectItemID=projectItemID; self.warning=warning
    }
}

public struct IssueChoice: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct ComposerProject: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var url: String
    public init(id: String, title: String, url: String) {
        self.id = id; self.title = title; self.url = url
    }
}

public struct ComposerTemplate: Codable, Equatable, Sendable {
    public var filename: String
    public var name: String
    public var about: String
    public var body: String
    public var title: String
    public var assigneeIDs: [String]
    public var labelIDs: [String]
    public var issueTypeID: String?
    public init(filename: String, name: String, about: String, body: String, title: String, assigneeIDs: [String] = [], labelIDs: [String] = [], issueTypeID: String? = nil) {
        self.filename = filename; self.name = name; self.about = about; self.body = body; self.title = title
        self.assigneeIDs = assigneeIDs; self.labelIDs = labelIDs; self.issueTypeID = issueTypeID
    }
}

public struct IssueComposerMetadata: Codable, Equatable, Sendable {
    public var repository: String
    public var repositoryID: String
    public var assignees: [IssueChoice]
    public var labels: [IssueChoice]
    public var milestones: [IssueChoice]
    public var issueTypes: [IssueChoice]
    public var projects: [ComposerProject]
    public var templates: [ComposerTemplate]
    public var canWrite: Bool
    public var warnings: [String]
    public init(repository: String, repositoryID: String, assignees: [IssueChoice] = [], labels: [IssueChoice] = [], milestones: [IssueChoice] = [], issueTypes: [IssueChoice] = [], projects: [ComposerProject] = [], templates: [ComposerTemplate] = [], canWrite: Bool, warnings: [String] = []) {
        self.repository = repository; self.repositoryID = repositoryID; self.assignees = assignees; self.labels = labels
        self.milestones = milestones; self.issueTypes = issueTypes; self.projects = projects; self.templates = templates
        self.canWrite = canWrite; self.warnings = warnings
    }
}

public struct IssueCreationRequest: Codable, Equatable, Sendable {
    public var projectID: String
    public var repository: String
    public var title: String
    public var body: String
    public var assigneeIDs: [String]
    public var labelIDs: [String]
    public var milestoneID: String?
    public var issueTypeID: String?
    public var templateFilename: String?
    public var additionalProjectIDs: [String]
    public var parentIssue: String?
    public var blockedBy: [String]
    public var blocking: [String]
    public var statusFieldID: String?
    public var statusOptionID: String?
    public init(projectID: String, repository: String, title: String, body: String, assigneeIDs: [String] = [], labelIDs: [String] = [], milestoneID: String? = nil, issueTypeID: String? = nil, templateFilename: String? = nil, additionalProjectIDs: [String] = [], parentIssue: String? = nil, blockedBy: [String] = [], blocking: [String] = [], statusFieldID: String? = nil, statusOptionID: String? = nil) {
        self.projectID = projectID; self.repository = repository; self.title = title; self.body = body
        self.assigneeIDs = assigneeIDs; self.labelIDs = labelIDs; self.milestoneID = milestoneID; self.issueTypeID = issueTypeID
        self.templateFilename = templateFilename; self.additionalProjectIDs = additionalProjectIDs; self.parentIssue = parentIssue
        self.blockedBy = blockedBy; self.blocking = blocking; self.statusFieldID = statusFieldID; self.statusOptionID = statusOptionID
    }
}

public struct ProjectSnapshot: Codable, Sendable {
    public var project: ProjectReference
    public var title: String
    public var viewerLogin: String
    public var issues: [GitHubIssue]
    public var fetchedAt: Date
    public var metadata: ProjectMetadata?
    public init(project: ProjectReference, title: String, viewerLogin: String, issues: [GitHubIssue], fetchedAt: Date, metadata: ProjectMetadata? = nil) {
        self.project=project; self.title=title; self.viewerLogin=viewerLogin; self.issues=issues; self.fetchedAt=fetchedAt; self.metadata=metadata
    }
}

public enum StatusMapping {
    public static func group(for status: String, inProgress: Set<String>, todo: Set<String>) -> IssueGroup {
        let value=status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if inProgress.contains(where: { $0.lowercased() == value }) { return .inProgress }
        if value.isEmpty || todo.contains(where: { $0.lowercased() == value }) { return .todo }
        return .other
    }
    public static let defaultInProgress: Set<String> = ["In Progress", "In progress", "In corso", "Doing"]
    public static let defaultTodo: Set<String> = ["Todo", "To do", "Backlog", "Da fare", "Ready"]
}
