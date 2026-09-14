import Foundation

public enum IssueAttachmentError: Error, Equatable, LocalizedError, Sendable {
    case invalidRepository
    case fileUnavailable(String)
    case notRegularFile(String)
    case emptyFile(String)
    case unsupportedFileType(String)
    case fileTooLarge(String, maxBytes: Int64)
    case unsupportedAuthentication
    case authenticationUnavailable
    case authenticationFailed
    case repositoryUnavailable
    case writeAccessRequired
    case invalidResponse
    case invalidAssetURL
    case requestFailed
    case uploadFailed(Int)
    case rateLimited(String?)

    public var errorDescription: String? {
        switch self {
        case .invalidRepository:
            return "Enter a repository as owner/name."
        case .fileUnavailable(let name):
            return "The attachment \(name) is unavailable."
        case .notRegularFile(let name):
            return "The attachment \(name) is not a regular file."
        case .emptyFile(let name):
            return "The attachment \(name) is empty."
        case .unsupportedFileType(let ext):
            let value = ext.isEmpty ? "this file" : ".\(ext)"
            return "GitHub does not support \(value) as an issue attachment. Choose PNG, JPG, JPEG, GIF, WEBP, SVG, MP4, MOV, or WEBM."
        case .fileTooLarge(let name, let maxBytes):
            return "The attachment \(name) exceeds GitHub's \(maxBytes / 1_048_576) MB limit."
        case .unsupportedAuthentication:
            return "GitHub attachment uploads require an OAuth token, classic personal access token, or fine-grained personal access token."
        case .authenticationUnavailable:
            return "GitHub CLI could not provide an authentication token. Run `gh auth login` and try again."
        case .authenticationFailed:
            return "GitHub authentication failed. Check the saved token or run `gh auth status`."
        case .repositoryUnavailable:
            return "GitHub could not access that repository. Check its name and your repository access."
        case .writeAccessRequired:
            return "Attaching files requires write access to the repository."
        case .invalidResponse:
            return "GitHub returned an invalid attachment response. Try again shortly."
        case .invalidAssetURL:
            return "GitHub returned an untrusted attachment URL. The file was not added to the issue body."
        case .requestFailed:
            return "GitHub could not prepare the attachment upload. Check your connection and try again."
        case .uploadFailed(let status):
            return "GitHub could not upload the attachment (HTTP \(status))."
        case .rateLimited(let retryAfter):
            if let retryAfter, !retryAfter.isEmpty {
                return "GitHub rate limited the attachment upload. Retry after \(retryAfter)."
            }
            return "GitHub rate limited the attachment upload. Wait and try again."
        }
    }
}

struct IssueAttachmentFile: Sendable {
    let size: Int64
    let isRegular: Bool
}

public struct IssueAttachmentClient: Sendable {
    typealias APITransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    typealias UploadTransport = @Sendable (URLRequest, URL) async throws -> (Data, HTTPURLResponse)
    typealias CLITokenProvider = @Sendable () async throws -> String
    typealias FileInspector = @Sendable (URL) throws -> IssueAttachmentFile

    private let apiTransport: APITransport
    private let uploadTransport: UploadTransport
    private let cliTokenProvider: CLITokenProvider
    private let fileInspector: FileInspector

    public init() {
        let session = IssueAttachmentSession.shared
        self.init(
            apiTransport: { request in
                let (data, response) = try await session.data(for: request)
                guard let response = response as? HTTPURLResponse else { throw IssueAttachmentError.invalidResponse }
                return (data, response)
            },
            uploadTransport: { request, fileURL in
                let (data, response) = try await session.upload(for: request, fromFile: fileURL)
                guard let response = response as? HTTPURLResponse else { throw IssueAttachmentError.invalidResponse }
                return (data, response)
            },
            cliTokenProvider: { try await IssueAttachmentCLIToken.load() },
            fileInspector: { try Self.inspectFile($0) }
        )
    }

    init(
        apiTransport: @escaping APITransport,
        uploadTransport: @escaping UploadTransport,
        cliTokenProvider: @escaping CLITokenProvider,
        fileInspector: @escaping FileInspector
    ) {
        self.apiTransport = apiTransport
        self.uploadTransport = uploadTransport
        self.cliTokenProvider = cliTokenProvider
        self.fileInspector = fileInspector
    }

    public static func validate(fileURL: URL) throws {
        _ = try validatedFile(fileURL, inspector: { try inspectFile($0) })
    }

