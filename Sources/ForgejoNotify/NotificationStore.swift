import AppKit
import Combine
import Network

struct DisplayItem: Identifiable, Equatable {
    var thread: NotificationThread
    var hiddenReason: String?
    var id: Int { thread.id }
}

/// Polls Forgejo, applies the filters, and handles reading/opening notifications.
@MainActor
final class NotificationStore: ObservableObject {
    @Published private(set) var threads: [NotificationThread] = []
    @Published private(set) var shown: [DisplayItem] = []
    @Published private(set) var hidden: [DisplayItem] = []
    @Published private(set) var error: ForgejoError?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isEnriching = false
    @Published private(set) var lastFetched: Date?
    @Published private(set) var user: ForgejoUser?
    @Published private(set) var credentialSource: String?
    @Published private(set) var serverURL: URL?
    @Published private(set) var now = Date()

    let credentials = CredentialProvider()
    private var enrichments: [Int: CachedEnrichment] = [:]
    private var userFor: URL?
    private var pollTimer: Timer?
    private var clockTimer: Timer?
    private var pollInterval: TimeInterval = 0
    private var wakeObserver: NSObjectProtocol?
    private let pathMonitor = NWPathMonitor()
    private var wasOnline = true
    private var filters = Prefs.filters
    private var announced: Set<Int> = []
    private var hasLoadedOnce = false
    /// Thread id → the thread's server `updatedAt` when we marked it read. Hides it until the
    /// server agrees, unless it gets newer activity.
    private var pendingReads: [Int: Date] = [:]
    /// Bumped when the account changes so in-flight results for the old one are dropped.
    private var generation = 0
    private var refreshQueued = false

    private struct CachedEnrichment: Codable {
        var updatedAt: Date
        var hasComment: Bool
        var hasReviewers: Bool
        var value: Enrichment
    }

    init() {
        enrichments = Self.loadCache()
    }

    /// Unread notifications that pass the filters: the badge number.
    var badgeCount: Int { shown.filter(\.thread.unread).count }

    // MARK: - Lifecycle

