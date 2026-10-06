import Foundation
import Network
import Observation
import Security
import ImageCratCore

// Local MCP server (docs/MCP.md): lets Claude Code and other MCP clients drive the running app over Streamable HTTP
// on 127.0.0.1. Off by default; Preferences ▸ Integrations turns it on. The protocol (JSON-RPC, versions, sessions,
// auth checks) is `MCPEndpoint` in the core; this file is the loopback listener (Network.framework), the settings,
// the bearer token in the Keychain and the status the Preferences pane and the status-bar chip show.

/// Preferences ▸ Integrations ▸ Claude Code / MCP.
struct MCPSettingsData: Codable, Equatable {
    var enabled = false
    var port = MCPServerController.defaultPort
    /// MCP may start paid generative AI jobs (fal.ai and the other providers). Off: those tools are refused.
    var allowPaidGenerative = false
    /// "Don't ask again for MCP": paid jobs started by MCP skip the cost confirmation.
    var skipPaidConfirmation = false

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        port = (try? c.decodeIfPresent(Int.self, forKey: .port)) ?? MCPServerController.defaultPort
        allowPaidGenerative = (try? c.decodeIfPresent(Bool.self, forKey: .allowPaidGenerative)) ?? false
        skipPaidConfirmation = (try? c.decodeIfPresent(Bool.self, forKey: .skipPaidConfirmation)) ?? false
    }
}

@Observable
final class MCPServerController {
    static let shared = MCPServerController()
    static let defaultPort = 47800
    static let defaultsKey = "ImageCrat.MCP"
    /// The token's Keychain item (its own service: never the generative AI keys').
    static let keychainService = Brand.bundleIdentifier + ".mcp"
    static let tokenAccount = "mcp-bearer-token"
    /// How many ports after the preferred one are tried before an ephemeral port.
    static let portAttempts = 10
    static let maxConnections = 32

    /// Self tests and other automated runs: settings stay in memory and the token is never read from or written to
    /// the Keychain (`GenAIKeyOverrides.realKeysBlocked`).
    let ephemeral: Bool

    var settings: MCPSettingsData {
        didSet {
            guard settings != oldValue else { return }
            saveSettings()
            if settings.enabled != oldValue.enabled || (settings.enabled && settings.port != oldValue.port) { apply() }
        }
    }

    // Status (main thread)
    private(set) var running = false
    private(set) var starting = false
    private(set) var listeningPort: Int?
    private(set) var statusError: String?
    private(set) var lastCall: String?
    private(set) var lastWrittenFile: String?
    private(set) var callCount = 0
    /// Bumped on every request (the status line re-reads the client count).
    private(set) var activity = 0
    /// The token exists (it is read from the Keychain only when the server starts or the user copies it).
    private(set) var hasToken = false

    @ObservationIgnored private var token: String?
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var endpoint: MCPEndpoint?
    @ObservationIgnored private let queue = DispatchQueue(label: "app.imagecrat.mcp.server")
    /// Live connections (touched on `queue` only).
    @ObservationIgnored private var connections: [ObjectIdentifier: MCPConnection] = [:]
    @ObservationIgnored private var generation = 0

    private init() {
        ephemeral = GenAIKeyOverrides.realKeysBlocked
        if !ephemeral, let d = UserDefaults.standard.data(forKey: MCPServerController.defaultsKey),
           let s = try? JSONDecoder().decode(MCPSettingsData.self, from: d) {
            settings = s
        } else {
            settings = MCPSettingsData()
        }
    }

    private func saveSettings() {
        guard !ephemeral, let d = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(d, forKey: MCPServerController.defaultsKey)
    }

    /// Launch: start the server if the user left it on (never in automated runs: tests start it explicitly).
    func startAtLaunchIfEnabled() {
        guard !ephemeral, settings.enabled else { return }
        apply()
    }

    // MARK: Token

    private var keychain: GenAIKeychain { GenAIKeychain(service: MCPServerController.keychainService) }

    /// Self tests: use `t` as the token (memory only). Ignored outside automated runs.
    func useTestToken(_ t: String) {
        guard ephemeral else { return }
        token = t
        hasToken = true
        endpoint?.token = t
    }

    /// Reads (or creates) the token off the main thread — a Keychain read may wait for an access prompt.
    private func loadToken(_ done: @escaping (String) -> Void) {
        if let t = token { return done(t) }
        if ephemeral {
            let t = MCPEndpoint.newToken()
            token = t; hasToken = true
            return done(t)
        }
        let kc = keychain
        DispatchQueue.global(qos: .userInitiated).async {
            var t = kc.get(MCPServerController.tokenAccount)
            if t == nil || t!.count < 32 {
                let fresh = MCPEndpoint.newToken()
                kc.set(fresh, for: MCPServerController.tokenAccount)
                t = fresh
            }
            DispatchQueue.main.async {
                self.token = t
                self.hasToken = true
                done(t!)
            }
        }
    }

