import Foundation

/// What counts as a notification. Everything Forgejo reports is still there on the server;
/// this only decides what shows in the list and counts toward the badge.
struct FilterSettings: Equatable {
    var types: Set<SubjectType>
    var hideClosed: Bool
    var hideMerged: Bool
    var hideDrafts: Bool
    var onlyInvolved: Bool
    var includeRepos: [String]
    var excludeRepos: [String]
    var excludeAuthors: [String]
    var excludeCommenters: [String]
    var excludeLabels: [String]
    var excludeTitles: [String]

    static let none = FilterSettings(types: Set(SubjectType.allCases), hideClosed: false, hideMerged: false,
                                     hideDrafts: false, onlyInvolved: false, includeRepos: [], excludeRepos: [],
                                     excludeAuthors: [], excludeCommenters: [], excludeLabels: [], excludeTitles: [])

    /// Filters that need the issue/PR itself (author, labels, assignees, draft).
    var needsIssue: Bool {
        onlyInvolved || hideDrafts || !excludeAuthors.isEmpty || !excludeLabels.isEmpty
    }

    /// Filters that need the latest comment.
    var needsComment: Bool { onlyInvolved || !excludeCommenters.isEmpty }

    func needsEnrichment(_ thread: NotificationThread) -> Bool {
        guard passesCheapFilters(thread) == nil else { return false }
        let isIssueLike = thread.subject.type == .issue || thread.subject.type == .pull
        return (needsIssue && isIssueLike) || (needsComment && thread.subject.latestCommentURL != nil)
    }

    /// nil if shown, otherwise a short reason it's hidden.
    func hiddenReason(_ thread: NotificationThread, enrichment: Enrichment?, me: String?) -> String? {
        if let reason = passesCheapFilters(thread) { return reason }
        let isIssueLike = thread.subject.type == .issue || thread.subject.type == .pull

        if let e = enrichment {
            if hideDrafts, e.draft { return "Draft" }
            if let author = e.author, Glob.any(excludeAuthors, matches: author) { return "Author \(author)" }
            if let label = e.labels.first(where: { Glob.any(excludeLabels, matches: $0) }) { return "Label \(label)" }
            if let commenter = e.latestCommentAuthor, Glob.any(excludeCommenters, matches: commenter) {
                return "Comment by \(commenter)"
            }
        }
        if onlyInvolved, let me = me?.lowercased() {
            guard isIssueLike else { return "Not involved" }
            // Lookup failed: we don't know, so show it rather than hide (and maybe auto-read) it.
            guard let e = enrichment else { return nil }
            let involved = e.author?.lowercased() == me
                || e.assignees.contains { $0.lowercased() == me }
                || e.requestedReviewers.contains { $0.lowercased() == me }
                || Self.mentions(e.latestCommentBody, me)
            if !involved { return "Not involved" }
        }
        return nil
    }

    private func passesCheapFilters(_ thread: NotificationThread) -> String? {
        if !types.contains(thread.subject.type) { return thread.subject.type.title }
        if hideClosed, thread.subject.state == .closed { return "Closed" }
        if hideMerged, thread.subject.state == .merged { return "Merged" }
        let repo = thread.repository.fullName
        if !includeRepos.isEmpty, !Glob.any(includeRepos, matches: repo) { return "Repo \(repo)" }
        if Glob.any(excludeRepos, matches: repo) { return "Repo \(repo)" }
        if excludeTitles.contains(where: { Glob.matches($0.contains("*") ? $0 : "*\($0)*", thread.subject.title) }) {
            return "Title"
        }
        return nil
    }

    static func mentions(_ body: String?, _ login: String) -> Bool {
        guard let body, !login.isEmpty else { return false }
        let escaped = NSRegularExpression.escapedPattern(for: login)
        return body.range(of: "(^|[^\\w])@\(escaped)(?![\\w-])", options: [.regularExpression, .caseInsensitive]) != nil
    }
}

/// Case-insensitive shell-style patterns: `renovate*`, `travis/*`, `*bot`.
enum Glob {
    static func any(_ patterns: [String], matches text: String) -> Bool {
        patterns.contains { matches($0, text) }
    }

    static func matches(_ pattern: String, _ text: String) -> Bool {
        var regex = "^"
        for character in pattern {
            switch character {
            case "*": regex += ".*"
            case "?": regex += "."
            default: regex += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        regex += "$"
        return text.range(of: regex, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
