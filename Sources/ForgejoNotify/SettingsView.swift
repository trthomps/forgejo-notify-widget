import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let store: NotificationStore
    private var window: NSWindow?

    init(store: NotificationStore) {
        self.store = store
    }

    func show(tab: SettingsTab? = nil) {
        if let tab { SettingsTab.requested = tab }
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(store: store))
            host.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: host)
            window.title = "Forgejo Notifications Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

enum SettingsTab: String, Hashable {
    case general, account, filters
    @MainActor static var requested: SettingsTab?
}

struct SettingsView: View {
    @ObservedObject var store: NotificationStore
    @State private var tab: SettingsTab = .general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings(store: store)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            AccountSettings(store: store)
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
                .tag(SettingsTab.account)
            FilterSettingsView(store: store)
                .tabItem { Label("Filters", systemImage: "line.3.horizontal.decrease.circle") }
                .tag(SettingsTab.filters)
        }
        .frame(width: 520, height: 640)
        .onAppear {
            if let requested = SettingsTab.requested {
                tab = requested
                SettingsTab.requested = nil
            } else if store.error == .notConfigured {
                tab = .account
            }
        }
    }
}

private func note(_ text: String) -> some View {
    Text(text)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
}

// MARK: - General

private struct GeneralSettings: View {
    @ObservedObject var store: NotificationStore
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(PrefKey.iconColor) private var iconColor: IconColor = .color
    @AppStorage(PrefKey.badgeStyle) private var badgeStyle: BadgeStyle = .badge
    @AppStorage(PrefKey.hideWhenEmpty) private var dimWhenEmpty = true
    @AppStorage(PrefKey.refreshInterval) private var refreshInterval: Double = 60
    @AppStorage(PrefKey.markReadOnOpen) private var markReadOnOpen = true
    @AppStorage(PrefKey.systemNotifications) private var systemNotifications = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Menu bar icon") {
                HStack(spacing: 10) {
                    ForEach(IconColor.allCases) { candidate in
                        tile(candidate.title, selected: candidate == iconColor,
                             image: preview(color: candidate, badge: badgeStyle))
                            .onTapGesture { iconColor = candidate }
                    }
                }
                .padding(.vertical, 4)
                Picker("Unread count", selection: $badgeStyle) {
                    ForEach(BadgeStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Dim the icon when there's nothing unread", isOn: $dimWhenEmpty)
            }

            Section("Behavior") {
                Toggle("Mark as read when I open a notification", isOn: $markReadOnOpen)
                Toggle("Show a macOS notification for new items", isOn: $systemNotifications)
                    .disabled(!SystemNotifier.available)
                    .onChange(of: systemNotifications) { _, enabled in
                        guard enabled else { return }
                        Task {
                            if !(await SystemNotifier.requestAuthorization()) { systemNotifications = false }
                        }
                    }
                if !SystemNotifier.available {
                    note("macOS notifications need the app bundle (make app), not swift run.")
                } else {
                    note("Only notifications that pass your filters. Clicking a banner opens it.")
                }
                Picker("Refresh every", selection: $refreshInterval) {
                    Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0)
                    Text("2 minutes").tag(120.0)
                    Text("5 minutes").tag(300.0)
                    Text("15 minutes").tag(900.0)
                }
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let loginError {
                    note(loginError).foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func preview(color: IconColor, badge: BadgeStyle) -> NSImage {
        let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)!
        let model = MenuBarModel(state: .ok, count: max(store.badgeCount, 7), color: color, badge: badge)
        return MenuBarRenderer.image(for: model, appearance: appearance)
    }

    private func tile(_ title: String, selected: Bool, image: NSImage) -> some View {
        VStack(spacing: 6) {
            Image(nsImage: image)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(colorScheme == .dark ? Color(white: 0.13) : Color(white: 0.95)))
            Text(title).font(.system(size: 11, weight: selected ? .semibold : .regular))
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 9)
            .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 2 : 1))
        .contentShape(Rectangle())
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Couldn't change login item: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: - Account

