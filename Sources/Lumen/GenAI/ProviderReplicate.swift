import Foundation
import CoreGraphics
import ImageCratCore

/// Replicate predictions API: `POST /v1/models/{owner}/{name}/predictions {input}` (`Authorization: Bearer`, `Prefer: wait=N`),
/// poll `GET /v1/predictions/{id}` (starting/processing/succeeded/failed/canceled), cancel `POST /v1/predictions/{id}/cancel`.
/// Files: data URIs up to 256 KB, larger ones are uploaded with `POST /v1/files` (multipart `content`) and deleted afterwards.
/// Docs: https://replicate.com/docs/reference/http (OpenAPI https://api.replicate.com/openapi.json)
final class ReplicateProvider: GenerativeProvider {
    let id = ProviderID.replicate
    var base: String { GenHTTP.base(.replicate, "https://api.replicate.com") }
    static let dataURILimit = 256 * 1024

    static func caps(_ mask: MaskKind, edge: Int = 1024, mp: Double = 2) -> ProviderCapabilities {
        ProviderCapabilities(maxMegapixels: mp, minMegapixels: 0, minAspect: 0.25, maxAspect: 4, maxEdge: max(edge, 1536), preferredEdge: edge,
                             maskKind: mask, alphaOutput: false, maxReferenceImages: 0, maxImagesPerCall: 1, allowedSizes: nil, sizeMultiple: 16, async: true)
    }

    lazy var models: [GenModel] = [
        GenModel(provider: .replicate, model: "black-forest-labs/flux-fill-pro", name: "FLUX.1 Fill Pro", features: [.fill, .remove, .expand, .sky, .background], caps: Self.caps(.grayWhiteEdit), pricePerImage: 0.05),
        GenModel(provider: .replicate, model: "black-forest-labs/flux-kontext-pro", name: "FLUX.1 Kontext Pro", features: [.promptEdit, .harmonize, .similar, .generateImage], caps: Self.caps(.none), pricePerImage: 0.04),
        GenModel(provider: .replicate, model: "topazlabs/image-upscale", name: "Topaz Image Upscale", features: [.upscale], caps: Self.caps(.none, edge: 3000, mp: 16), pricePerImage: 0.05),
    ]

    func headers(_ key: String) -> [String: String] { ["Authorization": "Bearer \(key)"] }

    /// data: URI for small files, otherwise an uploaded file URL (id recorded for cleanup).
    func fileURL(_ data: Data, mime: String, key: String, uploaded: inout [String]) async throws -> String {
        if data.count <= Self.dataURILimit { return "data:\(mime);base64," + data.base64EncodedString() }
        var mp = GenHTTP.Multipart()
        mp.file("content", filename: mime == "image/png" ? "image.png" : "image.jpg", mime: mime, data: data)
        mp.field("filename", mime == "image/png" ? "image.png" : "image.jpg")
        mp.field("type", mime)
        let json = try await GenHTTP.sendJSON(mp.request(try GenHTTP.url(base + "/v1/files"), headers: headers(key)), provider: .replicate)
        guard let urls = json["urls"] as? [String: Any], let get = urls["get"] as? String else { throw GenError.badResponse("file upload: missing urls.get") }
        if let fid = json["id"] as? String { uploaded.append(fid) }
        return get
    }

    func submit(_ r: GenRequest, model: GenModel, key: String) async throws -> GenJobHandle {
        var uploaded: [String] = []
        var input: [String: Any] = [:]
        func need(_ i: CGImage?) throws -> CGImage { guard let i else { throw GenError.unsupported("\(model.name) needs an input image.") }; return i }
        switch model.model {
        case "black-forest-labs/flux-fill-pro":
            input = ["prompt": GenPrompts.text(r), "output_format": "png", "safety_tolerance": 2, "outpaint": "None"]
            input["image"] = try await fileURL(GenHTTP.jpegData(try need(r.image), quality: 0.95), mime: "image/jpeg", key: key, uploaded: &uploaded)
            if let m = r.mask { input["mask"] = try await fileURL(GenImaging.encodeMask(m, kind: .grayWhiteEdit), mime: "image/png", key: key, uploaded: &uploaded) }
        case "black-forest-labs/flux-kontext-pro":
            input = ["prompt": GenPrompts.maskless(r), "output_format": "png", "safety_tolerance": 2]
            if let i = r.image ?? r.references.first {
                input["input_image"] = try await fileURL(GenHTTP.jpegData(i, quality: 0.95), mime: "image/jpeg", key: key, uploaded: &uploaded)
                input["aspect_ratio"] = "match_input_image"
            } else {
                input["aspect_ratio"] = GenImaging.aspectString(r.width, r.height, allowed: ["21:9", "16:9", "4:3", "3:2", "1:1", "2:3", "3:4", "9:16", "9:21"])
            }
        case "topazlabs/image-upscale":
            input = ["enhance_model": r.contentType == .art ? "CGI" : "Standard V2", "upscale_factor": r.upscaleFactor >= 3 ? "4x" : "2x"]
            input["image"] = try await fileURL(GenHTTP.pngData(try need(r.image)), mime: "image/png", key: key, uploaded: &uploaded)
        default:
            throw GenError.unsupported("Unknown Replicate model \(model.model)")
        }
        if let s = r.seed, model.model.hasPrefix("black-forest-labs") { input["seed"] = s }
        var h = headers(key)
        if GenAISettings.shared.data.replicatePreferWait { h["Prefer"] = "wait=60" }
        let req = try GenHTTP.jsonRequest(try GenHTTP.url(base + "/v1/models/\(model.model)/predictions"), headers: h, body: ["input": input])
        let json = try await GenHTTP.sendJSON(req, provider: .replicate)
        let job = try pending(json, files: uploaded)
        if let done = try await finished(json, model: model, key: key, job: job) { return .done(done) }
        return .pending(job)
    }

