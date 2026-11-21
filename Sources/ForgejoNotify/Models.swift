import Foundation

/// One notification thread from `GET /api/v1/notifications`.
struct NotificationThread: Codable, Identifiable, Equatable {
    var id: Int
    var repository: Repository
    var subject: Subject
    var unread: Bool
    var pinned: Bool
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, repository, subject, unread, pinned
        case updatedAt = "updated_at"
    }

    struct Repository: Codable, Equatable {
        var fullName: String
        var htmlURL: String?

        enum CodingKeys: String, CodingKey {
            case fullName = "full_name"
            case htmlURL = "html_url"
        }
    }

    struct Subject: Codable, Equatable {
        var title: String
        var url: String?
        var latestCommentURL: String?
        var htmlURL: String?
        var latestCommentHTMLURL: String?
        var type: SubjectType
        var state: SubjectState?

        enum CodingKeys: String, CodingKey {
            case title, url, type, state
            case latestCommentURL = "latest_comment_url"
            case htmlURL = "html_url"
            case latestCommentHTMLURL = "latest_comment_html_url"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
            url = try c.decodeIfPresent(String.self, forKey: .url).nonEmpty
            latestCommentURL = try c.decodeIfPresent(String.self, forKey: .latestCommentURL).nonEmpty
            htmlURL = try c.decodeIfPresent(String.self, forKey: .htmlURL).nonEmpty
            latestCommentHTMLURL = try c.decodeIfPresent(String.self, forKey: .latestCommentHTMLURL).nonEmpty
            type = SubjectType(rawValue: try c.decodeIfPresent(String.self, forKey: .type) ?? "") ?? .other
            state = SubjectState(rawValue: try c.decodeIfPresent(String.self, forKey: .state) ?? "")
        }
    }

    /// Where clicking the notification goes: the latest comment if there is one, else the
    /// issue/PR/commit, else the repository.
    var webURL: URL? {
        for candidate in [subject.latestCommentHTMLURL, subject.htmlURL, repository.htmlURL] {
            if let candidate, let url = URL(string: candidate) { return url }
        }
        return nil
    }

    /// "#580" for issues and PRs, nil otherwise.
    var number: String? {
        guard subject.type == .issue || subject.type == .pull,
              let url = subject.url ?? subject.htmlURL,
              let last = url.split(separator: "/").last, Int(last) != nil else { return nil }
        return "#\(last)"
    }
}

enum SubjectType: String, Codable, CaseIterable, Identifiable {
    case issue = "Issue"
    case pull = "Pull"
    case commit = "Commit"
    case repository = "Repository"
    case other = "Other"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .issue: "Issues"
        case .pull: "Pull requests"
        case .commit: "Commits"
        case .repository: "Releases & repository events"
        case .other: "Other"
        }
    }
}

enum SubjectState: String, Codable, CaseIterable, Identifiable {
    case open, closed, merged

    var id: String { rawValue }
}

/// Extra details fetched per notification, only when a filter needs them.
struct Enrichment: Codable, Equatable {
    var author: String?
    var assignees: [String] = []
    var requestedReviewers: [String] = []
    var labels: [String] = []
    var draft = false
    var latestCommentAuthor: String?
    var latestCommentBody: String?
}

struct ForgejoUser: Codable, Equatable {
    var login: String
    var fullName: String?
    var avatarURL: String?

    enum CodingKeys: String, CodingKey {
        case login
        case fullName = "full_name"
        case avatarURL = "avatar_url"
    }
}

enum ForgejoError: Error, Equatable {
    case notConfigured
    case unauthorized(String?)
    case forbidden(String?)
    case http(Int, String?)
    case network(String)
    case decoding(String)
    case auth(String)

    var title: String {
        switch self {
        case .notConfigured: "Not signed in"
        case .unauthorized: "Sign-in expired"
        case .forbidden: "Access denied"
        case .http(let code, _): "Server error \(code)"
        case .network: "Can't reach Forgejo"
        case .decoding: "Unexpected response"
        case .auth: "Sign-in problem"
        }
    }

    var message: String {
        switch self {
        case .notConfigured:
            "Open Settings → Account to use your tea login, sign in with OAuth, or paste an access token."
        case .unauthorized(let detail):
            detail ?? "Forgejo rejected the token. Sign in again from Settings → Account."
        case .forbidden(let detail):
            detail ?? "The token doesn't have permission to read notifications (needs the notification scope)."
        case .http(_, let detail): detail ?? "The server returned an error."
        case .network(let detail): detail
        case .decoding(let detail): detail
        case .auth(let detail): detail
        }
    }

    var symbol: String {
        switch self {
        case .notConfigured: "person.crop.circle.badge.questionmark"
        case .unauthorized, .forbidden, .auth: "lock.trianglebadge.exclamationmark"
        case .network: "wifi.exclamationmark"
        default: "exclamationmark.triangle"
        }
    }
}

extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
