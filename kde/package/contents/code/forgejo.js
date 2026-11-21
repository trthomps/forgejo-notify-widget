.pragma library

// Port of Models.swift, Filters.swift, the tea config reader in Auth.swift, and Fmt.
// Plain JS so it can be unit-tested with node (see kde/test/forgejo.test.js).

var TYPES = ["Issue", "Pull", "Commit", "Repository", "Other"];

var typeTitles = {
    Issue: "Issues", Pull: "Pull requests", Commit: "Commits",
    Repository: "Releases & repository events", Other: "Other"
};

// MARK: - Parsing GET /api/v1/notifications

/// Milliseconds since epoch, or null. ISO-8601 with or without a fraction.
function parseDate(v) {
    if (typeof v !== "string" || v === "") return null;
    // V4's Date parser is picky about fractions and "+0100" offsets; normalize both.
    var trimmed = v.replace(/\.\d+/, "").replace(/([+-]\d\d)(\d\d)$/, "$1:$2");
    var t = Date.parse(trimmed);
    return isNaN(t) ? null : t;
}

function str(v) { return typeof v === "string" && v !== "" ? v : null; }

function parseThread(raw) {
    if (!raw || typeof raw !== "object" || typeof raw.id !== "number") return null;
    var repo = raw.repository || {};
    var subject = raw.subject || {};
    var type = TYPES.indexOf(subject.type) >= 0 ? subject.type : "Other";
    var state = ["open", "closed", "merged"].indexOf(subject.state) >= 0 ? subject.state : null;
    var updatedAt = parseDate(raw.updated_at);
    if (updatedAt === null) return null;
    return {
        id: raw.id,
        repo: typeof repo.full_name === "string" ? repo.full_name : "",
        repoURL: str(repo.html_url),
        title: typeof subject.title === "string" ? subject.title : "",
        url: str(subject.url),
        latestCommentURL: str(subject.latest_comment_url),
        htmlURL: str(subject.html_url),
        latestCommentHTMLURL: str(subject.latest_comment_html_url),
        type: type,
        state: state,
        unread: raw.unread === true,
        pinned: raw.pinned === true,
        updatedAt: updatedAt
    };
}

/// One page of notifications: { threads, rawCount }. rawCount counts entries before unparseable
/// ones are dropped, so paging can tell a full page from the last one.
/// Throws an error with .kind = "decoding" when the page isn't a list.
function parsePage(text) {
    var list;
    try { list = JSON.parse(text); } catch (e) { throw apiError("decoding", "Couldn't read the notification list."); }
    if (!Array.isArray(list)) throw apiError("decoding", "Expected a list of notifications.");
    return { threads: list.map(parseThread).filter(function (t) { return t !== null; }), rawCount: list.length };
}

function parseThreads(text) { return parsePage(text).threads; }

/// The URL to request for an API path or a server-supplied absolute URL, kept on `base`'s origin so
/// the token never goes to another host or scheme (e.g. a misconfigured ROOT_URL). null if it can't be.
function apiURL(base, pathOrURL) {
    if (pathOrURL.indexOf("://") < 0) return base + "/api/v1/" + pathOrURL.replace(/^\/+/, "");
    if (pathOrURL.indexOf(base + "/") === 0) return pathOrURL;
    var i = pathOrURL.indexOf("/api/v1/");
    return i < 0 ? null : base + pathOrURL.slice(i);
}

/// Where clicking goes: the latest comment, else the issue/PR/commit, else the repository.
function webURL(t) {
    return t.latestCommentHTMLURL || t.htmlURL || t.repoURL || null;
}

/// "#580" for issues and PRs, "" otherwise.
function number(t) {
    if (t.type !== "Issue" && t.type !== "Pull") return "";
    var url = t.url || t.htmlURL;
    if (!url) return "";
    var last = url.split("/").pop();
    return /^\d+$/.test(last) ? "#" + last : "";
}

function logins(list) {
    return Array.isArray(list) ? list.map(function (u) { return u && u.login; }).filter(Boolean) : [];
}

/// The parts of an issue (GET /repos/…/issues/N) the filters use.
function parseIssue(text) {
    var o = JSON.parse(text);
    return {
        author: o.user && o.user.login || null,
        assignees: logins(o.assignees),
        labels: Array.isArray(o.labels) ? o.labels.map(function (l) { return l && l.name; }).filter(Boolean) : [],
        draft: !!(o.pull_request && o.pull_request.draft)
    };
}

