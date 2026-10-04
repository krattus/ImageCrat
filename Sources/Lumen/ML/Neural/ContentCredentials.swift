import SwiftUI
import C2PA
import UniformTypeIdentifiers

/// Content Credentials (C2PA) — signing exports with a locally generated test certificate and reading/verifying
/// credentials of files (c2pa-swift / c2pa-rs).
enum ContentCredentials {
    /// Hook: does the document contain generative-AI content? (set by the generative-layer module when it lands)
    static var usedGenerativeAI: (Document) -> Bool = { _ in false }

    /// Persisted "Attach Content Credentials" export preference.
    static var attachOnExport: Bool {
        get { UserDefaults.standard.bool(forKey: "Lumen.AttachContentCredentials") }
        set { UserDefaults.standard.set(newValue, forKey: "Lumen.AttachContentCredentials") }
    }

    /// History steps produced by on-device generative / neural tools.
    static let neuralActionNames = ["Remove", "Remove Distractions", "Neural Filters", "Sky Replacement", "AI Denoise", "AI Sharpen", "AI Upscale"]
        + NeuralFilterKind.allCases.map(\.title)

    static func usedNeuralTools(_ d: Document) -> [String] {
        Array(Set(d.history.map(\.name).filter { neuralActionNames.contains($0) })).sorted()
    }

    static var version: String { C2PA.version }

    // MARK: Credentials

    static var credentialsDir: URL {
        let u = Brand.supportFolder.appendingPathComponent("ContentCredentials")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return u
    }

    enum CCError: LocalizedError {
        case openssl(String), unsupported(String)
        var errorDescription: String? {
            switch self {
            case .openssl(let m): return "Could not create the signing certificate: \(m)"
            case .unsupported(let f): return "Content Credentials can't be embedded in \(f) files."
            }
        }
    }

    /// Test signing identity (ES256): a local root CA + end-entity certificate, generated with openssl on first use
    /// and kept in Application Support (0600). Verifiers report it as *untrusted* (it isn't on the C2PA trust list).
    static func signerInfo() throws -> SignerInfo {
        let dir = credentialsDir
        let chain = dir.appendingPathComponent("signing-chain.pem"), key = dir.appendingPathComponent("signing-key.pem")
        if !FileManager.default.fileExists(atPath: chain.path) || !FileManager.default.fileExists(atPath: key.path) {
            try generateCertificates(in: dir)
        }
        return SignerInfo(algorithm: .es256, certificatePEM: try String(contentsOf: chain, encoding: .utf8),
                          privateKeyPEM: try String(contentsOf: key, encoding: .utf8))
    }

