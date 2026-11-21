import AppKit
import CryptoKit
import Foundation
import Network

enum AuthMode: String, CaseIterable, Identifiable {
    case tea, oauth, token

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tea: "tea login"
        case .oauth: "OAuth"
        case .token: "Access token"
        }
    }
}

// MARK: - tea

/// A login from tea's config.yml. Read-only: the app never writes tea's config, and never
/// refreshes tea's OAuth token itself (that would rotate the refresh token out from under tea).
struct TeaLogin: Equatable, Identifiable {
    var name: String
    var url: String
    var token: String
    var user: String?
    var isDefault: Bool
    var refreshToken: String?
    var tokenExpiry: Date?

    var id: String { name }
    var isOAuth: Bool { refreshToken?.isEmpty == false }
    var isExpired: Bool { tokenExpiry.map { $0 <= Date() } ?? false }
}

enum TeaConfig {
    static var candidatePaths: [URL] {
        var paths: [URL] = []
        let env = ProcessInfo.processInfo.environment
        if let xdg = env["XDG_CONFIG_HOME"], !xdg.isEmpty {
            paths.append(URL(fileURLWithPath: xdg).appendingPathComponent("tea/config.yml"))
        }
        let home = URL(fileURLWithPath: NSHomeDirectory())
        paths.append(home.appendingPathComponent("Library/Application Support/tea/config.yml"))
        paths.append(home.appendingPathComponent(".config/tea/config.yml"))
        return paths
    }

    static var configPath: URL? {
        candidatePaths.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func logins() -> [TeaLogin] {
        guard let path = configPath, let text = try? String(contentsOf: path, encoding: .utf8) else { return [] }
        return parse(text)
    }

    /// Just enough YAML for tea's `logins:` list of flat maps.
    static func parse(_ text: String) -> [TeaLogin] {
        var logins: [TeaLogin] = []
        var current: [String: String]?
        var inLogins = false
        var itemIndent = -1

        func flush() {
            guard let fields = current, let name = fields["name"], let url = fields["url"] else { return }
            logins.append(TeaLogin(
                name: name, url: url, token: fields["token"] ?? "",
                user: fields["user"].nonEmpty,
                isDefault: fields["default"] == "true",
                refreshToken: fields["refresh_token"].nonEmpty,
                tokenExpiry: fields["token_expiry"].flatMap(Double.init).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
            ))
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let indent = rawLine.prefix { $0 == " " }.count
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if indent == 0 {
                if inLogins { flush(); current = nil }
                inLogins = line.hasPrefix("logins:")
                continue
            }
            guard inLogins else { continue }
            if line.hasPrefix("- ") {
                if itemIndent < 0 { itemIndent = indent }
                if indent == itemIndent {
                    flush()
                    current = [:]
                    line = String(line.dropFirst(2))
                }
            }
            guard current != nil, let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
            }
            current?[key] = value
        }
        if inLogins { flush() }
        return logins
    }

    /// For tea OAuth logins whose token expired: run a harmless tea command, which makes tea
    /// refresh its own token and rewrite config.yml. Best effort.
    static func nudgeRefresh(login: String) async {
        let candidates = ["/opt/homebrew/bin/tea", "/usr/local/bin/tea"]
        guard let tea = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return }
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tea)
            process.arguments = ["whoami", "--login", login]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            let deadline = Date().addingTimeInterval(15)
            while process.isRunning, Date() < deadline { usleep(100_000) }
            if process.isRunning { process.terminate() }
        }.value
    }
}

// MARK: - Keychain

/// Secrets in the login Keychain, written and read through `/usr/bin/security`. Items made by
/// that tool trust it, so reads never prompt, even after the app is rebuilt and re-signed.
/// Writes go over stdin (`security -i`) so secrets never show up in a process listing.
enum SecretStore {
    static let service = "io.github.trthomps.forgejo-notify"