// MARK: - Filters (Filters.swift)

/// Comma- or newline-separated list, as stored in the config.
function patterns(text) {
    return String(text || "").split(/[,\n]/).map(function (s) { return s.trim(); })
        .filter(function (s) { return s.length > 0; });
}

/// Turns the widget's config into a filter object.
function filtersFromConfig(c) {
    return {
        types: patterns(c.filterTypes),
        hideClosed: !!c.filterHideClosed,
        hideMerged: !!c.filterHideMerged,
        hideDrafts: !!c.filterHideDrafts,
        onlyInvolved: !!c.filterOnlyInvolved,
        includeRepos: patterns(c.filterIncludeRepos),
        excludeRepos: patterns(c.filterExcludeRepos),
        excludeAuthors: patterns(c.filterExcludeAuthors),
        excludeCommenters: patterns(c.filterExcludeCommenters),
        excludeLabels: patterns(c.filterExcludeLabels),
        excludeTitles: patterns(c.filterExcludeTitles)
    };
}

function escapeRegex(s) { return s.replace(/[.*+?^${}()|[\]\\\/]/g, "\\$&"); }

/// Case-insensitive shell-style patterns: `renovate*`, `travis/*`, `*bot`.
function globMatches(pattern, text) {
    var re = "^";
    for (var i = 0; i < pattern.length; i++) {
        var c = pattern.charAt(i);
        re += c === "*" ? ".*" : c === "?" ? "." : escapeRegex(c);
    }
    return new RegExp(re + "$", "i").test(text);
}

function globAny(list, text) {
    for (var i = 0; i < list.length; i++) if (globMatches(list[i], text)) return true;
    return false;
}

function mentions(body, login) {
    if (!body || !login) return false;
    return new RegExp("(^|[^\\w])@" + escapeRegex(login) + "(?![\\w-])", "i").test(body);
}

/// Filters that need the issue/PR itself (author, labels, assignees, draft).
function needsIssue(f) {
    return f.onlyInvolved || f.hideDrafts || f.excludeAuthors.length > 0 || f.excludeLabels.length > 0;
}

/// Filters that need the latest comment.
function needsComment(f) { return f.onlyInvolved || f.excludeCommenters.length > 0; }

function isIssueLike(t) { return t.type === "Issue" || t.type === "Pull"; }

function cheapReason(f, t) {
    if (f.types.indexOf(t.type) < 0) return typeTitles[t.type];
    if (f.hideClosed && t.state === "closed") return "Closed";
    if (f.hideMerged && t.state === "merged") return "Merged";
    if (f.includeRepos.length > 0 && !globAny(f.includeRepos, t.repo)) return "Repo " + t.repo;
    if (globAny(f.excludeRepos, t.repo)) return "Repo " + t.repo;
    for (var i = 0; i < f.excludeTitles.length; i++) {
        var p = f.excludeTitles[i];
        if (globMatches(p.indexOf("*") >= 0 ? p : "*" + p + "*", t.title)) return "Title";
    }
    return null;
}

function needsEnrichment(f, t) {
    if (cheapReason(f, t) !== null) return false;
    return (needsIssue(f) && isIssueLike(t)) || (needsComment(f) && t.latestCommentURL !== null);
}

/// null if shown, otherwise a short reason it's hidden.
function hiddenReason(f, t, e, me) {
    var reason = cheapReason(f, t);
    if (reason !== null) return reason;
    if (e) {
        if (f.hideDrafts && e.draft) return "Draft";
        if (e.author && globAny(f.excludeAuthors, e.author)) return "Author " + e.author;
        for (var i = 0; i < (e.labels || []).length; i++)
            if (globAny(f.excludeLabels, e.labels[i])) return "Label " + e.labels[i];
        if (e.latestCommentAuthor && globAny(f.excludeCommenters, e.latestCommentAuthor))
            return "Comment by " + e.latestCommentAuthor;
    }
    if (f.onlyInvolved && me) {
        me = me.toLowerCase();
        if (!isIssueLike(t)) return "Not involved";
        // Lookup failed: we don't know, so show it rather than hide (and maybe auto-read) it.
        if (!e) return null;
        var lower = function (s) { return String(s).toLowerCase(); };
        var involved = (e.author && lower(e.author) === me)
            || (e.assignees || []).some(function (a) { return lower(a) === me; })
            || (e.requestedReviewers || []).some(function (a) { return lower(a) === me; })
            || mentions(e.latestCommentBody, me);
        // The comment lookup failed, so a mention can't be ruled out.
        if (!involved && e.commentFailed) return null;
        if (!involved) return "Not involved";
    }
    return null;
}