    func start() {
        reschedulePolling()
        let clock = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.now = Date() }
        }
        clock.tolerance = 5
        RunLoop.main.add(clock, forMode: .common)
        clockTimer = clock

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    Task { await self?.refresh() }
                }
            }
        }
        // Refresh as soon as the network comes back instead of waiting for the next poll.
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    defer { self.wasOnline = online }
                    if online, !self.wasOnline || self.error != nil {
                        Task { await self.refresh() }
                    }
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "forgejo-notify.path"))

        Task { await refresh() }
    }

    /// The last good fetch is old enough that the list shouldn't be trusted at a glance.
    var isStale: Bool {
        guard let lastFetched else { return false }
        return now.timeIntervalSince(lastFetched) > max(Prefs.refreshInterval * 3, 5 * 60)
    }

    func preferencesChanged() {
        if Prefs.refreshInterval != pollInterval { reschedulePolling() }
        let latest = Prefs.filters
        if latest != filters {
            filters = latest
            Task { await applyFilters(fetchDetails: true) }
        }
    }

    /// Account settings changed: drop the cached credential and start over.
    func accountChanged() {
        generation += 1
        threads = []
        shown = []
        hidden = []
        user = nil
        userFor = nil
        announced = []
        hasLoadedOnce = false
        pendingReads = [:]
        enrichments = [:]   // keyed by thread id, which means nothing on another server
        lastFetched = nil
        error = nil
        saveCache()
        Task {
            await credentials.reset()
            await refresh(userInitiated: true)
        }
    }

    private func reschedulePolling() {
        pollTimer?.invalidate()
        pollInterval = Prefs.refreshInterval
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.refresh() }
            }
        }
        timer.tolerance = pollInterval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    var shouldRefreshOnOpen: Bool {
        guard let lastFetched else { return true }
        return Date().timeIntervalSince(lastFetched) > 20
    }

    // MARK: - Fetching

    /// `readOnly` skips anything that changes server state or posts banners (used by --print).
    func refresh(userInitiated: Bool = false, readOnly: Bool = false) async {
        guard !isRefreshing else {
            if userInitiated { refreshQueued = true }
            return
        }
        isRefreshing = true
        let started = generation
        defer {
            isRefreshing = false
            now = Date()
            if refreshQueued {
                refreshQueued = false
                Task { await refresh(userInitiated: true, readOnly: readOnly) }
            }
        }
        do {
            let fetched = try await withAPI { try await $0.notifications() }
            guard started == generation else { return }
            // Keep optimistic reads hidden until the server catches up.
            threads = fetched.filter { thread in
                guard thread.unread, let readAt = pendingReads[thread.id] else { return true }
                return thread.updatedAt > readAt
            }
            let stillUnread = Set(fetched.filter(\.unread).map(\.id))
            pendingReads = pendingReads.filter { stillUnread.contains($0.key) }
            lastFetched = Date()
            error = nil
            await loadUserIfNeeded()
            await applyFilters(fetchDetails: true)
            guard started == generation else { return }
            if !readOnly {
                await autoReadFiltered()
                announceNew()
            }
            hasLoadedOnce = true
        } catch is CancellationError {
            return
        } catch let failure as ForgejoError {
            guard started == generation else { return }
            Debug.log("refresh failed: \(failure)")
            error = failure
        } catch {
            guard started == generation else { return }
            self.error = .network(error.localizedDescription)
        }
    }

    /// Runs a call with the current credential, renewing it once on a 401.
    private func withAPI<T>(_ call: (ForgejoAPI) async throws -> T) async throws -> T {
        let credential = try await credentials.current()
        credentialSource = credential.source
        serverURL = credential.baseURL
        do {
            return try await call(ForgejoAPI(credential: credential))
        } catch ForgejoError.unauthorized(let detail) {
            guard let renewed = try await credentials.renew(after: credential) else {
                throw ForgejoError.unauthorized(detail)
            }
            credentialSource = renewed.source
            return try await call(ForgejoAPI(credential: renewed))
        }
    }

    private func loadUserIfNeeded() async {
        guard let serverURL, userFor != serverURL || user == nil else { return }
        if let me = try? await withAPI({ try await $0.currentUser() }) {
            user = me
            userFor = serverURL
        }
    }

    private func applyFilters(fetchDetails: Bool) async {
        let filters = self.filters
        if fetchDetails {
            let needed = threads.filter { thread in
                guard filters.needsEnrichment(thread) else { return false }
                guard let cached = enrichments[thread.id] else { return true }
                return cached.updatedAt < thread.updatedAt
                    || (filters.needsComment && !cached.hasComment)
                    || (filters.onlyInvolved && !cached.hasReviewers)
            }
            if !needed.isEmpty { await enrich(needed, filters: filters) }
        }

        var shown: [DisplayItem] = [], hidden: [DisplayItem] = []
        let me = user?.login
        for thread in threads {
            let reason = filters.hiddenReason(thread, enrichment: enrichments[thread.id]?.value, me: me)
            let item = DisplayItem(thread: thread, hiddenReason: reason)
            if reason == nil { shown.append(item) } else { hidden.append(item) }
        }
        shown.sort { ($0.thread.pinned ? 1 : 0, $0.thread.updatedAt) > ($1.thread.pinned ? 1 : 0, $1.thread.updatedAt) }
        hidden.sort { $0.thread.updatedAt > $1.thread.updatedAt }
        self.shown = shown
        self.hidden = hidden
    }

    private func enrich(_ needed: [NotificationThread], filters: FilterSettings) async {
        guard let credential = try? await credentials.current() else { return }
        let started = generation
        isEnriching = true
        defer { isEnriching = false }
        let api = ForgejoAPI(credential: credential)
        let includeComment = filters.needsComment
        let includeReviewers = filters.onlyInvolved

        var results: [(Int, CachedEnrichment)] = []
        await withTaskGroup(of: (Int, CachedEnrichment)?.self) { group in
            var iterator = needed.makeIterator()
            func addNext() {
                guard let thread = iterator.next() else { return }
                group.addTask {
                    guard let value = try? await api.enrichment(for: thread, includeComment: includeComment,
                                                                includeReviewers: includeReviewers) else { return nil }
                    return (thread.id, CachedEnrichment(updatedAt: thread.updatedAt, hasComment: includeComment,
                                                        hasReviewers: includeReviewers, value: value))
                }
            }
            for _ in 0..<6 { addNext() }
            while let result = await group.next() {
                if let result { results.append(result) }
                addNext()
            }
        }
        guard started == generation else { return }
        for (id, value) in results { enrichments[id] = value }
        let live = Set(threads.map(\.id))
        enrichments = enrichments.filter { live.contains($0.key) }
        saveCache()
    }

    private func autoReadFiltered() async {
        guard Prefs.autoReadFiltered else { return }
        let targets = hidden.filter { $0.thread.unread && !$0.thread.pinned }.map(\.thread)
        guard !targets.isEmpty else { return }
        Debug.log("auto-reading \(targets.count) filtered notifications")
        await markRead(targets)
    }

    private func announceNew() {
        let current = Set(shown.filter(\.thread.unread).map(\.id))
        defer { announced = current }
        guard hasLoadedOnce, Prefs.systemNotifications else { return }
        let fresh = shown.filter { $0.thread.unread && !announced.contains($0.id) }.map(\.thread)
        SystemNotifier.post(fresh)
    }

    // MARK: - Actions

    func open(_ thread: NotificationThread) {
        if let url = thread.webURL { NSWorkspace.shared.open(url) }
        if Prefs.markReadOnOpen, thread.unread {
            Task { await markRead([thread]) }
        }
    }

    func open(threadID: Int) {
        if let thread = threads.first(where: { $0.id == threadID }) { open(thread) }
    }

    func markRead(_ targets: [NotificationThread]) async {
        let ids = Set(targets.map(\.id))
        guard !ids.isEmpty else { return }
        let started = generation
        for thread in targets { pendingReads[thread.id] = thread.updatedAt }
        threads.removeAll { ids.contains($0.id) && !$0.pinned }
        for index in threads.indices where ids.contains(threads[index].id) { threads[index].unread = false }
        await applyFilters(fetchDetails: false)
        do {
            try await withAPI { api in
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for id in ids { group.addTask { try await api.markRead(threadID: id) } }
                    try await group.waitForAll()
                }
            }
        } catch {
            guard started == generation else { return }
            self.error = error as? ForgejoError ?? .network(error.localizedDescription)
            // Put them back so it doesn't look handled when it isn't.
            for id in ids { pendingReads[id] = nil }
            let present = Set(threads.map(\.id))
            threads.append(contentsOf: targets.filter { !present.contains($0.id) })
            for index in threads.indices where ids.contains(threads[index].id) {
                if let original = targets.first(where: { $0.id == threads[index].id }) { threads[index] = original }
            }
            await applyFilters(fetchDetails: false)
        }
    }

    func readAll() async {
        switch Prefs.readAllScope {
        case .everything:
            // Only clear what we've actually shown: anything newer than the latest thread we
            // fetched (in server time) stays unread.
            guard let newest = threads.map(\.updatedAt).max() else { return }
            let cutoff = newest.addingTimeInterval(1)
            let started = generation
            let previous = threads
            let ids = threads.filter(\.unread).map(\.id)
            for thread in threads where thread.unread { pendingReads[thread.id] = thread.updatedAt }
            threads = threads.filter(\.pinned).map { var t = $0; t.unread = false; return t }
            await applyFilters(fetchDetails: false)
            do {
                try await withAPI { try await $0.markAllRead(before: cutoff) }
            } catch {
                guard started == generation else { return }
                self.error = error as? ForgejoError ?? .network(error.localizedDescription)
                for id in ids { pendingReads[id] = nil }
                threads = previous
                await applyFilters(fetchDetails: false)
            }
        case .shown:
            await markRead(shown.filter(\.thread.unread).map(\.thread))
        }
    }

    // MARK: - Cache

    private static let cacheURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("ForgejoNotify", isDirectory: true)
            .appendingPathComponent("enrichment.json")
    }()

    private static func loadCache() -> [Int: CachedEnrichment] {
        guard let data = try? Data(contentsOf: cacheURL) else { return [:] }
        return (try? JSONDecoder().decode([Int: CachedEnrichment].self, from: data)) ?? [:]
    }

    private func saveCache() {
        let url = Self.cacheURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(enrichments) { try? data.write(to: url, options: .atomic) }
    }
}