    func pending(_ json: [String: Any], files: [String]) throws -> PendingJob {
        guard let pid = json["id"] as? String else { throw GenError.badResponse("missing prediction id") }
        let urls = json["urls"] as? [String: Any]
        let get = (urls?["get"] as? String) ?? (base + "/v1/predictions/\(pid)")
        let cancel = (urls?["cancel"] as? String) ?? (base + "/v1/predictions/\(pid)/cancel")
        return PendingJob(id: pid, pollURL: try GenHTTP.url(get), cancelURL: URL(string: cancel), extra: ["files": files.joined(separator: ",")])
    }

    /// Returns images when the prediction reached a terminal state (throws on failed/canceled), nil while running.
    func finished(_ json: [String: Any], model: GenModel, key: String, job: PendingJob) async throws -> [GenImage]? {
        let status = json["status"] as? String ?? ""
        switch status {
        case "succeeded":
            await cleanup(job, key: key)
            var urls: [String] = []
            if let s = json["output"] as? String { urls = [s] } else if let a = json["output"] as? [String] { urls = a }
            if urls.isEmpty { throw GenError.badResponse("prediction succeeded without output") }
            var out: [GenImage] = []
            let host = URL(string: base)?.host
            for u in urls {
                let auth = URL(string: u)?.host == host ? headers(key) : [:]
                out.append(GenImage(image: try await GenHTTP.fetchImage(u, provider: .replicate, headers: auth)))
            }
            out[0].cost = model.pricePerImage
            return out
        case "failed":
            await cleanup(job, key: key)
            let e = json["error"] as? String ?? "prediction failed"
            if GenHTTP.looksModerated(e) { throw GenError.moderated(e) }
            throw GenError.badResponse(e)
        case "canceled":
            await cleanup(job, key: key)
            throw GenError.cancelled
        default:
            return nil
        }
    }

    func poll(_ job: PendingJob, model: GenModel, key: String) async throws -> PollState {
        var r = URLRequest(url: job.pollURL)
        for (k, v) in headers(key) { r.setValue(v, forHTTPHeaderField: k) }
        let json = try await GenHTTP.sendJSON(r, provider: .replicate)
        if let imgs = try await finished(json, model: model, key: key, job: job) { return .done(imgs) }
        return .pending(GenProgress(fraction: nil, message: "Replicate: \(json["status"] as? String ?? "running")…"))
    }

    func cancel(_ job: PendingJob, model: GenModel, key: String) async {
        if let u = job.cancelURL {
            var r = URLRequest(url: u)
            r.httpMethod = "POST"
            r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            _ = try? await GenHTTP.session.data(for: r)
        }
        await cleanup(job, key: key)
    }

    /// Deletes uploaded input files (privacy).
    func cleanup(_ job: PendingJob, key: String) async {
        for fid in (job.extra["files"] ?? "").split(separator: ",") where !fid.isEmpty {
            guard let u = URL(string: base + "/v1/files/\(fid)") else { continue }
            var r = URLRequest(url: u)
            r.httpMethod = "DELETE"
            r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            _ = try? await GenHTTP.session.data(for: r)
        }
    }

    func testKey(_ key: String) async throws -> String {
        var r = URLRequest(url: try GenHTTP.url(base + "/v1/account"))
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let json = try await GenHTTP.sendJSON(r, provider: .replicate)
        return "Key OK — \(json["username"] as? String ?? "account") (\(json["type"] as? String ?? ""))"
    }
}