/// Splits threads into { shown, hidden } items ({ thread, reason }), pinned first, newest first.
function partition(threads, f, enrichments, me) {
    var shown = [], hidden = [];
    threads.forEach(function (t) {
        var cached = enrichments[t.id];
        var reason = hiddenReason(f, t, cached ? cached.value : null, me);
        (reason === null ? shown : hidden).push({ thread: t, reason: reason });
    });
    shown.sort(function (a, b) {
        if (a.thread.pinned !== b.thread.pinned) return a.thread.pinned ? -1 : 1;
        return b.thread.updatedAt - a.thread.updatedAt;
    });
    hidden.sort(function (a, b) { return b.thread.updatedAt - a.thread.updatedAt; });
    return { shown: shown, hidden: hidden };
}

/// How long a failed lookup is remembered before it's tried again (unless the thread changes).
var FAILURE_RETRY = 30 * 60 * 1000;

/// Threads whose enrichment is missing or out of date for the current filters.
/// A cached failure ({ value: null, failedAt }) counts as fresh for FAILURE_RETRY.
function staleEnrichments(threads, f, enrichments, now) {
    now = now || Date.now();
    return threads.filter(function (t) {
        if (!needsEnrichment(f, t)) return false;
        var c = enrichments[t.id];
        if (!c) return true;
        if (c.value === null) return c.updatedAt < t.updatedAt || !(now - c.failedAt < FAILURE_RETRY);
        return c.updatedAt < t.updatedAt
            || (needsComment(f) && !c.hasComment)
            || (f.onlyInvolved && !c.hasReviewers);
    });
}

/// The repos with the most items, for one-click "hide" suggestions.
function busiestRepos(threads, limit) {
    var counts = {};
    threads.forEach(function (t) { counts[t.repo] = (counts[t.repo] || 0) + 1; });
    return Object.keys(counts).sort(function (a, b) { return counts[b] - counts[a] || (a < b ? -1 : 1); })
        .slice(0, limit || 5).map(function (r) { return { repo: r, count: counts[r] }; });
}

// MARK: - tea config (just enough YAML for tea's `logins:` list of flat maps)

function parseTeaConfig(text) {
    var logins = [], current = null, inLogins = false, itemIndent = -1;
    function flush() {
        if (!current || !current.name || !current.url) return;
        var expiry = Number(current.token_expiry);
        logins.push({
            name: current.name, url: current.url, token: current.token || "",
            user: current.user || null, isDefault: current["default"] === "true",
            isOAuth: !!current.refresh_token || current.auth_method === "oauth",
            tokenExpiry: isFinite(expiry) && expiry > 0 ? expiry * 1000 : null
        });
    }
    String(text).split(/\r?\n/).forEach(function (raw) {
        var indent = raw.match(/^ */)[0].length;
        var line = raw.trim();
        if (line === "" || line.charAt(0) === "#") return;
        if (indent === 0) {
            if (inLogins) { flush(); current = null; }
            inLogins = line.indexOf("logins:") === 0;
            return;
        }
        if (!inLogins) return;
        if (line.indexOf("- ") === 0) {
            if (itemIndent < 0) itemIndent = indent;
            if (indent === itemIndent) { flush(); current = {}; line = line.slice(2); }
        }
        var colon = line.indexOf(":");
        if (!current || colon < 0) return;
        var key = line.slice(0, colon).trim();
        var value = line.slice(colon + 1).trim();
        var q = value.charAt(0);
        if (value.length >= 2 && (q === "\"" || q === "'") && value.charAt(value.length - 1) === q)
            value = value.slice(1, -1);
        current[key] = value;
    });
    if (inLogins) flush();
    return logins;
}