    static func generateCertificates(in dir: URL) throws {
        let openssl = ["/usr/bin/openssl", "/opt/homebrew/bin/openssl", "/usr/local/bin/openssl"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let bin = openssl else { throw CCError.openssl("openssl not found") }
        let work = dir.appendingPathComponent("tmp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let user = NSUserName()
        let cnf = """
        [ req ]
        distinguished_name = dn
        prompt = no
        [ dn ]
        CN = ImageCrat Local Test Root CA
        O = ImageCrat (local test)
        [ v3_ca ]
        basicConstraints = critical, CA:TRUE
        keyUsage = critical, keyCertSign, cRLSign
        subjectKeyIdentifier = hash
        [ v3_leaf ]
        basicConstraints = critical, CA:FALSE
        keyUsage = critical, digitalSignature
        extendedKeyUsage = emailProtection
        subjectKeyIdentifier = hash
        authorityKeyIdentifier = keyid, issuer
        """
        try cnf.write(to: work.appendingPathComponent("c.cnf"), atomically: true, encoding: .utf8)
        func run(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = args
            p.currentDirectoryURL = work
            let err = Pipe()
            p.standardError = err
            p.standardOutput = Pipe()
            try p.run(); p.waitUntilExit()
            if p.terminationStatus != 0 {
                throw CCError.openssl(String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "exit \(p.terminationStatus)")
            }
        }
        try run(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", "ca.key"])
        try run(["req", "-new", "-x509", "-key", "ca.key", "-sha256", "-days", "3650", "-config", "c.cnf", "-extensions", "v3_ca", "-out", "ca.pem"])
        try run(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", "leaf.key"])
        try run(["pkcs8", "-topk8", "-nocrypt", "-in", "leaf.key", "-out", "leaf.p8"])
        try run(["req", "-new", "-key", "leaf.key", "-subj", "/CN=ImageCrat Local Signer (\(user))/O=ImageCrat (local test)", "-out", "leaf.csr"])
        try run(["x509", "-req", "-in", "leaf.csr", "-CA", "ca.pem", "-CAkey", "ca.key", "-CAcreateserial", "-sha256", "-days", "730",
                 "-extfile", "c.cnf", "-extensions", "v3_leaf", "-out", "leaf.pem"])
        let chain = try String(contentsOf: work.appendingPathComponent("leaf.pem"), encoding: .utf8) + String(contentsOf: work.appendingPathComponent("ca.pem"), encoding: .utf8)
        let fm = FileManager.default
        let chainURL = dir.appendingPathComponent("signing-chain.pem"), keyURL = dir.appendingPathComponent("signing-key.pem")
        try chain.write(to: chainURL, atomically: true, encoding: .utf8)
        try? fm.removeItem(at: keyURL)
        try fm.copyItem(at: work.appendingPathComponent("leaf.p8"), to: keyURL)
        try? fm.removeItem(at: dir.appendingPathComponent("root-ca.pem"))
        try fm.copyItem(at: work.appendingPathComponent("ca.pem"), to: dir.appendingPathComponent("root-ca.pem"))
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
    }

    // MARK: Signing

    static func mime(_ url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "tif", "tiff": return "image/tiff"
        case "heic": return "image/heic"
        case "heif": return "image/heif"
        case "webp": return "image/webp"
        case "gif": return "image/gif"
        case "avif": return "image/avif"
        default: return nil
        }
    }

    static func manifestJSON(title: String, format: String, generativeAI: Bool, neuralTools: [String], newDocument: Bool) -> String {
        let iptc = "http://cv.iptc.org/newscodes/digitalsourcetype/"
        var actions: [[String: Any]] = [
            ["action": "c2pa.created", "digitalSourceType": iptc + (newDocument ? "digitalCreation" : "digitalCapture"),
             "softwareAgent": ["name": Brand.name, "version": "1.0"], "description": newDocument ? "Created in ImageCrat" : "Opened in ImageCrat"],
            ["action": "c2pa.edited", "softwareAgent": ["name": Brand.name, "version": "1.0"], "description": "Edited with ImageCrat"],
        ]
        if !neuralTools.isEmpty {
            actions.append(["action": "c2pa.edited", "softwareAgent": ["name": "ImageCrat on-device ML"],
                            "digitalSourceType": iptc + "compositeWithTrainedAlgorithmicMedia",
                            "description": "On-device neural tools: " + neuralTools.joined(separator: ", ")])
        }
        if generativeAI {
            actions.append(["action": "c2pa.edited", "softwareAgent": ["name": "ImageCrat Generative AI"],
                            "digitalSourceType": iptc + "compositeWithTrainedAlgorithmicMedia", "description": "Contains generative AI content"])
        }
        let manifest: [String: Any] = [
            "claim_generator_info": [["name": Brand.name, "version": "1.0"]],
            "title": title,
            "format": format,
            "assertions": [["label": "c2pa.actions.v2", "data": ["actions": actions]]],
        ]
        let d = try? JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        return String(data: d ?? Data(), encoding: .utf8) ?? "{}"
    }

    /// Signs an exported file in place.
    static func sign(file url: URL, title: String? = nil, generativeAI: Bool, neuralTools: [String], newDocument: Bool) throws {
        guard let fmt = mime(url) else { throw CCError.unsupported(url.pathExtension.uppercased()) }
        let info = try signerInfo()
        let json = manifestJSON(title: title ?? url.lastPathComponent, format: fmt, generativeAI: generativeAI, neuralTools: neuralTools, newDocument: newDocument)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".c2pa-\(UUID().uuidString).\(url.pathExtension)")
        try C2PA.signFile(source: url, destination: tmp, manifestJSON: json, signerInfo: info)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    /// Signs an export of `d`.
    static func signExport(_ url: URL, document d: Document) throws {
        try sign(file: url, title: url.lastPathComponent, generativeAI: usedGenerativeAI(d), neuralTools: usedNeuralTools(d), newDocument: d.fileURL == nil)
    }

    // MARK: Reading

    struct Summary {
        var state: String = "None"             // Valid / Trusted / Invalid / None
        var title = ""
        var generator = ""
        var issuer = ""
        var time = ""
        var actions: [String] = []
        var aiGenerated = false
        var ingredients: [String] = []
        var statusCodes: [String] = []
        var json = ""
        var untrusted: Bool { statusCodes.contains { $0.contains("untrusted") } }
    }

    static func read(_ url: URL) -> Result<Summary, Error> {
        do {
            let json = try C2PA.readFile(at: url)
            return .success(summarize(json))
        } catch {
            return .failure(error)
        }
    }

    static func summarize(_ json: String) -> Summary {
        var s = Summary()
        s.json = json
        guard let data = json.data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return s }
        s.state = root["validation_state"] as? String ?? ((root["validation_status"] as? [Any])?.isEmpty == false ? "Invalid" : "Valid")
        s.statusCodes = (root["validation_status"] as? [[String: Any]] ?? []).compactMap { $0["code"] as? String }
        if let vr = root["validation_results"] as? [String: Any], let am = vr["activeManifest"] as? [String: Any] {
            for key in ["success", "informational", "failure"] {
                for e in (am[key] as? [[String: Any]] ?? []) { if let c = e["code"] as? String, !s.statusCodes.contains(c) { s.statusCodes.append((key == "failure" ? "✗ " : "") + c) } }
            }
        }
        guard let active = root["active_manifest"] as? String, let manifests = root["manifests"] as? [String: Any],
              let m = manifests[active] as? [String: Any] else { return s }
        s.title = m["title"] as? String ?? ""
        if let g = m["claim_generator"] as? String { s.generator = g }
        if let gi = (m["claim_generator_info"] as? [[String: Any]])?.first { s.generator = [gi["name"] as? String, gi["version"] as? String].compactMap { $0 }.joined(separator: " ") }
        if let sig = m["signature_info"] as? [String: Any] {
            s.issuer = sig["issuer"] as? String ?? sig["common_name"] as? String ?? ""
            s.time = sig["time"] as? String ?? ""
        }
        for a in m["assertions"] as? [[String: Any]] ?? [] {
            guard let label = a["label"] as? String, label.hasPrefix("c2pa.actions"), let d = a["data"] as? [String: Any] else { continue }
            for act in d["actions"] as? [[String: Any]] ?? [] {
                let name = (act["action"] as? String ?? "?").replacingOccurrences(of: "c2pa.", with: "")
                let src = act["digitalSourceType"] as? String ?? ""
                if src.contains("trainedAlgorithmicMedia") || src.contains("TrainedAlgorithmicMedia") { s.aiGenerated = true }
                let desc = act["description"] as? String
                s.actions.append(desc.map { "\(name) — \($0)" } ?? name)
            }
        }
        s.ingredients = (m["ingredients"] as? [[String: Any]] ?? []).compactMap { $0["title"] as? String }
        return s
    }
}

// MARK: - Panel (Window ▸ Content Credentials)

struct ContentCredentialsPanel: View {
    @Bindable var app = AppModel.shared
    @State private var url: URL? = nil
    @State private var summary: ContentCredentials.Summary? = nil
    @State private var error: String? = nil
    @State private var showJSON = false

    /// `preload`: show this file's credentials immediately (otherwise the active document's file).
    init(preload: URL? = nil) {
        guard let u = preload else { return }
        _url = State(initialValue: u)
        switch ContentCredentials.read(u) {
        case .success(let s): _summary = State(initialValue: s)
        case .failure(let e): _error = State(initialValue: "No Content Credentials (\(e.localizedDescription))")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(url?.lastPathComponent ?? "No file").font(Theme.fontBold).lineLimit(1)
                Spacer()
                Button("Verify File…") { pick() }.buttonStyle(PanelButtonStyle())
            }
            if let s = summary {
                HStack(spacing: 6) {
                    Image(systemName: s.state == "Invalid" ? "xmark.seal" : (s.untrusted ? "checkmark.seal" : "checkmark.seal.fill"))
                        .foregroundStyle(s.state == "Invalid" ? .red : (s.untrusted ? .orange : .green))
                    Text(s.state == "Invalid" ? "Invalid credentials" : (s.untrusted ? "Valid – signer not on a trust list" : "Valid (\(s.state))"))
                }
                row("Title", s.title); row("App", s.generator); row("Signed by", s.issuer)
                if !s.time.isEmpty { row("Signed", s.time) }
                if s.aiGenerated { Label("Contains AI-generated / AI-edited content", systemImage: "sparkles").font(Theme.fontSmall).foregroundStyle(.purple) }
                Caption("Actions")
                ForEach(Array(s.actions.enumerated()), id: \.offset) { _, a in Text("• " + a).font(Theme.fontSmall).foregroundStyle(Theme.textDim) }
                if !s.ingredients.isEmpty { Caption("Ingredients"); ForEach(s.ingredients, id: \.self) { Text("• " + $0).font(Theme.fontSmall) } }
                DisclosureGroup("Validation (\(s.statusCodes.count))") {
                    ForEach(s.statusCodes, id: \.self) { Text($0).font(Theme.fontSmall).foregroundStyle(Theme.textFaint) }
                }.font(Theme.fontSmall)
                DisclosureGroup("Manifest JSON", isExpanded: $showJSON) {
                    ScrollView { Text(s.json).font(.system(size: 9, design: .monospaced)).textSelection(.enabled) }.frame(height: 160)
                }.font(Theme.fontSmall)
            } else if let e = error {
                Text(e).font(Theme.fontSmall).foregroundStyle(Theme.textDim)
            } else {
                Text("Open a file to see its Content Credentials.").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
            }
            Divider()
            Toggle2(label: "Attach Content Credentials on Export", on: Binding(get: { ContentCredentials.attachOnExport }, set: { ContentCredentials.attachOnExport = $0 }))
            Text("Exports are signed with a local test certificate (shown as untrusted by verifiers). c2pa \(ContentCredentials.version)")
                .font(.system(size: 9)).foregroundStyle(Theme.textFaint)
        }
        .padding(8)
        .onAppear { load(app.activeDocument?.fileURL) }
        .onChange(of: app.activeDocumentID) { _, _ in load(app.activeDocument?.fileURL) }
    }

    func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) { Text(k).foregroundStyle(Theme.textFaint).frame(width: 64, alignment: .leading); Text(v).lineLimit(2) }.font(Theme.fontSmall)
    }

    func load(_ u: URL?) {
        url = u; summary = nil; error = nil
        guard let u else { return }
        switch ContentCredentials.read(u) {
        case .success(let s): summary = s
        case .failure(let e): error = "No Content Credentials (\(e.localizedDescription))"
        }
    }

    func pick() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        UIBlock.begin(p) { r in if r == .OK, let u = p.url { load(u) } }
    }
}