    public func upload(
        repository: String,
        fileURL: URL,
        authentication: GitHubAuthentication
    ) async throws -> String {
        let file = try Self.validatedFile(fileURL, inspector: fileInspector)
        let target = try Self.parseRepository(repository)
        let token = try await resolvedToken(authentication)
        let metadata = try await repositoryMetadata(owner: target.owner, name: target.name, token: token)
        guard metadata.databaseID > 0 else { throw IssueAttachmentError.repositoryUnavailable }
        guard ["ADMIN", "MAINTAIN", "WRITE"].contains(metadata.viewerPermission) else {
            throw IssueAttachmentError.writeAccessRequired
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "uploads.github.com"
        components.path = "/user-attachments/assets"
        components.queryItems = [
            URLQueryItem(name: "name", value: fileURL.lastPathComponent),
            URLQueryItem(name: "content_type", value: file.contentType),
            URLQueryItem(name: "repository_id", value: String(metadata.databaseID))
        ]
        guard let uploadURL = components.url else { throw IssueAttachmentError.invalidResponse }
        var request = try Self.authorizedRequest(url: uploadURL, token: token, allowedHost: "uploads.github.com")
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(file.size), forHTTPHeaderField: "Content-Length")

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await uploadTransport(request, fileURL)
        } catch let error as IssueAttachmentError {
            throw error
        } catch {
            throw IssueAttachmentError.requestFailed
        }
        switch response.statusCode {
        case 200...299:
            break
        case 401, 403:
            throw IssueAttachmentError.authenticationFailed
        case 404:
            throw IssueAttachmentError.writeAccessRequired
        case 429:
            throw IssueAttachmentError.rateLimited(response.value(forHTTPHeaderField: "Retry-After"))
        default:
            throw IssueAttachmentError.uploadFailed(response.statusCode)
        }