    /// The token for Copy / the setup command (loads it first if needed).
    func withToken(_ body: @escaping (String) -> Void) { loadToken(body) }

    /// A new token: clients configured with the old one get 401 until they are set up again.
    func regenerateToken() {
        let t = MCPEndpoint.newToken()
        token = t
        hasToken = true
        endpoint?.token = t
        if !ephemeral {
            let kc = keychain
            DispatchQueue.global(qos: .userInitiated).async { kc.set(t, for: MCPServerController.tokenAccount) }
        }
        DiagLog.shared.info("MCP: token regenerated")
    }

    /// The port clients should use: the one the server listens on, else the configured one.
    var effectivePort: Int { listeningPort ?? (settings.port == 0 ? MCPServerController.defaultPort : settings.port) }

    func setupCommand(token: String) -> String { MCPEndpoint.claudeSetupCommand(port: effectivePort, token: token) }

    // MARK: Start / stop

    private func apply() {
        if settings.enabled { start() } else { stop() }
    }

    private func start() {
        stop()
        generation += 1
        let gen = generation
        starting = true
        statusError = nil
        loadToken { [weak self] token in
            guard let self, self.generation == gen, self.settings.enabled else { return }
            let ep = self.endpoint ?? self.makeEndpoint(token: token)
            ep.token = token
            ep.tools = MCPTools.descriptors
            self.endpoint = ep
            let first = self.settings.port
            var ports = first == 0 ? [] : (0..<MCPServerController.portAttempts).map { first + $0 }.filter { $0 > 0 && $0 < 65536 }
            ports.append(0)   // then any free port
            self.listen(ports, gen: gen)
        }
    }

    private func makeEndpoint(token: String) -> MCPEndpoint {
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
        let ep = MCPEndpoint(token: token, info: .init(name: "imagecrat", title: Brand.name, version: version, instructions: MCPTools.instructions))
        ep.executor = { call, done in
            DispatchQueue.main.async { MCPToolRunner.shared.enqueue(call, done) }
        }
        ep.onEvent = { [weak self] e in
            DispatchQueue.main.async { self?.note(e) }
        }
        return ep
    }

