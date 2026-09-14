import Foundation
@testable import IssuesCore
#if canImport(XCTest)
import XCTest
#endif

enum IssueAttachmentFixtureTests {
    static func runAll() async throws {
        try await uploadUsesGitHubProtocolInOrder()
        try await cliAuthenticationResolvesTokenOnlyWhenUploadStarts()
        try await unsupportedFilesNeverReachGitHub()
        try await repositoryPermissionIsCheckedBeforeUpload()
        try await untrustedAssetURLsAreRejected()
        try redirectsNeverForwardAttachmentData()
    }

    static func uploadUsesGitHubProtocolInOrder() async throws {
        let recorder = AttachmentRequestRecorder(
            metadata: #"{"data":{"repository":{"databaseId":42,"viewerPermission":"WRITE"}}}"#,
            upload: #"{"url":"https://github.com/user-attachments/assets/7d843dd8"}"#
        )
        let client = IssueAttachmentClient(
            apiTransport: { request in try await recorder.metadataResponse(for: request) },
            uploadTransport: { request, fileURL in try await recorder.uploadResponse(for: request, fileURL: fileURL) },
            cliTokenProvider: { throw AttachmentFixtureFailure("CLI token should not be requested") },
            fileInspector: { _ in IssueAttachmentFile(size: 8, isRegular: true) }
        )
        let fileURL = URL(fileURLWithPath: "/fixtures/error state.png")

        let url = try await client.upload(repository: "acme/widgets", fileURL: fileURL, authentication: .token("  ghp_fixture-token\n"))

        try attachmentRequire(url == "https://github.com/user-attachments/assets/7d843dd8", "permanent asset URL")
        let captured = try await recorder.captured()
        try attachmentRequire(captured.events == ["metadata", "upload"], "repository metadata must precede irreversible upload")
        try attachmentRequire(captured.apiRequest.url?.absoluteString == "https://api.github.com/graphql", "GraphQL API host")
        try attachmentRequire(captured.apiRequest.httpMethod == "POST", "GraphQL method")
        try attachmentRequire(captured.apiRequest.value(forHTTPHeaderField: "Authorization") == "Bearer ghp_fixture-token", "trimmed API credential")
        let body = try attachmentJSON(captured.apiRequest.httpBody)
        let variables = try attachmentUnwrap(body["variables"] as? [String: Any], "GraphQL variables")
        try attachmentRequire(variables["owner"] as? String == "acme", "repository owner")
        try attachmentRequire(variables["name"] as? String == "widgets", "repository name")

        let uploadURL = try attachmentUnwrap(captured.uploadRequest.url, "upload URL")
        let components = try attachmentUnwrap(URLComponents(url: uploadURL, resolvingAgainstBaseURL: false), "upload URL components")
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } })
        try attachmentRequire(components.scheme == "https" && components.host == "uploads.github.com", "trusted upload host")
        try attachmentRequire(components.path == "/user-attachments/assets", "official upload endpoint")
        try attachmentRequire(query == ["name": "error state.png", "content_type": "image/png", "repository_id": "42"], "official upload query")
        try attachmentRequire(captured.uploadRequest.value(forHTTPHeaderField: "Authorization") == "Bearer ghp_fixture-token", "upload credential")
        try attachmentRequire(captured.uploadRequest.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream", "raw byte content type")
        try attachmentRequire(captured.uploadRequest.value(forHTTPHeaderField: "Content-Length") == "8", "known content length")
        try attachmentRequire(captured.fileURL == fileURL, "selected file is streamed")
    }

    static func cliAuthenticationResolvesTokenOnlyWhenUploadStarts() async throws {
        let recorder = AttachmentRequestRecorder(
            metadata: #"{"data":{"repository":{"databaseId":7,"viewerPermission":"ADMIN"}}}"#,
            upload: #"{"url":"https://github.com/user-attachments/assets/cli"}"#
        )
        let tokenCalls = AttachmentCounter()
        let client = IssueAttachmentClient(
            apiTransport: { request in try await recorder.metadataResponse(for: request) },
            uploadTransport: { request, fileURL in try await recorder.uploadResponse(for: request, fileURL: fileURL) },
            cliTokenProvider: {
                await tokenCalls.increment()
                return "gho_cli-token"
            },
            fileInspector: { _ in IssueAttachmentFile(size: 1, isRegular: true) }
        )

        let callsBeforeUpload = await tokenCalls.value()
        try attachmentRequire(callsBeforeUpload == 0, "constructing and queuing a file must not resolve credentials or upload")
        _ = try await client.upload(repository: "acme/widgets", fileURL: URL(fileURLWithPath: "/fixtures/demo.mov"), authentication: .cli)
        let callsAfterUpload = await tokenCalls.value()
        try attachmentRequire(callsAfterUpload == 1, "CLI credential resolved in memory for the explicit upload")
        let captured = try await recorder.captured()
        try attachmentRequire(captured.uploadRequest.value(forHTTPHeaderField: "Authorization") == "Bearer gho_cli-token", "CLI credential used only for GitHub")
    }

    static func unsupportedFilesNeverReachGitHub() async throws {
        let calls = AttachmentCounter()
        let client = IssueAttachmentClient(
            apiTransport: { _ in await calls.increment(); throw AttachmentFixtureFailure("unexpected API request") },
            uploadTransport: { _, _ in await calls.increment(); throw AttachmentFixtureFailure("unexpected upload") },
            cliTokenProvider: { await calls.increment(); return "gho_unexpected" },
            fileInspector: { _ in IssueAttachmentFile(size: 20, isRegular: true) }
        )

        do {
            _ = try await client.upload(repository: "acme/widgets", fileURL: URL(fileURLWithPath: "/fixtures/report.pdf"), authentication: .cli)
            throw AttachmentFixtureFailure("PDF upload unexpectedly succeeded")
        } catch let error as IssueAttachmentError {
            try attachmentRequire(error == .unsupportedFileType("pdf"), "PDF is explicitly unsupported")
        }
        let callCount = await calls.value()
        try attachmentRequire(callCount == 0, "unsupported files never resolve credentials or reach GitHub")
    }

    static func repositoryPermissionIsCheckedBeforeUpload() async throws {
        let uploadCalls = AttachmentCounter()
        let client = IssueAttachmentClient(
            apiTransport: { request in
                let data = Data(#"{"data":{"repository":{"databaseId":42,"viewerPermission":"READ"}}}"#.utf8)
                return (data, attachmentResponse(for: request, status: 200))
            },
            uploadTransport: { _, _ in await uploadCalls.increment(); throw AttachmentFixtureFailure("unexpected upload") },
            cliTokenProvider: { throw AttachmentFixtureFailure("CLI token should not be requested") },
            fileInspector: { _ in IssueAttachmentFile(size: 1, isRegular: true) }
        )

        do {
            _ = try await client.upload(repository: "acme/widgets", fileURL: URL(fileURLWithPath: "/fixtures/shot.webp"), authentication: .token("github_pat_fixture"))
            throw AttachmentFixtureFailure("read-only upload unexpectedly succeeded")
        } catch let error as IssueAttachmentError {
            try attachmentRequire(error == .writeAccessRequired, "write access error")
        }
        let uploadCount = await uploadCalls.value()
        try attachmentRequire(uploadCount == 0, "permission is checked before upload")
    }

    static func untrustedAssetURLsAreRejected() async throws {
        let client = IssueAttachmentClient(
            apiTransport: { request in
                let data = Data(#"{"data":{"repository":{"databaseId":42,"viewerPermission":"MAINTAIN"}}}"#.utf8)
                return (data, attachmentResponse(for: request, status: 200))
            },
            uploadTransport: { request, _ in
                try attachmentRequire(request.url?.host == "uploads.github.com", "credential-bearing upload is host-bound")
                let data = Data(#"{"url":"https://uploads.evil.example/asset"}"#.utf8)
                return (data, attachmentResponse(for: request, status: 201))
            },
            cliTokenProvider: { throw AttachmentFixtureFailure("CLI token should not be requested") },
            fileInspector: { _ in IssueAttachmentFile(size: 1, isRegular: true) }
        )

        do {
            _ = try await client.upload(repository: "acme/widgets", fileURL: URL(fileURLWithPath: "/fixtures/shot.svg"), authentication: .token("ghp_fixture"))
            throw AttachmentFixtureFailure("untrusted asset URL unexpectedly succeeded")
        } catch let error as IssueAttachmentError {
            try attachmentRequire(error == .invalidAssetURL, "returned URL host is allowlisted")
        }
    }

    static func redirectsNeverForwardAttachmentData() throws {
        let original = URLRequest(url: URL(string: "https://uploads.github.com/user-attachments/assets")!)
        var crossHost = URLRequest(url: URL(string: "https://storage.example.test/signed-upload")!)
        crossHost.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        let sameHost = URLRequest(url: URL(string: "https://uploads.github.com/redirected")!)

        try attachmentRequire(IssueAttachmentSession.redirectRequest(original: original, proposed: crossHost) == nil,
                              "cross-host redirect must not receive credentials or file bytes")
        try attachmentRequire(IssueAttachmentSession.redirectRequest(original: original, proposed: sameHost) == nil,
                              "the direct upload endpoint must not redirect file bytes")
    }
}

#if canImport(XCTest)
final class IssueAttachmentTests: XCTestCase {
    func testUploadUsesGitHubProtocolInOrder() async throws { try await IssueAttachmentFixtureTests.uploadUsesGitHubProtocolInOrder() }
    func testCLIAuthenticationResolvesTokenOnlyWhenUploadStarts() async throws { try await IssueAttachmentFixtureTests.cliAuthenticationResolvesTokenOnlyWhenUploadStarts() }
    func testUnsupportedFilesNeverReachGitHub() async throws { try await IssueAttachmentFixtureTests.unsupportedFilesNeverReachGitHub() }
    func testRepositoryPermissionIsCheckedBeforeUpload() async throws { try await IssueAttachmentFixtureTests.repositoryPermissionIsCheckedBeforeUpload() }
    func testUntrustedAssetURLsAreRejected() async throws { try await IssueAttachmentFixtureTests.untrustedAssetURLsAreRejected() }
    func testRedirectsNeverForwardAttachmentData() throws { try IssueAttachmentFixtureTests.redirectsNeverForwardAttachmentData() }
}
#endif

private actor AttachmentRequestRecorder {
    private let metadata: Data
    private let upload: Data
    private var events: [String] = []
    private var apiRequest: URLRequest?
    private var uploadRequest: URLRequest?
    private var fileURL: URL?

    init(metadata: String, upload: String) {
        self.metadata = Data(metadata.utf8)
        self.upload = Data(upload.utf8)
    }

    func metadataResponse(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        events.append("metadata")
        apiRequest = request
        return (metadata, attachmentResponse(for: request, status: 200))
    }

    func uploadResponse(for request: URLRequest, fileURL: URL) throws -> (Data, HTTPURLResponse) {
        events.append("upload")
        uploadRequest = request
        self.fileURL = fileURL
        return (upload, attachmentResponse(for: request, status: 201))
    }

    func captured() throws -> (events: [String], apiRequest: URLRequest, uploadRequest: URLRequest, fileURL: URL) {
        (events,
         try attachmentUnwrap(apiRequest, "captured API request"),
         try attachmentUnwrap(uploadRequest, "captured upload request"),
         try attachmentUnwrap(fileURL, "captured file URL"))
    }
}

private actor AttachmentCounter {
    private var count = 0
    func increment() { count += 1 }
    func value() -> Int { count }
}

private struct AttachmentFixtureFailure: Error, LocalizedError {
    let detail: String
    init(_ detail: String) { self.detail = detail }
    var errorDescription: String? { detail }
}

private func attachmentResponse(for request: URLRequest, status: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
}

private func attachmentJSON(_ data: Data?) throws -> [String: Any] {
    let data = try attachmentUnwrap(data, "JSON request body")
    return try attachmentUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], "JSON object")
}

private func attachmentRequire(_ condition: @autoclosure () throws -> Bool, _ detail: String) throws {
    guard try condition() else { throw AttachmentFixtureFailure(detail) }
}

private func attachmentUnwrap<Value>(_ value: Value?, _ detail: String) throws -> Value {
    guard let value else { throw AttachmentFixtureFailure(detail) }
    return value
}