    static func read(_ account: String) -> String? {
        let (status, output) = run(["find-generic-password", "-s", service, "-a", account, "-w"])
        guard status == 0 else { return nil }
        return output.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    @discardableResult
    static func write(_ account: String, _ secret: String) -> Bool {
        let hex = Data(secret.utf8).map { String(format: "%02x", $0) }.joined()
        let command = "add-generic-password -U -s \"\(service)\" -a \"\(sanitize(account))\" -X \(hex)\n"
        let (status, _) = run(["-i"], stdin: command)
        return status == 0 && read(account) == secret
    }

    static func delete(_ account: String) {
        _ = run(["delete-generic-password", "-s", service, "-a", account])
    }

    private static func sanitize(_ text: String) -> String {
        text.filter { $0 != "\"" && $0 != "\\" && !$0.isNewline }
    }

    private static func run(_ arguments: [String], stdin: String? = nil) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        let input = Pipe()
        if stdin != nil { process.standardInput = input }
        do { try process.run() } catch { return (-1, "") }
        if let stdin {
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try? input.fileHandleForWriting.close()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

// MARK: - OAuth

struct OAuthSession: Codable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var clientID: String

    var expiresSoon: Bool { expiresAt.map { $0 <= Date().addingTimeInterval(60) } ?? false }
}

/// Authorization code flow with PKCE and a loopback redirect (RFC 8252), the same way
/// git-credential-oauth signs in. Your Forgejo login page handles everything else, including
/// any external SSO provider it's set up with.
enum OAuthFlow {
    /// Forgejo ships git-credential-oauth as a built-in public OAuth2 app with a loopback
    /// redirect, so it works on most instances without registering anything.
    static let defaultClientID = "a4792ccc-144e-407e-86c9-5e7d8d9c3269"

    static func signIn(baseURL: URL, clientID: String) async throws -> OAuthSession {
        let verifier = randomString(48)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = randomString(24)

        let server = try await LoopbackServer.start()
        defer { server.stop() }
        let redirect = "http://127.0.0.1:\(server.port)"

        var components = URLComponents(url: baseURL.appendingPathComponent("login/oauth/authorize"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
        ]
        guard let authorizeURL = components.url else { throw ForgejoError.auth("Bad server URL") }
        await MainActor.run { _ = NSWorkspace.shared.open(authorizeURL) }

        let params = try await server.waitForCallback(timeout: 300)
        if let error = params["error"] {
            throw ForgejoError.auth(params["error_description"] ?? "Forgejo said: \(error)")
        }
        guard params["state"] == state else { throw ForgejoError.auth("State mismatch in the OAuth callback.") }
        guard let code = params["code"] else { throw ForgejoError.auth("No authorization code in the callback.") }

        return try await tokenRequest(baseURL: baseURL, clientID: clientID, form: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirect,
            "code_verifier": verifier,
        ])
    }

    static func refresh(_ session: OAuthSession, baseURL: URL) async throws -> OAuthSession {
        guard let refreshToken = session.refreshToken else {
            throw ForgejoError.unauthorized("The OAuth session expired. Sign in again from Settings → Account.")
        }
        var refreshed = try await tokenRequest(baseURL: baseURL, clientID: session.clientID, form: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ])
        if refreshed.refreshToken == nil { refreshed.refreshToken = refreshToken }
        return refreshed
    }

    private static func tokenRequest(baseURL: URL, clientID: String, form: [String: String]) async throws -> OAuthSession {
        var request = URLRequest(url: baseURL.appendingPathComponent("login/oauth/access_token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var fields = form
        fields["client_id"] = clientID
        var body = URLComponents()
        body.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((body.percentEncodedQuery ?? "")
            .replacingOccurrences(of: "+", with: "%2B").utf8)

        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ForgejoError.network(error.localizedDescription)
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), let access = object["access_token"] as? String else {
            let detail = (object["error_description"] as? String) ?? (object["error"] as? String) ?? "HTTP \(status)"
            if form["grant_type"] == "refresh_token" {
                throw ForgejoError.unauthorized("Couldn't renew the OAuth session (\(detail)). Sign in again from Settings → Account.")
            }
            throw ForgejoError.auth("Token exchange failed: \(detail)")
        }
        let expiresIn = (object["expires_in"] as? NSNumber)?.doubleValue
        return OAuthSession(
            accessToken: access,
            refreshToken: (object["refresh_token"] as? String).nonEmpty,
            expiresAt: expiresIn.map { Date().addingTimeInterval($0) },
            clientID: clientID
        )
    }

    private static func randomString(_ bytes: Int) -> String {
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return data.base64URL
    }
}

/// A one-shot HTTP listener on 127.0.0.1 that catches the OAuth redirect.
final class LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "forgejo-notify.oauth")
    private var continuation: CheckedContinuation<[String: String], Error>?
    /// A callback that arrived before anyone was waiting for it.
    private var earlyResult: [String: String]?
    private(set) var port: UInt16 = 0

    private init(listener: NWListener) { self.listener = listener }

