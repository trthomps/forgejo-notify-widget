import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.kirigami as Kirigami
import org.kde.notification

import "../code/forgejo.js" as F

PlasmoidItem {
    id: root

    // MARK: - State (NotificationStore.swift)

    property var threads: []
    property var shown: []               // [{ thread, reason }]
    property var hidden: []
    property var error: null             // F.errorInfo(...)
    property bool refreshing: false
    property bool enriching: false
    property real lastFetched: 0
    property var user: null              // { login }
    property string userFor: ""
    property var credential: null        // { baseURL, token, isOAuth, source, teaLogin }
    property real now: Date.now()
    property real lastTick: Date.now()

    property string cacheServer: ""
    property var enrichments: ({})       // id → { updatedAt, hasComment, hasReviewers, value }
    property var pendingReads: ({})      // id → thread.updatedAt when we marked it read
    property var announced: ({})
    property bool hasLoadedOnce: false
    /// Bumped when the account changes so in-flight results for the old one are dropped.
    property int generation: 0
    property bool refreshQueued: false

    readonly property var cfg: Plasmoid.configuration
    readonly property var filters: F.filtersFromConfig({
        filterTypes: cfg.filterTypes, filterHideClosed: cfg.filterHideClosed,
        filterHideMerged: cfg.filterHideMerged, filterHideDrafts: cfg.filterHideDrafts,
        filterOnlyInvolved: cfg.filterOnlyInvolved, filterIncludeRepos: cfg.filterIncludeRepos,
        filterExcludeRepos: cfg.filterExcludeRepos, filterExcludeAuthors: cfg.filterExcludeAuthors,
        filterExcludeCommenters: cfg.filterExcludeCommenters, filterExcludeLabels: cfg.filterExcludeLabels,
        filterExcludeTitles: cfg.filterExcludeTitles
    })
    readonly property int refreshSeconds: Math.max(30, cfg.refreshInterval)
    readonly property string accountKey: cfg.authMode + "|" + cfg.teaLogin + "|" + cfg.teaPath + "|" + cfg.serverURL

    /// Unread notifications that pass the filters: the badge number.
    readonly property int badgeCount: shown.filter(i => i.thread.unread).length
    readonly property bool canReadAll: badgeCount > 0
        || (cfg.readAllScope === "everything" && hidden.some(i => i.thread.unread))
    readonly property bool stale: lastFetched > 0
        && now - lastFetched > Math.max(refreshSeconds * 3, 5 * 60) * 1000
    readonly property string serverURL: credential ? credential.baseURL : ""

    /// "ok" | "loading" | "error", for the panel icon (MenuBarModel.make).
    readonly property string iconState: {
        if (error && (lastFetched === 0 || error.kind === "notConfigured")) return "error"
        if (lastFetched === 0) return "loading"
        if (error) return error.kind === "network" && !stale ? "ok" : "error"
        return "ok"
    }

    readonly property bool planar: Plasmoid.formFactor === PlasmaCore.Types.Planar
        || Plasmoid.formFactor === PlasmaCore.Types.MediaCenter

    readonly property color forgejoOrange: "#ff6600"
    readonly property color forgejoRed: "#d40000"

    onFiltersChanged: if (hasLoadedOnce) applyFilters(true)
    onAccountKeyChanged: accountChangeTimer.restart()

    Timer {
        // Typing a server URL changes the config on every keystroke; wait for it to settle.
        id: accountChangeTimer
        interval: 800
        onTriggered: root.accountChanged()
    }

    // MARK: - Representations

    Plasmoid.icon: "notifications"
    Plasmoid.backgroundHints: PlasmaCore.Types.DefaultBackground | PlasmaCore.Types.ConfigurableBackground
    Plasmoid.status: PlasmaCore.Types.ActiveStatus

    preferredRepresentation: planar ? fullRepresentation : compactRepresentation
    compactRepresentation: CompactRepresentation {}
    fullRepresentation: PopupView {}

    toolTipMainText: i18n("Forgejo Notifications")
    toolTipSubText: {
        if (error) return error.title
        if (lastFetched === 0) return i18n("Loading…")
        const hiddenText = hidden.length ? i18n(" · %1 filtered", hidden.length) : ""
        return (badgeCount === 0 ? i18n("No unread notifications") : i18np("%1 unread notification", "%1 unread notifications", badgeCount))
            + hiddenText
    }
    toolTipTextFormat: Text.PlainText

    Plasmoid.contextualActions: [
        PlasmaCore.Action {
            text: i18n("Refresh Now")
            icon.name: "view-refresh"
            onTriggered: root.refresh(true)
        },
        PlasmaCore.Action {
            text: i18n("Mark All as Read")
            icon.name: "mail-mark-read"
            enabled: root.canReadAll
            onTriggered: root.readAll()
        },
        PlasmaCore.Action {
            text: i18n("Open Notifications in Browser")
            icon.name: "internet-web-browser"
            enabled: root.serverURL !== ""
            onTriggered: root.openWeb()
        }
    ]

    onExpandedChanged: () => {
        if (expanded && (lastFetched === 0 || Date.now() - lastFetched > 20000)) refresh(false)
    }

    // MARK: - Shell (tea, secret-tool, reading tea's config)

    Shell {
        id: shell
        teaPath: root.cfg.teaPath
    }

    /// Resolves to a credential or rejects with an error (CredentialProvider.load).
    function loadCredential(forceRenew) {
        if (cfg.authMode === "token") {
            const base = F.normalizeServer(cfg.serverURL)
            if (!base) return Promise.reject(F.apiError("notConfigured"))
            return shell.run(shell.secretLookupCommand(base)).then(r => {
                const token = r.code === 0 ? r.stdout.trim() : ""
                if (!token) throw F.apiError("notConfigured")
                return { baseURL: base, token: token, isOAuth: false, source: i18n("Access token") }
            })
        }

        return shell.readTeaLogins().then(logins => {
            const login = F.pickTeaLogin(logins, cfg.teaLogin)
            if (!login) throw F.apiError("notConfigured")
            const base = F.normalizeServer(login.url)
            if (!base) throw F.apiError("notConfigured")
            const make = token => {
                if (!token) throw F.apiError("auth", i18n("tea has no token for “%1”. Run “tea login add” or check “tea login list”.", login.name))
                return { baseURL: base, token: token, isOAuth: login.isOAuth, source: "tea · " + login.name, teaLogin: login.name }
            }
            const expired = login.tokenExpiry !== null && login.tokenExpiry <= Date.now()
            // Older tea versions write the token into config.yml. Use it unless it's stale.
            if (login.token && !forceRenew && !expired) return make(login.token)
            // For OAuth logins, a harmless tea command makes tea refresh its own token. The
            // widget never refreshes it itself: that would rotate the refresh token out from under tea.
            const nudge = login.isOAuth && (forceRenew || expired) ? shell.teaNudge(login) : Promise.resolve()
            return nudge.then(() => forceRenew || expired ? shell.readTeaLogins() : logins).then(fresh => {
                const reloaded = F.pickTeaLogin(fresh, login.name) || login
                if (reloaded.token) return make(reloaded.token)
                return shell.teaHelperToken(reloaded).then(make)
            })
        })
    }

    function currentCredential() {
        if (credential) return Promise.resolve(credential)
        const started = generation
        return loadCredential(false).then(c => {
            if (started !== generation) throw F.apiError("cancelled")
            credential = c
            return c
        })
    }

    /// After a 401: renew once. Rejects with the original error if the token didn't change.
    function renewCredential(failed, original) {
        const started = generation
        return loadCredential(true).then(c => {
            if (started !== generation) throw F.apiError("cancelled")
            credential = c
            if (c.token === failed.token) throw original
            return c
        })
    }

    // MARK: - HTTP (ForgejoAPI.swift)

    property var inflight: []

    function request(cred, method, pathOrURL, query) {
        let url = pathOrURL.indexOf("://") > 0 ? pathOrURL : cred.baseURL + "/api/v1/" + pathOrURL
        if (query) {
            const parts = []
            Object.keys(query).sort().forEach(k => [].concat(query[k]).forEach(v =>
                parts.push(encodeURIComponent(k) + "=" + encodeURIComponent(v))))
            if (parts.length) url += (url.indexOf("?") >= 0 ? "&" : "?") + parts.join("&")
        }
        return new Promise((resolve, reject) => {
            const xhr = new XMLHttpRequest()
            const entry = { xhr: xhr, started: Date.now(), done: false, reject: reject }
            inflight.push(entry)
            xhr.onreadystatechange = () => {
                if (xhr.readyState !== XMLHttpRequest.DONE || entry.done) return
                entry.done = true
                inflight = inflight.filter(e => e !== entry)
                const err = F.errorForStatus(xhr.status, xhr.responseText)
                if (err) reject(err)
                else resolve(xhr.responseText)
            }
            xhr.open(method, url)
            xhr.setRequestHeader("Authorization", (cred.isOAuth ? "Bearer " : "token ") + cred.token)
            xhr.setRequestHeader("Accept", "application/json")
            xhr.setRequestHeader("User-Agent", "ForgejoNotify/kde")
            xhr.send()
        })
    }

    Timer {
        // QML's XMLHttpRequest has no timeout; abort anything older than 20 seconds.
        interval: 2000
        repeat: true
        running: root.inflight.length > 0
        onTriggered: {
            const cutoff = Date.now() - 20000
            root.inflight.filter(e => e.started < cutoff).forEach(e => {
                e.done = true
                e.xhr.abort()
                e.reject(F.apiError("network", i18n("The request timed out.")))
            })
            root.inflight = root.inflight.filter(e => !e.done)
        }
    }

    /// Runs `call(cred)` with the current credential, renewing it once on a 401.
    function withAPI(call) {
        return currentCredential().then(cred => call(cred).catch(err => {
            if (err.kind !== "unauthorized") throw err
            return renewCredential(cred, err).then(call)
        }))
    }

    function getJSON(cred, path, query) {
        return request(cred, "GET", path, query).then(text => {
            try { return JSON.parse(text) } catch (e) { throw F.apiError("decoding", i18n("Couldn't read %1.", path)) }
        })
    }

    /// All unread and pinned threads. Pages through up to 10 × 50.
    function fetchNotifications(cred) {
        const all = []
        const page = n => request(cred, "GET", "notifications",
                                  { "status-types": ["unread", "pinned"], limit: "50", page: String(n) })
            .then(text => {
                const batch = F.parseThreads(text)
                batch.forEach(t => all.push(t))
                if (batch.length >= 50 && n < 10) return page(n + 1)
                const seen = {}
                return all.filter(t => seen[t.id] ? false : (seen[t.id] = true))
            })
        return page(1)
    }

    function fetchEnrichment(cred, t, includeComment, includeReviewers) {
        const result = { author: null, assignees: [], requestedReviewers: [], labels: [], draft: false,
                         latestCommentAuthor: null, latestCommentBody: null }
        let chain = Promise.resolve()
        if (t.url && F.isIssueLike(t)) {
            chain = chain.then(() => request(cred, "GET", t.url)).then(text => {
                Object.assign(result, F.parseIssue(text))
                if (includeReviewers && t.type === "Pull")
                    return getJSON(cred, t.url.replace("/issues/", "/pulls/"))
                        .then(pull => { result.requestedReviewers = F.logins(pull.requested_reviewers) })
            })
        }
        if (includeComment && t.latestCommentURL) {
            chain = chain.then(() => getJSON(cred, t.latestCommentURL)).then(c => {
                result.latestCommentAuthor = c.user && c.user.login || null
                result.latestCommentBody = typeof c.body === "string" ? c.body : null
            })
        }
        return chain.then(() => result)
    }

    // MARK: - Refresh

    function refresh(userInitiated) {
        if (refreshing) {
            if (userInitiated) refreshQueued = true
            return
        }
        refreshing = true
        const started = generation
        const finish = () => {
            refreshing = false
            now = Date.now()
            if (refreshQueued) {
                refreshQueued = false
                Qt.callLater(() => refresh(true))
            }
        }
        withAPI(fetchNotifications).then(fetched => {
            if (started !== generation) return
            // Keep optimistic reads hidden until the server catches up.
            threads = fetched.filter(t => !(t.unread && pendingReads[t.id] !== undefined && t.updatedAt <= pendingReads[t.id]))
            const stillUnread = {}
            fetched.forEach(t => { if (t.unread) stillUnread[t.id] = true })
            const pr = {}
            Object.keys(pendingReads).forEach(id => { if (stillUnread[id]) pr[id] = pendingReads[id] })
            pendingReads = pr
            lastFetched = Date.now()
            error = null
            if (cacheServer !== serverURL) { enrichments = ({}); cacheServer = serverURL }
            rememberBusyRepos()
            return loadUserIfNeeded()
                .then(() => applyFilters(true))
                .then(() => {
                    if (started !== generation) return
                    autoReadFiltered()
                    announceNew()
                    hasLoadedOnce = true
                })
        }).catch(err => {
            if (started !== generation || err.kind === "cancelled") return
            console.warn("forgejo-notify: refresh failed:", err.kind, err.detail || err.message)
            error = F.errorInfo(err.kind ? err : F.apiError("network", String(err)))
        }).then(finish)
    }

    function loadUserIfNeeded() {
        if (!credential || (user && userFor === credential.baseURL)) return Promise.resolve()
        const base = credential.baseURL
        return withAPI(cred => getJSON(cred, "user")).then(u => {
            if (u && typeof u.login === "string") { user = { login: u.login }; userFor = base }
        }).catch(() => {})
    }

    function applyFilters(fetchDetails) {
        const f = filters
        const needed = fetchDetails ? F.staleEnrichments(threads, f, enrichments) : []
        const work = needed.length ? enrich(needed, f) : Promise.resolve()
        return work.then(() => {
            const p = F.partition(threads, f, enrichments, user ? user.login : null)
            shown = p.shown
            hidden = p.hidden
        })
    }

    function enrich(needed, f) {
        const started = generation
        const includeComment = F.needsComment(f)
        const includeReviewers = f.onlyInvolved
        enriching = true
        return currentCredential().then(cred => {
            const results = {}
            const queue = needed.slice()
            // Six at a time, like the macOS task group.
            const worker = () => {
                const t = queue.shift()
                if (!t) return Promise.resolve()
                return fetchEnrichment(cred, t, includeComment, includeReviewers)
                    .then(value => { results[t.id] = { updatedAt: t.updatedAt, hasComment: includeComment,
                                                       hasReviewers: includeReviewers, value: value } })
                    .catch(() => {})
                    .then(worker)
            }
            const workers = []
            for (let i = 0; i < 6; i++) workers.push(worker())
            return Promise.all(workers).then(() => {
                if (started !== generation) return
                const live = {}
                threads.forEach(t => { live[t.id] = true })
                const next = {}
                Object.keys(enrichments).forEach(id => { if (live[id]) next[id] = enrichments[id] })
                Object.keys(results).forEach(id => { next[id] = results[id] })
                enrichments = next
                saveCache()
            })
        }).catch(() => {}).then(() => { enriching = false })
    }

    function autoReadFiltered() {
        if (!cfg.filterAutoRead) return
        const targets = hidden.filter(i => i.thread.unread && !i.thread.pinned).map(i => i.thread)
        if (targets.length) markRead(targets)
    }

    function announceNew() {
        const current = {}
        shown.forEach(i => { if (i.thread.unread) current[i.thread.id] = true })
        const fresh = hasLoadedOnce && cfg.systemNotifications
            ? shown.filter(i => i.thread.unread && !announced[i.thread.id]).map(i => i.thread) : []
        announced = current
        if (fresh.length > 5) {
            postNotification(i18n("%1 new Forgejo notifications", fresh.length),
                             fresh.slice(0, 3).map(t => t.title).join("\n"), null)
        } else {
            fresh.forEach(t => postNotification([t.repo, F.number(t)].filter(Boolean).join(" "), t.title, t))
        }
    }

    Component {
        id: notificationComponent
        Notification {
            id: note
            property var thread: null
            componentName: "plasma_workspace"
            eventId: "notification"
            iconName: "notifications"
            autoDelete: true
            defaultAction: NotificationAction {
                label: i18n("Open")
                onActivated: note.thread ? root.open(note.thread) : root.openWeb()
            }
        }
    }

    function postNotification(title, text, thread) {
        const n = notificationComponent.createObject(root, { title: title, text: text, thread: thread })
        if (n) n.sendEvent()
    }

    // MARK: - Actions

    function open(t) {
        const url = F.webURL(t)
        if (url) Qt.openUrlExternally(url)
        if (cfg.markReadOnOpen && t.unread) markRead([t])
        root.expanded = false
    }

    function openWeb() {
        if (serverURL) Qt.openUrlExternally(serverURL + "/notifications")
    }

    function restore(targets) {
        const ids = {}
        targets.forEach(t => { ids[t.id] = t })
        const pr = Object.assign({}, pendingReads)
        targets.forEach(t => delete pr[t.id])
        pendingReads = pr
        // Put them back so it doesn't look handled when it isn't.
        const rest = threads.filter(t => !ids[t.id])
        threads = rest.concat(targets)
        applyFilters(false)
    }

    function markRead(targets) {
        if (!targets.length) return
        const started = generation
        const ids = {}
        targets.forEach(t => { ids[t.id] = true })
        const pr = Object.assign({}, pendingReads)
        targets.forEach(t => { pr[t.id] = t.updatedAt })
        pendingReads = pr
        threads = threads.filter(t => !ids[t.id] || t.pinned)
            .map(t => ids[t.id] ? Object.assign({}, t, { unread: false }) : t)
        applyFilters(false)
        withAPI(cred => Promise.all(targets.map(t =>
            request(cred, "PATCH", "notifications/threads/" + t.id, { "to-status": "read" }))))
            .catch(err => {
                if (started !== generation || err.kind === "cancelled") return
                error = F.errorInfo(err)
                restore(targets)
            })
    }

    function readAll() {
        if (cfg.readAllScope === "shown") {
            markRead(shown.filter(i => i.thread.unread).map(i => i.thread))
            return
        }
        if (!threads.length) return
        // Only clear what we've actually shown: anything newer than the latest thread we
        // fetched (in server time) stays unread.
        const cutoff = Math.max.apply(null, threads.map(t => t.updatedAt)) + 1000
        const started = generation
        const previous = threads.filter(t => t.unread)
        const pr = Object.assign({}, pendingReads)
        previous.forEach(t => { pr[t.id] = t.updatedAt })
        pendingReads = pr
        threads = threads.filter(t => t.pinned).map(t => Object.assign({}, t, { unread: false }))
        applyFilters(false)
        withAPI(cred => request(cred, "PUT", "notifications", {
            last_read_at: F.isoSeconds(cutoff), "to-status": "read", "status-types": "unread" }))
            .catch(err => {
                if (started !== generation || err.kind === "cancelled") return
                error = F.errorInfo(err)
                restore(previous)
            })
    }

    /// Appends a repo to the block-list (the popup's per-row "Hide" action).
    function hideRepo(repo) {
        const list = F.patterns(cfg.filterExcludeRepos)
        if (list.indexOf(repo) < 0) list.push(repo)
        cfg.filterExcludeRepos = list.join(", ")
    }

    /// Account settings changed: drop the cached credential and start over.
    function accountChanged() {
        generation += 1
        credential = null
        threads = []
        shown = []
        hidden = []
        user = null
        userFor = ""
        announced = ({})
        hasLoadedOnce = false
        pendingReads = ({})
        enrichments = ({})   // keyed by thread id, which means nothing on another server
        lastFetched = 0
        error = null
        refreshing = false
        refreshQueued = false
        saveCache()
        refresh(true)
    }

    // MARK: - Cache (issue/comment lookups, so filters don't refetch every poll)

    function saveCache() {
        cacheServer = serverURL
        const text = JSON.stringify({ server: serverURL, items: enrichments })
        if (text !== cfg.enrichmentCache) cfg.enrichmentCache = text
    }

    function loadCache() {
        try {
            const c = JSON.parse(cfg.enrichmentCache || "{}")
            if (c && c.items && typeof c.items === "object") {
                enrichments = c.items
                cacheServer = c.server || ""
            }
        } catch (e) {}
    }

    function rememberBusyRepos() {
        const text = JSON.stringify(F.busiestRepos(threads, 5))
        if (text !== cfg.busyRepos) cfg.busyRepos = text
    }

    // MARK: - Timers

    Timer {
        interval: root.refreshSeconds * 1000
        repeat: true
        running: true
        onTriggered: root.refresh(false)
    }

    Timer {
        // Keeps "5m ago" current, and notices resume from suspend (a big gap between ticks).
        interval: 30000
        repeat: true
        running: true
        onTriggered: {
            const t = Date.now()
            const slept = t - root.lastTick > 90000
            root.lastTick = t
            root.now = t
            if (slept) wakeTimer.restart()
        }
    }

    Timer {
        id: wakeTimer
        interval: 5000 // give the network a moment after resume
        onTriggered: root.refresh(false)
    }

    Component.onCompleted: {
        loadCache()
        refresh(false)
    }
}