/// The named login, else tea's default, else the first.
function pickTeaLogin(logins, name) {
    for (var i = 0; i < logins.length; i++) if (logins[i].name === name) return logins[i];
    for (i = 0; i < logins.length; i++) if (logins[i].isDefault) return logins[i];
    return logins[0] || null;
}

/// `password=` from git's credential helper protocol.
function parseCredentialHelper(text) {
    var m = String(text).match(/^password=(.*)$/m);
    return m && m[1] ? m[1].trim() : null;
}

function normalizeServer(text) {
    var s = String(text || "").trim();
    if (!s) return null;
    if (s.indexOf("://") < 0) s = "https://" + s;
    s = s.replace(/\/+$/, "");
    return /^https?:\/\/[^\/\s]+/.test(s) ? s : null;
}

function hostOf(url) {
    var m = String(url).match(/^(\w+):\/\/([^\/]+)/);
    return m ? { protocol: m[1], host: m[2] } : null;
}

/// Single-quotes a value for /bin/sh.
function shellQuote(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'"; }

// MARK: - Errors (ForgejoError)

var errorText = {
    notConfigured: ["Not signed in",
        "Open Configure… → Account to use your tea login or an access token."],
    unauthorized: ["Sign-in expired", "Forgejo rejected the token. Sign in again from Configure… → Account."],
    forbidden: ["Access denied",
        "The token doesn't have permission to read notifications (needs the notification scope)."],
    http: ["Server error", "The server returned an error."],
    network: ["Can't reach Forgejo", "The request failed."],
    decoding: ["Unexpected response", "Couldn't read the server's response."],
    auth: ["Sign-in problem", ""]
};

var errorIcon = {
    notConfigured: "user-identity", unauthorized: "object-locked", forbidden: "object-locked",
    auth: "object-locked", network: "network-disconnect"
};

function apiError(kind, detail, status) {
    var e = new Error(detail || kind);
    e.kind = kind;
    e.detail = detail || "";
    e.status = status || 0;
    return e;
}

/// Maps an HTTP status (0 = no response) and body to an error, or null on success.
function errorForStatus(status, body) {
    if (status >= 200 && status < 300) return null;
    var message = null;
    try { var o = JSON.parse(body); if (o && typeof o.message === "string" && o.message) message = o.message; } catch (e) {}
    if (status === 0) return apiError("network", "");
    if (status === 401) return apiError("unauthorized", message, status);
    if (status === 403) return apiError("forbidden", message, status);
    return apiError("http", message, status);
}

function errorInfo(err) {
    if (!err) return null;
    var kind = errorText[err.kind] ? err.kind : "network";
    var t = errorText[kind];
    var title = kind === "http" && err.status ? "Server error " + err.status : t[0];
    var message = err.detail || t[1];
    return { kind: kind, title: title, message: message, icon: errorIcon[kind] || "dialog-warning" };
}

// MARK: - Formatting (Fmt)

var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

function ago(t, now, short) {
    var s = Math.max(0, (now - t) / 1000);
    if (s < 60) return short ? "now" : "just now";
    var m = Math.floor(s / 60), v;
    if (m < 60) v = m + "m";
    else if (m < 1440) v = Math.floor(m / 60) + "h";
    else if (m < 1440 * 30) v = Math.floor(m / 1440) + "d";
    else { var d = new Date(t); return months[d.getMonth()] + " " + d.getDate(); }
    return short ? v : v + " ago";
}

function countText(n) { return n > 99 ? "99+" : String(n); }

/// Seconds-precision ISO string, as Forgejo's last_read_at expects.
function isoSeconds(ms) { return new Date(Math.floor(ms / 1000) * 1000).toISOString().replace(".000Z", "Z"); }

/// Breeze icon and tint role for a row (PopoverView.swift NotificationRow).
function iconFor(t) {
    switch (t.type) {
    case "Pull": return t.state === "merged" ? "vcs-merge" : "vcs-merge-request";
    case "Issue": return t.state === "closed" ? "emblem-checked" : "data-information";
    case "Commit": return "vcs-commit";
    case "Repository": return "tag";
    default: return "notifications";
    }
}

/// "positive" | "negative" | "merged" | "neutral"
function tintFor(t) {
    if (t.state === "merged") return "merged";
    if (t.state === "closed") return t.type === "Issue" ? "merged" : "negative";
    if (t.state === "open") return "positive";
    return "neutral";
}