        guard let payload = try? JSONDecoder().decode(AssetResponse.self, from: data),
              Self.isTrustedAssetURL(payload.url) else {
            if (try? JSONDecoder().decode(AssetResponse.self, from: data))?.url != nil {
                throw IssueAttachmentError.invalidAssetURL
            }
            throw IssueAttachmentError.invalidResponse
        }
        return payload.url
    }

    private func resolvedToken(_ authentication: GitHubAuthentication) async throws -> String {
        let raw: String
        switch authentication {
        case .token(let token):
            raw = token
        case .cli:
            do { raw = try await cliTokenProvider() }
            catch { throw IssueAttachmentError.authenticationUnavailable }
        }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw IssueAttachmentError.authenticationUnavailable }
        guard token.hasPrefix("gho_") || token.hasPrefix("ghp_") || token.hasPrefix("github_pat_") else {
            throw IssueAttachmentError.unsupportedAuthentication
        }
        return token
    }

    private func repositoryMetadata(owner: String, name: String, token: String) async throws -> RepositoryMetadata {
        let url = URL(string: "https://api.github.com/graphql")!
        var request = try Self.authorizedRequest(url: url, token: token, allowedHost: "api.github.com")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": Self.repositoryQuery,
            "variables": ["owner": owner, "name": name]
        ])

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await apiTransport(request)
        } catch let error as IssueAttachmentError {
            throw error
        } catch {
            throw IssueAttachmentError.requestFailed
        }
        switch response.statusCode {
        case 200...299:
            break
        case 401, 403:
            throw IssueAttachmentError.authenticationFailed
        case 404:
            throw IssueAttachmentError.repositoryUnavailable
        default:
            throw IssueAttachmentError.requestFailed
        }

        guard let envelope = try? JSONDecoder().decode(RepositoryEnvelope.self, from: data),
              envelope.errors?.isEmpty != false,
              let repository = envelope.data?.repository else {
            throw IssueAttachmentError.repositoryUnavailable
        }
        return RepositoryMetadata(databaseID: repository.databaseID, viewerPermission: repository.viewerPermission)
    }

    private static func authorizedRequest(url: URL, token: String, allowedHost: String) throws -> URLRequest {
        guard url.scheme == "https", url.host?.lowercased() == allowedHost, url.user == nil, url.password == nil else {
            throw IssueAttachmentError.requestFailed
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }

    private static func parseRepository(_ value: String) throws -> (owner: String, name: String) {
        let parts = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw IssueAttachmentError.invalidRepository }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
        let owner = String(parts[0])
        let name = String(parts[1])
        guard !owner.isEmpty, !name.isEmpty,
              owner.unicodeScalars.allSatisfy(allowed.contains),
              name.unicodeScalars.allSatisfy(allowed.contains) else {
            throw IssueAttachmentError.invalidRepository
        }
        return (owner, name)
    }

    private static func validatedFile(_ fileURL: URL, inspector: FileInspector) throws -> ValidatedFile {
        let name = fileURL.lastPathComponent
        guard fileURL.isFileURL, !name.isEmpty else { throw IssueAttachmentError.fileUnavailable(name) }
        let ext = fileURL.pathExtension.lowercased()
        guard let type = supportedTypes[ext] else { throw IssueAttachmentError.unsupportedFileType(ext) }
        let info: IssueAttachmentFile
        do { info = try inspector(fileURL) }
        catch { throw IssueAttachmentError.fileUnavailable(name) }
        guard info.isRegular else { throw IssueAttachmentError.notRegularFile(name) }
        guard info.size > 0 else { throw IssueAttachmentError.emptyFile(name) }
        let maxBytes: Int64 = type.isVideo ? 100 * 1_024 * 1_024 : 10 * 1_024 * 1_024
        guard info.size <= maxBytes else { throw IssueAttachmentError.fileTooLarge(name, maxBytes: maxBytes) }
        return ValidatedFile(size: info.size, contentType: type.contentType)
    }

    private static func inspectFile(_ fileURL: URL) throws -> IssueAttachmentFile {
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        return IssueAttachmentFile(size: Int64(values.fileSize ?? -1), isRegular: values.isRegularFile == true)
    }

    private static func isTrustedAssetURL(_ value: String) -> Bool {
        guard let url = URL(string: value), url.scheme == "https", url.host?.lowercased() == "github.com",
              url.user == nil, url.password == nil else { return false }
        let components = url.pathComponents
        return components.count == 4 && components[1] == "user-attachments" && components[2] == "assets" && !components[3].isEmpty
    }

    private static let repositoryQuery = """
    query IssueAttachmentRepository($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) {
        databaseId
        viewerPermission
      }
    }
    """

    private static let supportedTypes: [String: (contentType: String, isVideo: Bool)] = [
        "png": ("image/png", false),
        "jpg": ("image/jpeg", false),
        "jpeg": ("image/jpeg", false),
        "gif": ("image/gif", false),
        "webp": ("image/webp", false),
        "svg": ("image/svg+xml", false),
        "mp4": ("video/mp4", true),
        "mov": ("video/quicktime", true),
        "webm": ("video/webm", true)
    ]
}

private struct ValidatedFile {
    let size: Int64
    let contentType: String
}

private struct RepositoryMetadata {
    let databaseID: Int64
    let viewerPermission: String
}

private struct RepositoryEnvelope: Decodable {
    struct Payload: Decodable {
        struct Repository: Decodable {
            let databaseID: Int64
            let viewerPermission: String

            private enum CodingKeys: String, CodingKey {
                case databaseID = "databaseId"
                case viewerPermission
            }
        }
        let repository: Repository?
    }
    struct GraphQLError: Decodable { let message: String? }
    let data: Payload?
    let errors: [GraphQLError]?
}

private struct AssetResponse: Decodable { let url: String }

final class IssueAttachmentSession: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = IssueAttachmentSession()

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }

    func upload(for request: URLRequest, fromFile fileURL: URL) async throws -> (Data, URLResponse) {
        try await session.upload(for: request, fromFile: fileURL)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(Self.redirectRequest(original: task.originalRequest, proposed: request))
    }

    static func redirectRequest(original: URLRequest?, proposed: URLRequest) -> URLRequest? {
        // Attachment uploads are irreversible and the official endpoint responds
        // directly. Never forward either its credential or raw file body.
        nil
    }
}

private enum IssueAttachmentCLIToken {
    static func load() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["gh", "auth", "token", "--hostname", "github.com"]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { process in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                guard process.terminationStatus == 0,
                      let token = String(data: data, encoding: .utf8),
                      !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continuation.resume(throwing: IssueAttachmentError.authenticationUnavailable)
                    return
                }
                continuation.resume(returning: token)
            }
            do { try process.run() }
            catch { continuation.resume(throwing: IssueAttachmentError.authenticationUnavailable) }
        }
    }
}