private struct AccountSettings: View {
    @ObservedObject var store: NotificationStore
    @AppStorage(PrefKey.authMode) private var authMode: AuthMode = .tea
    @AppStorage(PrefKey.teaLogin) private var teaLogin = ""
    @AppStorage(PrefKey.serverURL) private var serverURL = ""
    @AppStorage(PrefKey.oauthClientID) private var clientID = OAuthFlow.defaultClientID
    @State private var teaLogins = TeaConfig.logins()
    @State private var tokenDraft = ""
    @State private var busy = false
    @State private var message: String?
    @State private var hasOAuth = false
    @State private var hasToken = false

    var body: some View {
        Form {
            Section {
                Picker("Sign in with", selection: $authMode) {
                    ForEach(AuthMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: authMode) { _, _ in changed() }
            }

            switch authMode {
            case .tea: teaSection
            case .oauth: oauthSection
            case .token: tokenSection
            }

            Section("Status") {
                if let user = store.user, store.error == nil {
                    LabeledContent("Signed in as", value: "@\(user.login)")
                } else if let error = store.error {
                    LabeledContent("Status", value: error.title)
                    note(error.message)
                } else {
                    LabeledContent("Status", value: store.lastFetched == nil ? "Connecting…" : "Connected")
                }
                if let server = store.serverURL { LabeledContent("Server", value: server.absoluteString) }
                if let source = store.credentialSource { LabeledContent("Using", value: source) }
                if let message { note(message) }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reloadState)
    }

    private var teaSection: some View {
        Section {
            if teaLogins.isEmpty {
                note("No tea logins found. Run `tea login add` (or `tea login add --oauth`) in a terminal, then click Reload.")
            } else {
                Picker("Login", selection: $teaLogin) {
                    Text("Default").tag("")
                    ForEach(teaLogins) { login in
                        Text("\(login.name) — \(login.user.map { "@\($0) · " } ?? "")\(login.url)").tag(login.name)
                    }
                }
                .onChange(of: teaLogin) { _, _ in changed() }
            }
            HStack {
                Button("Reload tea config") {
                    teaLogins = TeaConfig.logins()
                    changed()
                }
                Spacer()
            }
            note("Reads tea's config at \(TeaConfig.configPath?.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") ?? "~/Library/Application Support/tea/config.yml") (read-only). For OAuth logins made with `tea login add --oauth`, tea keeps the token fresh; this app re-reads it when it expires.")
        } header: {
            Text("tea")
        }
    }

    private var oauthSection: some View {
        Section {
            TextField("Server", text: $serverURL, prompt: Text(teaLogins.first?.url ?? "https://forgejo.example.com"))
            TextField("Client ID", text: $clientID)
                .font(.system(.body, design: .monospaced))
            HStack {
                if hasOAuth {
                    Label("Signed in", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    Spacer()
                    Button("Sign Out", role: .destructive, action: signOutOAuth)
                    Button("Sign In Again", action: signInOAuth).disabled(busy)
                } else {
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    Button("Sign In with Browser…", action: signInOAuth)
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy || CredentialProvider.normalizedServer(serverURL) == nil)
                }
            }
            note("Opens your Forgejo login page in the browser (SSO and 2FA work as usual) and catches the redirect on 127.0.0.1. The default client ID is Forgejo's built-in git-credential-oauth app. To use your own, create an OAuth2 app under Settings → Applications with “Confidential client” unchecked and redirect URI http://127.0.0.1. Tokens are kept in your Keychain and refreshed automatically.")
        } header: {
            Text("OAuth")
        }
    }

    private var tokenSection: some View {
        Section {
            TextField("Server", text: $serverURL, prompt: Text(teaLogins.first?.url ?? "https://forgejo.example.com"))
            SecureField("Token", text: $tokenDraft, prompt: Text(hasToken ? "•••••••• (saved)" : "Paste an access token"))
            HStack {
                if hasToken {
                    Button("Remove Token", role: .destructive, action: removeToken)
                }
                Spacer()
                Button("Save", action: saveToken)
                    .keyboardShortcut(.defaultAction)
                    .disabled(tokenDraft.isEmpty || CredentialProvider.normalizedServer(serverURL) == nil)
            }
            note("Create one under Settings → Applications → Access tokens with read:notification, write:notification, read:issue, read:repository and read:user. Stored in your Keychain.")
        } header: {
            Text("Access token")
        }
    }

    private func reloadState() {
        teaLogins = TeaConfig.logins()
        if serverURL.isEmpty, let first = teaLogins.first(where: \.isDefault) ?? teaLogins.first {
            serverURL = first.url
        }
        guard let base = CredentialProvider.normalizedServer(serverURL) else {
            hasOAuth = false
            hasToken = false
            return
        }
        hasOAuth = SecretStore.read(CredentialProvider.oauthAccount(base)) != nil
        hasToken = SecretStore.read(CredentialProvider.tokenAccount(base)) != nil
    }

    private func changed() {
        message = nil
        reloadState()
        store.accountChanged()
    }

    private func signInOAuth() {
        guard let base = CredentialProvider.normalizedServer(serverURL) else { return }
        busy = true
        message = "Waiting for you to finish signing in in the browser…"
        let client = clientID.trimmingCharacters(in: .whitespaces).nonEmpty ?? OAuthFlow.defaultClientID
        Task {
            defer { busy = false }
            do {
                let session = try await OAuthFlow.signIn(baseURL: base, clientID: client)
                CredentialProvider.save(session, for: base)
                serverURL = base.absoluteString
                changed()
                message = "Signed in."
                NSApp.activate()
            } catch let error as ForgejoError {
                message = error.message
            } catch is CancellationError {
                message = nil
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func signOutOAuth() {
        guard let base = CredentialProvider.normalizedServer(serverURL) else { return }
        SecretStore.delete(CredentialProvider.oauthAccount(base))
        changed()
    }

    private func saveToken() {
        guard let base = CredentialProvider.normalizedServer(serverURL) else { return }
        let token = tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if SecretStore.write(CredentialProvider.tokenAccount(base), token) {
            tokenDraft = ""
            serverURL = base.absoluteString
            changed()
        } else {
            message = "Couldn't save the token to the Keychain."
        }
    }

    private func removeToken() {
        guard let base = CredentialProvider.normalizedServer(serverURL) else { return }
        SecretStore.delete(CredentialProvider.tokenAccount(base))
        changed()
    }
}

// MARK: - Filters

private struct FilterSettingsView: View {
    @ObservedObject var store: NotificationStore
    @AppStorage(PrefKey.types) private var typesRaw = Prefs.allTypes
    @AppStorage(PrefKey.hideClosed) private var hideClosed = false
    @AppStorage(PrefKey.hideMerged) private var hideMerged = false
    @AppStorage(PrefKey.hideDrafts) private var hideDrafts = false
    @AppStorage(PrefKey.onlyInvolved) private var onlyInvolved = false
    @AppStorage(PrefKey.includeRepos) private var includeRepos = ""
    @AppStorage(PrefKey.excludeRepos) private var excludeRepos = ""
    @AppStorage(PrefKey.excludeAuthors) private var excludeAuthors = ""
    @AppStorage(PrefKey.excludeCommenters) private var excludeCommenters = ""
    @AppStorage(PrefKey.excludeLabels) private var excludeLabels = ""
    @AppStorage(PrefKey.excludeTitles) private var excludeTitles = ""
    @AppStorage(PrefKey.autoReadFiltered) private var autoRead = false
    @AppStorage(PrefKey.readAllScope) private var readAllScope: ReadAllScope = .everything

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("\(store.shown.count) shown · \(store.hidden.count) hidden")
                        .monospacedDigit()
                    if store.isEnriching {
                        ProgressView().controlSize(.small)
                        Text("checking…").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Reset Filters", action: reset)
                }
                if !topReasons.isEmpty {
                    note("Hidden because: " + topReasons.map { "\($0.0) (\($0.1))" }.joined(separator: ", "))
                }
            }

            Section("Kinds") {
                ForEach(SubjectType.allCases.filter { $0 != .other }) { type in
                    Toggle(type.title, isOn: typeBinding(type))
                }
                Toggle("Hide closed", isOn: $hideClosed)
                Toggle("Hide merged pull requests", isOn: $hideMerged)
                Toggle("Hide draft pull requests", isOn: $hideDrafts)
            }

            Section {
                Toggle(isOn: $onlyInvolved) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Only things I'm involved in")
                        note("You opened it, are assigned, are a requested reviewer, or are @mentioned in the latest comment. Watching a repo alone doesn't count.")
                    }
                }
            } header: {
                Text("Involvement")
            }

            Section {
                field("Only these repos", text: $includeRepos, prompt: "everything")
                field("Hide repos", text: $excludeRepos, prompt: "owner/repo, mirrors/*")
                if !repoCounts.isEmpty {
                    HStack(spacing: 6) {
                        Text("In your inbox:").font(.caption).foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(repoCounts, id: \.0) { repo, count in
                                    Button("\(repo) (\(count))") { append(repo, to: &excludeRepos) }
                                        .controlSize(.small)
                                        .help("Hide \(repo)")
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("Repositories")
            }

            Section {
                field("Hide authors", text: $excludeAuthors, prompt: "renovate, *bot")
                field("Hide when last comment is by", text: $excludeCommenters, prompt: "agent-*, ci")
                field("Hide labels", text: $excludeLabels, prompt: "dependencies, renovate")
                field("Hide titles containing", text: $excludeTitles, prompt: "Update dependency, chore(deps)")
                note("Comma-separated, case-insensitive. * matches anything. Filtering by author, label or comment looks up each notification's issue or PR once (cached).")
            } header: {
                Text("People, labels and titles")
            }

            Section("Clearing") {
                Picker("Read all marks", selection: $readAllScope) {
                    ForEach(ReadAllScope.allCases) { Text($0.title).tag($0) }
                }
                Toggle(isOn: $autoRead) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Automatically mark filtered-out notifications as read")
                        note("Keeps your Forgejo inbox in sync with this list. Changes the read state on the server.")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func field(_ title: String, text: Binding<String>, prompt: String) -> some View {
        TextField(title, text: text, prompt: Text(prompt))
    }

    private var topReasons: [(String, Int)] {
        let counts = Dictionary(grouping: store.hidden.compactMap(\.hiddenReason), by: { $0 }).mapValues(\.count)
        return counts.sorted { $0.value > $1.value }.prefix(4).map { ($0.key, $0.value) }
    }

    private var repoCounts: [(String, Int)] {
        let counts = Dictionary(grouping: store.threads.map(\.repository.fullName), by: { $0 }).mapValues(\.count)
        let excluded = Prefs.patterns(PrefKey.excludeRepos)
        return counts.filter { !Glob.any(excluded, matches: $0.key) }
            .sorted { $0.value > $1.value }.prefix(6).map { ($0.key, $0.value) }
    }

    private func append(_ value: String, to text: inout String) {
        let existing = text.trimmingCharacters(in: .whitespaces)
        text = existing.isEmpty ? value : "\(existing), \(value)"
    }

    private var selectedTypes: Set<String> { Set(typesRaw.split(separator: ",").map(String.init)) }

    private func typeBinding(_ type: SubjectType) -> Binding<Bool> {
        Binding(
            get: { selectedTypes.contains(type.rawValue) },
            set: { enabled in
                var set = selectedTypes
                if enabled { set.insert(type.rawValue) } else { set.remove(type.rawValue) }
                typesRaw = SubjectType.allCases.map(\.rawValue).filter(set.contains).joined(separator: ",")
            }
        )
    }

    private func reset() {
        typesRaw = Prefs.allTypes
        hideClosed = false; hideMerged = false; hideDrafts = false; onlyInvolved = false
        includeRepos = ""; excludeRepos = ""; excludeAuthors = ""; excludeCommenters = ""
        excludeLabels = ""; excludeTitles = ""
    }
}