    private func listen(_ ports: [Int], gen: Int) {
        guard let port = ports.first else { return }
        let rest = Array(ports.dropFirst())
        let params = NWParameters.tcp
        params.acceptLocalOnly = true
        params.allowLocalEndpointReuse = false   // never share the port with another listener
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port == 0 ? .any : NWEndpoint.Port(rawValue: UInt16(port))!)
        let l: NWListener
        do { l = try NWListener(using: params) } catch {
            if !rest.isEmpty { return listen(rest, gen: gen) }
            return failed(tr("Could not start the MCP server: \(error.localizedDescription)"), gen: gen)
        }
        listener = l
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { [weak self, weak l] state in
            DispatchQueue.main.async {
                guard let self, let l, self.generation == gen, self.listener === l else { return }
                switch state {
                case .ready:
                    self.starting = false
                    self.running = true
                    self.listeningPort = l.port.map { Int($0.rawValue) }
                    let p = self.listeningPort ?? port
                    DiagLog.shared.info("MCP: listening on 127.0.0.1:\(p)")
                    if port != self.settings.port && self.settings.port != 0 {
                        self.statusError = tr("Port \(String(self.settings.port)) is in use: using \(String(p)) instead.")
                    }
                case .failed(let e), .waiting(let e):
                    l.cancel()
                    self.listener = nil
                    if !rest.isEmpty { self.listen(rest, gen: gen) } else { self.failed(tr("Could not start the MCP server: \(e.localizedDescription)"), gen: gen) }
                case .cancelled:
                    break
                default:
                    break
                }
            }
        }
        l.start(queue: queue)
    }

    private func failed(_ message: String, gen: Int) {
        guard generation == gen else { return }
        starting = false
        running = false
        listeningPort = nil
        statusError = message
        DiagLog.shared.warning("MCP: " + message)
    }

    func stop() {
        generation += 1
        if let l = listener { l.stateUpdateHandler = nil; l.newConnectionHandler = nil; l.cancel() }
        listener = nil
        queue.async {
            for c in self.connections.values { c.cancel() }
            self.connections.removeAll()
        }
        if running { DiagLog.shared.info("MCP: stopped") }
        running = false
        starting = false
        listeningPort = nil
    }

    private func accept(_ nw: NWConnection) {   // on `queue`
        guard connections.count < MCPServerController.maxConnections, let ep = endpoint else { nw.cancel(); return }
        let c = MCPConnection(nw, endpoint: ep, queue: queue)
        let key = ObjectIdentifier(c)
        connections[key] = c
        c.onClose = { [weak self] in self?.connections.removeValue(forKey: key) }
        c.start()
    }

    // MARK: Status

    private func note(_ e: MCPEndpoint.Event) {
        activity &+= 1
        switch e {
        case .toolCall(let name, let client):
            lastCall = name
            callCount += 1
            DiagLog.shared.info("MCP: \(client) called \(name)")
        case .sessionOpened(let client, let version):
            DiagLog.shared.info("MCP: \(client) connected (protocol \(version))")
        case .rejected(let status, let reason):
            DiagLog.shared.warning("MCP: rejected a request (\(status)): \(reason)")
        case .sessionClosed, .request:
            break
        }
    }

    /// Clients seen in the last 10 minutes.
    func activeClients() -> Int { running ? (endpoint?.activeClients() ?? 0) : 0 }

    /// A tool wrote a file: status line, status bar and the diagnostic log name it.
    func noteWrote(_ url: URL) {
        lastWrittenFile = url.path
        DiagLog.shared.info("MCP: wrote \(url.path)")
        AppModel.shared.setStatus("MCP wrote \(url.path)")   // (English: shown through tr() by the status bar)
    }

    /// "Listening on 127.0.0.1:47800 · 1 client connected · last call: apply_filter".
    func statusLine(clients: Int) -> String {
        if starting { return tr("Starting…") }
        guard running, let p = listeningPort else {
            return statusError ?? (settings.enabled ? tr("Not running") : tr("Off"))
        }
        var parts = [tr("Listening on 127.0.0.1:\(String(p))")]
        parts.append(clients == 1 ? tr("1 client connected") : tr("\(clients) clients connected"))
        if let c = lastCall { parts.append(tr("last call: \(c)")) }
        return parts.joined(separator: " · ")
    }

    // MARK: Tests

    /// The endpoint, for the self test (tool list, session count).
    var endpointForTesting: MCPEndpoint? { endpoint }
}

// MARK: - Connection

/// One HTTP/1.1 connection: requests are answered in order; the connection stays open between them (keep-alive).
final class MCPConnection {
    private let nw: NWConnection
    private let endpoint: MCPEndpoint
    private let queue: DispatchQueue
    private var buffer = Data()
    private var busy = false
    private var sentContinue = false
    private var closed = false
    var onClose: (() -> Void)?

    init(_ nw: NWConnection, endpoint: MCPEndpoint, queue: DispatchQueue) {
        self.nw = nw
        self.endpoint = endpoint
        self.queue = queue
    }

    func start() {
        nw.stateUpdateHandler = { [weak self] s in
            switch s {
            case .failed, .cancelled: self?.finish()
            default: break
            }
        }
        nw.start(queue: queue)
        receive()
    }

    func cancel() { nw.cancel() }

    private func finish() {
        guard !closed else { return }
        closed = true
        onClose?()
        onClose = nil
    }

    private func receive() {
        nw.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let d = data, !d.isEmpty { self.buffer.append(d); self.process() }
            if isComplete || error != nil {
                if !self.busy { self.nw.cancel() }
                return
            }
            self.receive()
        }
    }

    private func process() {
        guard !busy, !closed, !buffer.isEmpty else { return }
        switch MCPHTTP.parse(buffer) {
        case .needMore(let expectContinue):
            if expectContinue && !sentContinue {
                sentContinue = true
                nw.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .contentProcessed { _ in })
            }
        case .invalid(let status, let message):
            busy = true
            let r = MCPHTTPResponse.json(status, MCPEndpoint.errorObject(id: nil, code: MCPEndpoint.invalidRequest, message: message))
            nw.send(content: r.serialized(keepAlive: false), completion: .contentProcessed { [weak self] _ in self?.nw.cancel() })
        case .request(let req, let consumed):
            buffer.removeSubrange(0..<consumed)
            sentContinue = false
            busy = true
            endpoint.handle(req) { [weak self] resp in
                guard let self else { return }
                self.queue.async {
                    let keep = req.keepAlive
                    self.nw.send(content: resp.serialized(keepAlive: keep), completion: .contentProcessed { [weak self] _ in
                        guard let self else { return }
                        self.busy = false
                        if keep { self.process() } else { self.nw.cancel() }
                    })
                }
            }
        }
    }
}