    static func start() async throws -> LoopbackServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do { listener = try NWListener(using: parameters) } catch {
            throw ForgejoError.auth("Couldn't open a local port for the OAuth redirect: \(error.localizedDescription)")
        }
        let server = LoopbackServer(listener: listener)
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    server.port = listener.port?.rawValue ?? 0
                    ready.resume()
                case .failed(let error):
                    resumed = true
                    ready.resume(throwing: ForgejoError.auth("Local OAuth listener failed: \(error.localizedDescription)"))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak server] connection in server?.handle(connection) }
            listener.start(queue: server.queue)
        }
        return server
    }

    func waitForCallback(timeout: TimeInterval) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let early = self.earlyResult {
                    continuation.resume(returning: early)
                    return
                }
                self.continuation = continuation
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    self.finish(.failure(ForgejoError.auth("Timed out waiting for the browser sign-in.")))
                }
            }
        }
    }

    func stop() {
        listener.cancel()
        queue.async { self.finish(.failure(CancellationError())) }
    }

    private func finish(_ result: Result<[String: String], Error>) {
        guard let continuation else {
            if case .success(let params) = result { earlyResult = params }
            return
        }
        self.continuation = nil
        continuation.resume(with: result)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { return }
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let target = text.split(separator: "\r\n").first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let items = URLComponents(string: "http://127.0.0.1\(target)")?.queryItems ?? []
            var params: [String: String] = [:]
            for item in items { params[item.name] = item.value ?? "" }

            let isCallback = params["code"] != nil || params["error"] != nil
            let body = isCallback
                ? "<!doctype html><meta charset=utf-8><title>Forgejo Notifications</title><body style=\"font:15px -apple-system;text-align:center;padding-top:80px\"><h2>\(params["error"] == nil ? "Signed in" : "Sign-in failed")</h2><p>You can close this tab and go back to Forgejo Notifications.</p>"
                : "Not found"
            let response = "HTTP/1.1 \(isCallback ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            if isCallback { self.finish(.success(params)) }
        }
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Provider

/// Hands out a working credential for the configured auth mode, renewing it when it can.
actor CredentialProvider {
    private var cached: Credential?
    private var refreshTask: Task<Credential, Error>?
    /// Bumped by reset(); loads that started before it are discarded.
    private var epoch = 0

    static func normalizedServer(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed), url.host != nil else { return nil }
        return url
    }

    static func tokenAccount(_ server: URL) -> String { "token:\(server.absoluteString)" }
    static func oauthAccount(_ server: URL) -> String { "oauth:\(server.absoluteString)" }

    func reset() {
        epoch += 1
        cached = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    func current() async throws -> Credential {
        if let cached { return cached }
        let started = epoch
        let credential = try await load(forceRenew: false)
        guard started == epoch else { throw CancellationError() }
        cached = credential
        return credential
    }

    /// Called after a 401: re-read tea's config or refresh the OAuth session.
    /// Returns nil when nothing changed, so the caller can stop retrying.
    func renew(after failed: Credential) async throws -> Credential? {
        if let cached, cached != failed { return cached }
        if let refreshTask { return try await refreshTask.value }
        let started = epoch
        let task = Task { try await self.load(forceRenew: true) }
        refreshTask = task
        defer { if started == epoch { refreshTask = nil } }
        let renewed = try await task.value
        guard started == epoch else { throw CancellationError() }
        cached = renewed
        return renewed.token == failed.token ? nil : renewed
    }

    private func load(forceRenew: Bool) async throws -> Credential {
        let mode = await MainActor.run { Prefs.authMode }
        switch mode {
        case .tea:
            let name = await MainActor.run { Prefs.teaLogin }
            let logins = TeaConfig.logins()
            guard let login = logins.first(where: { $0.name == name })
                    ?? logins.first(where: \.isDefault) ?? logins.first else {
                throw ForgejoError.notConfigured
            }
            if login.isOAuth, forceRenew || login.isExpired {
                await TeaConfig.nudgeRefresh(login: login.name)
                if let reloaded = TeaConfig.logins().first(where: { $0.name == login.name }) {
                    return try teaCredential(reloaded)
                }
            }
            return try teaCredential(login)

        case .token:
            let server = await MainActor.run { Prefs.serverURL }
            guard let base = Self.normalizedServer(server),
                  let token = SecretStore.read(Self.tokenAccount(base)) else { throw ForgejoError.notConfigured }
            return Credential(baseURL: base, token: token, isOAuth: false, source: "Access token")

        case .oauth:
            let server = await MainActor.run { Prefs.serverURL }
            guard let base = Self.normalizedServer(server),
                  let stored = SecretStore.read(Self.oauthAccount(base)),
                  var session = try? JSONDecoder().decode(OAuthSession.self, from: Data(stored.utf8))
            else { throw ForgejoError.notConfigured }
            if forceRenew || session.expiresSoon {
                session = try await OAuthFlow.refresh(session, baseURL: base)
                Self.save(session, for: base)
            }
            return Credential(baseURL: base, token: session.accessToken, isOAuth: true, source: "OAuth")
        }
    }

    private func teaCredential(_ login: TeaLogin) throws -> Credential {
        guard let base = Self.normalizedServer(login.url), !login.token.isEmpty else { throw ForgejoError.notConfigured }
        return Credential(baseURL: base, token: login.token, isOAuth: login.isOAuth, source: "tea · \(login.name)")
    }

    static func save(_ session: OAuthSession, for base: URL) {
        if let data = try? JSONEncoder().encode(session), let text = String(data: data, encoding: .utf8) {
            SecretStore.write(oauthAccount(base), text)
        }
    }
}
