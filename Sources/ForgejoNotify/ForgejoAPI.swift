import Foundation

/// What every API call needs: where the server is and how to authenticate.
struct Credential: Equatable {
    var baseURL: URL
    var token: String
    var isOAuth: Bool
    /// Where it came from, for display: "tea · forgejo", "OAuth", "Access token".
    var source: String

    var authorizationHeader: String { isOAuth ? "Bearer \(token)" : "token \(token)" }
}

/// Thin wrapper over the parts of the Forgejo REST API this app uses.
struct ForgejoAPI {
    let credential: Credential
    var session: URLSession = .shared

    private var api: URL { credential.baseURL.appendingPathComponent("api/v1") }

    // MARK: - Notifications

    /// All unread (and pinned) threads, newest first. Pages through up to `maxPages` × 50.
    func notifications(maxPages: Int = 10) async throws -> [NotificationThread] {
        var all: [NotificationThread] = []
        for page in 1...maxPages {
            let batch: [NotificationThread] = try await get("notifications", query: [
                "status-types": ["unread", "pinned"],
                "limit": ["50"],
                "page": ["\(page)"],
            ])
            all.append(contentsOf: batch)
            if batch.count < 50 { break }
        }
        var seen = Set<Int>()
        return all.filter { seen.insert($0.id).inserted }
    }

    func markRead(threadID: Int) async throws {
        try await send("PATCH", "notifications/threads/\(threadID)", query: ["to-status": ["read"]])
    }

    /// Marks everything unread up to `before` as read on the server.
    func markAllRead(before: Date) async throws {
        try await send("PUT", "notifications", query: [
            "last_read_at": [ISO8601DateFormatter().string(from: before)],
            "to-status": ["read"],
            "status-types": ["unread"],
        ])
    }

    func currentUser() async throws -> ForgejoUser {
        try await get("user")
    }

    // MARK: - Enrichment

    /// Author, assignees, labels, reviewers and the latest comment for one thread.
    func enrichment(for thread: NotificationThread, includeComment: Bool, includeReviewers: Bool) async throws -> Enrichment {
        var result = Enrichment()
        if let url = thread.subject.url.flatMap(URL.init(string:)),
           thread.subject.type == .issue || thread.subject.type == .pull {
            let issue: IssueDTO = try await get(absolute: url)
            result.author = issue.user?.login
            result.assignees = (issue.assignees ?? []).map(\.login)
            result.labels = (issue.labels ?? []).map(\.name)
            result.draft = issue.pullRequest?.draft ?? false
            if includeReviewers, thread.subject.type == .pull,
               let pullURL = URL(string: url.absoluteString.replacingOccurrences(of: "/issues/", with: "/pulls/")) {
                let pull: PullDTO = try await get(absolute: pullURL)
                result.requestedReviewers = (pull.requestedReviewers ?? []).map(\.login)
            }
        }
        if includeComment, let url = thread.subject.latestCommentURL.flatMap(URL.init(string:)) {
            let comment: CommentDTO = try await get(absolute: url)
            result.latestCommentAuthor = comment.user?.login
            result.latestCommentBody = comment.body
        }
        return result
    }

    private struct LoginDTO: Decodable { var login: String }
    private struct LabelDTO: Decodable { var name: String }
    private struct IssueDTO: Decodable {
        var user: LoginDTO?
        var assignees: [LoginDTO]?
        var labels: [LabelDTO]?
        var pullRequest: PullRef?
        struct PullRef: Decodable { var draft: Bool? }
        enum CodingKeys: String, CodingKey {
            case user, assignees, labels
            case pullRequest = "pull_request"
        }
    }
    private struct PullDTO: Decodable {
        var requestedReviewers: [LoginDTO]?
        enum CodingKeys: String, CodingKey { case requestedReviewers = "requested_reviewers" }
    }
    private struct CommentDTO: Decodable {
        var user: LoginDTO?
        var body: String?
    }

    // MARK: - Plumbing

    private func url(_ path: String, query: [String: [String]]) -> URL {
        var components = URLComponents(url: api.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        let items = query.sorted { $0.key < $1.key }.flatMap { key, values in
            values.map { URLQueryItem(name: key, value: $0) }
        }
        if !items.isEmpty { components.queryItems = items }
        return components.url!
    }

    private func get<T: Decodable>(_ path: String, query: [String: [String]] = [:]) async throws -> T {
        try await get(absolute: url(path, query: query))
    }

    private func get<T: Decodable>(absolute url: URL) async throws -> T {
        let data = try await perform(request(url, method: "GET"))
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw ForgejoError.decoding("Couldn't read \(url.path): \(error)")
        }
    }

    private func send(_ method: String, _ path: String, query: [String: [String]]) async throws {
        _ = try await perform(request(url(path, query: query), method: method))
    }

    private func request(_ url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue(credential.authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ForgejoNotify/0.1", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ForgejoError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw ForgejoError.network("No HTTP response") }
        Debug.log("\(request.httpMethod ?? "") \(request.url?.path ?? "") → \(http.statusCode)")
        switch http.statusCode {
        case 200..<300: return data
        case 401: throw ForgejoError.unauthorized(Self.serverMessage(data))
        case 403: throw ForgejoError.forbidden(Self.serverMessage(data))
        default: throw ForgejoError.http(http.statusCode, Self.serverMessage(data))
        }
    }

    private static func serverMessage(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (object["message"] as? String).nonEmpty
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = parseDate(text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(text)"))
        }
        return decoder
    }()

    static func parseDate(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}
