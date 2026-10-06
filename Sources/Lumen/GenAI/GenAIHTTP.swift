import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import ImageCratCore

/// Small HTTP layer shared by all providers: base-URL overrides, multipart, error mapping, retries, polling.
enum GenHTTP {
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral          // no cookies / URL cache on disk
        c.timeoutIntervalForRequest = 180
        c.timeoutIntervalForResource = 900
        c.httpAdditionalHeaders = ["User-Agent": "ImageCrat/1.0 (macOS)"]
        return URLSession(configuration: c)
    }()

    /// Resolves a provider base URL, honouring the hidden debug override `LUMEN_GENAI_BASEURL_<PROVIDER>` (mock servers).
    static func base(_ p: ProviderID, _ def: String) -> String {
        if let o = GenHTTP.overrides[p] { return o }
        if let e = ProcessInfo.processInfo.environment[p.envOverrideKey], !e.isEmpty { return e.hasSuffix("/") ? String(e.dropLast()) : e }
        return def
    }
    /// Test-only in-process override (the self test points providers at the local mock).
    nonisolated(unsafe) static var overrides: [ProviderID: String] = [:]

    /// fal.ai Platform API base (billing / usage): `https://api.fal.ai`, or the mock given by `LUMEN_GENAI_BASEURL_FAL_API`.
    /// While the queue API points at a mock and no platform mock is configured this is nil, so tests can never reach the real API.
    static var falPlatformBase: String? {
        if let o = platformOverride { return o }
        if let e = ProcessInfo.processInfo.environment["LUMEN_GENAI_BASEURL_FAL_API"], !e.isEmpty { return e.hasSuffix("/") ? String(e.dropLast()) : e }
        if overrides[.fal] != nil || !(ProcessInfo.processInfo.environment[ProviderID.fal.envOverrideKey] ?? "").isEmpty { return nil }
        return "https://api.fal.ai"
    }
    nonisolated(unsafe) static var platformOverride: String?

    static func url(_ s: String) throws -> URL {
        guard let u = URL(string: s) else { throw GenError.badResponse("invalid URL \(s)") }
        return u
    }

    // MARK: Request building

    static func jsonRequest(_ url: URL, method: String = "POST", headers: [String: String], body: Any?) throws -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        }
        return r
    }

    struct Multipart {
        let boundary = "LumenBoundary-" + UUID().uuidString
        private(set) var body = Data()

        mutating func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        mutating func file(_ name: String, filename: String, mime: String, data: Data) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
            body.append(data)
            body.append("\r\n".data(using: .utf8)!)
        }
        func finished() -> Data { var b = body; b.append("--\(boundary)--\r\n".data(using: .utf8)!); return b }
        var contentType: String { "multipart/form-data; boundary=\(boundary)" }

        func request(_ url: URL, headers: [String: String]) -> URLRequest {
            var r = URLRequest(url: url)
            r.httpMethod = "POST"
            for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
            r.setValue(contentType, forHTTPHeaderField: "Content-Type")
            r.httpBody = finished()
            return r
        }
    }

    // MARK: Sending

    /// Sends a request, mapping HTTP failures to `GenError`. Retries 429 (honouring Retry-After up to 20 s) and
    /// transient 5xx / network errors a couple of times. Cancellation propagates as `GenError.cancelled`.
    static func send(_ req: URLRequest, provider: ProviderID, retries: Int = 2) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            try checkCancelled()
            let data: Data, resp: URLResponse
            do {
                (data, resp) = try await session.data(for: req)
            } catch let e as URLError where e.code == .cancelled {
                throw GenError.cancelled
            } catch is CancellationError {
                throw GenError.cancelled
            } catch let e as URLError {
                if attempt < retries, [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(e.code), !Task.isCancelled {
                    attempt += 1
                    try await sleep(Double(attempt) * 1.5)
                    continue
                }
                if e.code == .timedOut { throw GenError.timeout }
                throw GenError.network(e.localizedDescription)
            } catch {
                throw GenError.network(error.localizedDescription)
            }
            guard let http = resp as? HTTPURLResponse else { throw GenError.badResponse("no HTTP response") }
            if (200..<300).contains(http.statusCode) { return (data, http) }
            let err = mapError(status: http.statusCode, data: data, headers: http, provider: provider)
            if case .rateLimited(let after) = err, attempt < retries, (after ?? 2) <= 20 {
                attempt += 1
                try await sleep(after ?? Double(attempt) * 2)
                continue
            }
            if http.statusCode >= 500, http.statusCode != 501, attempt < retries {
                attempt += 1
                try await sleep(Double(attempt) * 2)
                continue
            }
            throw err
        }
    }

    static func sendJSON(_ req: URLRequest, provider: ProviderID) async throws -> [String: Any] {
        let (d, _) = try await send(req, provider: provider)
        return try parseJSON(d)
    }

    static func parseJSON(_ d: Data) throws -> [String: Any] {
        guard let o = try? JSONSerialization.jsonObject(with: d), let dict = o as? [String: Any] else {
            throw GenError.badResponse(String(data: d.prefix(200), encoding: .utf8) ?? "\(d.count) bytes")
        }
        return dict
    }

    static func sleep(_ s: Double) async throws {
        do { try await Task.sleep(nanoseconds: UInt64(max(0, s) * 1_000_000_000)) } catch { throw GenError.cancelled }
    }

    static func checkCancelled() throws { if Task.isCancelled { throw GenError.cancelled } }

    /// Parses `Retry-After` (seconds or HTTP date) and OpenAI-style `x-ratelimit-reset-*` ("1.5s", "20ms").
    static func retryAfter(_ h: HTTPURLResponse) -> Double? {
        if let v = h.value(forHTTPHeaderField: "Retry-After") ?? h.value(forHTTPHeaderField: "retry-after") {
            if let s = Double(v.trimmingCharacters(in: .whitespaces)) { return s }
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let d = f.date(from: v) { return max(0, d.timeIntervalSinceNow) }
        }
        if let v = h.value(forHTTPHeaderField: "retry-after-ms"), let ms = Double(v) { return ms / 1000 }
        for k in ["x-ratelimit-reset-requests", "x-ratelimit-reset-tokens"] {
            if let v = h.value(forHTTPHeaderField: k) {
                if v.hasSuffix("ms"), let n = Double(v.dropLast(2)) { return n / 1000 }
                if v.hasSuffix("s"), let n = Double(v.dropLast()) { return n }
            }
        }
        return nil
    }

    /// Human-readable message out of the common error envelopes.
    static func errorMessage(_ data: Data) -> String {
        guard let o = try? JSONSerialization.jsonObject(with: data) else {
            return String(data: data.prefix(300), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        if let d = o as? [String: Any] {
            if let e = d["error"] as? [String: Any] { return (e["message"] as? String) ?? (e["status"] as? String) ?? "\(e)" }   // OpenAI, Google
            if let e = d["error"] as? String { return e }                                                                      // Replicate/fal
            if let errs = d["errors"] as? [String], !errs.isEmpty { return errs.joined(separator: "; ") }                        // Stability
            if let detail = d["detail"] as? String { return detail }                                                           // Replicate, BFL, fal
            if let detail = d["detail"] as? [[String: Any]] {                                                                  // FastAPI validation (fal, BFL)
                return detail.compactMap { $0["msg"] as? String }.joined(separator: "; ")
            }
            if let m = d["message"] as? String { return m }
        }
        return ""
    }

    static let moderationWords = ["moderat", "safety", "content_policy", "content policy", "nsfw", "prohibited", "flagged", "blocked", "inappropriate"]

    static func looksModerated(_ s: String) -> Bool {
        let l = s.lowercased()
        return moderationWords.contains { l.contains($0) }
    }

    static func mapError(status: Int, data: Data, headers: HTTPURLResponse, provider: ProviderID) -> GenError {
        let msg = errorMessage(data)
        let name = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["name"] as? String ?? ""
        switch status {
        case 401: return .unauthorized(msg)
        case 402: return .insufficientCredits(msg)
        case 403:
            if name == "content_moderation" || looksModerated(msg) { return .moderated(msg) }
            return .unauthorized(msg)
        case 429:
            if msg.lowercased().contains("quota") || msg.lowercased().contains("billing") || msg.lowercased().contains("credit") {
                return .insufficientCredits(msg)
            }
            return .rateLimited(retryAfter: retryAfter(headers))
        case 400, 422:
            if name == "content_moderation" || looksModerated(msg) { return .moderated(msg) }
            return .http(status, msg)
        default:
            return .http(status, msg)
        }
    }

    // MARK: Images

    static func pngData(_ img: CGImage) -> Data {
        let d = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(d, UTType.png.identifier as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
        return d as Data
    }

    static func jpegData(_ img: CGImage, quality: Double = 0.92) -> Data {
        let d = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(d, UTType.jpeg.identifier as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return d as Data
    }

    static func decodeImage(_ d: Data) throws -> CGImage {
        guard let src = CGImageSourceCreateWithData(d as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw GenError.badResponse("could not decode image (\(d.count) bytes)")
        }
        return img
    }

    static func decodeBase64Image(_ s: String) throws -> CGImage {
        var b64 = s
        if s.hasPrefix("data:"), let comma = s.firstIndex(of: ",") { b64 = String(s[s.index(after: comma)...]) }
        guard let d = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else { throw GenError.badResponse("invalid base64 image") }
        return try decodeImage(d)
    }

    static func dataURI(png img: CGImage) -> String { "data:image/png;base64," + pngData(img).base64EncodedString() }
    static func dataURI(jpeg img: CGImage) -> String { "data:image/jpeg;base64," + jpegData(img).base64EncodedString() }

    /// Downloads an image result (http(s) or data: URI).
    static func fetchImage(_ s: String, provider: ProviderID, headers: [String: String] = [:]) async throws -> CGImage {
        if s.hasPrefix("data:") { return try decodeBase64Image(s) }
        var r = URLRequest(url: try url(s))
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        let (d, _) = try await send(r, provider: provider)
        return try decodeImage(d)
    }
}

// MARK: - Provider protocol

protocol GenerativeProvider: AnyObject {
    var id: ProviderID { get }
    var models: [GenModel] { get }
    /// Starts a job. Synchronous APIs return `.done`, queue APIs `.pending`.
    func submit(_ req: GenRequest, model: GenModel, key: String) async throws -> GenJobHandle
    func poll(_ job: PendingJob, model: GenModel, key: String) async throws -> PollState
    func cancel(_ job: PendingJob, model: GenModel, key: String) async
    /// Cheap authenticated call; returns a short description on success.
    func testKey(_ key: String) async throws -> String
}

extension GenerativeProvider {
    func poll(_ job: PendingJob, model: GenModel, key: String) async throws -> PollState { throw GenError.unsupported("polling not supported") }
    func cancel(_ job: PendingJob, model: GenModel, key: String) async {}

    /// submit → poll loop with backoff; cancels the remote job if the Swift task is cancelled.
    func run(_ req: GenRequest, model: GenModel, key: String, timeout: Double = 600, progress: @escaping (GenProgress) -> Void) async throws -> [GenImage] {
        progress(GenProgress(fraction: nil, message: "Sending to \(tr(id.displayName))…"))
        let h = try await submit(req, model: model, key: key)
        guard case .pending(let job) = h else {
            if case .done(let imgs) = h { return imgs }
            return []
        }
        let start = Date()
        var delay = GenHTTP.pollInterval
        // The remote cancel must run outside the (already cancelled) task, or URLSession refuses to send it.
        let cancelRemote: () async -> Void = { [self] in await Task.detached { await self.cancel(job, model: model, key: key) }.value }
        while true {
            if Task.isCancelled { await cancelRemote(); throw GenError.cancelled }
            if Date().timeIntervalSince(start) > timeout { await cancelRemote(); throw GenError.timeout }
            do { try await GenHTTP.sleep(delay) } catch { await cancelRemote(); throw GenError.cancelled }
            let state: PollState
            do { state = try await poll(job, model: model, key: key) } catch GenError.cancelled { await cancelRemote(); throw GenError.cancelled }
            switch state {
            case .done(let imgs): return imgs
            case .pending(let p): progress(p)
            }
            delay = min(delay * 1.3, 4)
        }
    }
}

extension GenHTTP {
    /// First poll delay (the self test shortens it).
    nonisolated(unsafe) static var pollInterval: Double = 1.0
}
