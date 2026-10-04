#!/usr/bin/env python3
"""Local mock of the generative-image provider APIs used by ImageCrat's self test (no real network calls).

Usage: genai_mock_server.py <port> [logdir]
Base URLs: http://127.0.0.1:<port>/<provider>  (openai, gemini, stability, fal, replicate, bfl)
           http://127.0.0.1:<port>/falapi     fal.ai Platform API (GET /v1/account/billing, GET /v1/models/usage);
                                              only "Key test-fal-admin-key" has the admin scope, other keys get 403, none 401
Control:   GET /__log (recorded requests as JSON), POST /__reset, POST /__scenario {"name": ..., "count": n}
Scenarios: ok | moderation | ratelimit (429, Retry-After: 1) | ratelimit_long (429, Retry-After: 120) | auth (401) | slow (jobs never finish)
Responses are provider-shaped (base64 JSON, image URLs, queue/polling flows) and return striped PNGs.
"""
import base64, datetime, json, os, re, struct, sys, threading, zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

LOCK = threading.Lock()
LOG = []
STATE = {"scenario": "ok", "count": 0, "polls": {}}
COLORS = {"openai": (16, 163, 127), "gemini": (66, 133, 244), "stability": (160, 60, 220), "fal": (240, 120, 20), "replicate": (220, 40, 60), "bfl": (20, 20, 20)}


def png(w, h, color):
    w, h = max(1, min(w, 4096)), max(1, min(h, 4096))
    r, g, b = color
    rows = []
    for y in range(h):
        row = bytearray([0])
        for x in range(w):
            if (x // 16) % 2 == 0:
                row += bytes((r, g, b))
            else:
                row += bytes((min(255, r + 70), min(255, g + 70), min(255, b + 70)))
        rows.append(bytes(row))
    raw = b"".join(rows)

    def chunk(t, d):
        c = struct.pack(">I", len(d)) + t + d
        return c + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b"")


def png_size(data):
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return struct.unpack(">II", data[16:24])
    return None


def parse_multipart(body, ctype):
    m = re.search(r"boundary=(.+)", ctype or "")
    if not m:
        return {}
    b = ("--" + m.group(1)).encode()
    out = {}
    for part in body.split(b)[1:]:
        if part.startswith(b"--"):
            break
        head, _, data = part.partition(b"\r\n\r\n")
        data = data[:-2] if data.endswith(b"\r\n") else data
        nm = re.search(rb'name="([^"]+)"', head)
        if nm:
            out.setdefault(nm.group(1).decode(), []).append(data)
    return out


def first_png_size_json(obj):
    """Find a base64 / data-URI PNG in a JSON body and return its size."""
    stack = [obj]
    while stack:
        o = stack.pop()
        if isinstance(o, dict):
            stack.extend(o.values())
        elif isinstance(o, list):
            stack.extend(o)
        elif isinstance(o, str) and len(o) > 100:
            s = o.split(",", 1)[1] if o.startswith("data:") else o
            try:
                d = base64.b64decode(s[:64] + "=" * (-len(s[:64]) % 4))
                if d[:8] == b"\x89PNG\r\n\x1a\n":
                    return struct.unpack(">II", d[16:24])
            except Exception:
                pass
    return None


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def send_json(self, code, obj, headers=None):
        d = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(d)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(d)

    def send_bytes(self, code, data, ctype="image/png"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self): self.handle_any("GET")
    def do_POST(self): self.handle_any("POST")
    def do_PUT(self): self.handle_any("PUT")
    def do_DELETE(self): self.handle_any("DELETE")

    def base(self, prov):
        return "http://%s/%s" % (self.headers.get("Host"), prov)

    def handle_any(self, method):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else b""
        u = urlparse(self.path)
        path = u.path
        if path == "/__log":
            with LOCK:
                return self.send_json(200, LOG)
        if path == "/__reset":
            with LOCK:
                LOG.clear(); STATE.update(scenario="ok", count=0, polls={})
            return self.send_json(200, {"ok": True})
        if path == "/__scenario":
            j = json.loads(body or b"{}")
            with LOCK:
                STATE["scenario"] = j.get("name", "ok"); STATE["count"] = j.get("count", 1)
            return self.send_json(200, {"ok": True})
        if path.startswith("/files/"):
            m = re.match(r"/files/([a-z]+)_(\d+)x(\d+)(?:_v(\d+))?\.png", path)
            prov, w, h = (m.group(1), int(m.group(2)), int(m.group(3))) if m else ("fal", 64, 64)
            c = COLORS.get(prov, (128, 128, 128))
            v = int(m.group(4) or 0) if m else 0
            for _ in range(v % 3):          # variation n gets its own colour (channels rotated)
                c = (c[2], c[0], c[1])
            return self.send_bytes(200, png(w, h, c))
        with LOCK:
            LOG.append({"method": method, "path": path, "query": u.query, "headers": {k: v for k, v in self.headers.items()},
                        "body": base64.b64encode(body).decode()})
            scen = STATE["scenario"] if STATE["count"] > 0 else "ok"
            if scen != "ok" and method in ("POST",) and not path.endswith("/files"):
                STATE["count"] -= 1
        prov = path.strip("/").split("/")[0]
        rest = "/" + "/".join(path.strip("/").split("/")[1:])
        ctype = self.headers.get("Content-Type", "")
        is_submit = method == "POST" and not rest.endswith("/files")
        if scen == "auth":
            return self.send_json(401, {"error": {"message": "Incorrect API key provided", "code": "invalid_api_key"}})
        if scen == "ratelimit" and is_submit:
            return self.send_json(429, {"error": {"message": "Rate limit reached", "code": "rate_limit_exceeded"}}, {"Retry-After": "1"})
        if scen == "ratelimit_long" and is_submit:
            return self.send_json(429, {"error": {"message": "Rate limit reached", "code": "rate_limit_exceeded"}}, {"Retry-After": "120"})
        if scen == "moderation" and is_submit:
            return self.moderation(prov)
        return getattr(self, "p_" + prov, self.notfound)(method, rest, body, ctype, u, scen)

    def notfound(self, *a):
        self.send_json(404, {"detail": "not found"})

    def moderation(self, prov):
        if prov == "openai":
            return self.send_json(400, {"error": {"message": "Your request was rejected by the safety system.", "type": "image_generation_user_error", "code": "moderation_blocked"}})
        if prov == "gemini":
            return self.send_json(200, {"promptFeedback": {"blockReason": "PROHIBITED_CONTENT"}})
        if prov == "stability":
            return self.send_json(403, {"id": "x", "name": "content_moderation", "errors": ["Your request was flagged by our content moderation system."]})
        if prov == "fal":
            return self.send_json(422, {"detail": [{"msg": "Content flagged by safety checker (nsfw)", "type": "content_policy_violation"}]})
        if prov == "replicate":
            return self.send_json(201, {"id": "pmod", "status": "failed", "error": "NSFW content detected. Try a different prompt.", "urls": {}})
        if prov == "bfl":
            with LOCK:
                STATE["polls"]["bmod"] = "moderated"
            return self.send_json(200, {"id": "bmod", "polling_url": self.base("bfl") + "/v1/get_result?id=bmod"})

    # ---- OpenAI
    def p_openai(self, method, rest, body, ctype, u, scen):
        if rest == "/v1/models":
            return self.send_json(200, {"object": "list", "data": [{"id": "gpt-image-2.5-flare"}, {"id": "gpt-image-2.5-sunburst"}, {"id": "gpt-4.1"}]})
        if rest in ("/v1/images/edits", "/v1/images/generations"):
            if rest.endswith("edits"):
                f = parse_multipart(body, ctype)
                size = f.get("size", [b"1024x1024"])[0].decode(); n = int(f.get("n", [b"1"])[0])
            else:
                j = json.loads(body); size = j.get("size", "1024x1024"); n = j.get("n", 1)
            w, h = (int(x) for x in size.split("x"))
            img = base64.b64encode(png(w, h, COLORS["openai"])).decode()
            return self.send_json(200, {"created": 1, "data": [{"b64_json": img} for _ in range(n)],
                                        "usage": {"input_tokens": 1200, "input_tokens_details": {"image_tokens": 1100, "text_tokens": 100}, "output_tokens": 1500, "total_tokens": 2700}})
        return self.notfound()

    # ---- Gemini
    def p_gemini(self, method, rest, body, ctype, u, scen):
        if rest.startswith("/v1beta/models") and method == "GET":
            return self.send_json(200, {"models": [{"name": "models/gemini-3.1-flash-image"}, {"name": "models/gemini-3-pro-image"}]})
        if rest.endswith(":generateContent"):
            j = json.loads(body)
            size = first_png_size_json(j) or (1024, 1024)
            img = base64.b64encode(png(size[0], size[1], COLORS["gemini"])).decode()
            return self.send_json(200, {"candidates": [{"content": {"role": "model", "parts": [{"text": "Here is the edited image."}, {"inlineData": {"mimeType": "image/png", "data": img}}]}, "finishReason": "STOP"}]})
        return self.notfound()

    # ---- Stability
    def p_stability(self, method, rest, body, ctype, u, scen):
        if rest == "/v1/user/balance":
            return self.send_json(200, {"credits": 42.5})
        if rest.startswith("/v2beta/results/"):
            jid = rest.rsplit("/", 1)[1]
            with LOCK:
                c = STATE["polls"].get(jid, 0); STATE["polls"][jid] = c + 1
            if c < 1 or scen == "slow":
                return self.send_json(202, {"id": jid, "status": "in-progress"})
            return self.send_json(200, {"image": base64.b64encode(png(512, 512, COLORS["stability"])).decode(), "finish_reason": "SUCCESS", "seed": 7})
        if rest.startswith("/v2beta/stable-image/"):
            f = parse_multipart(body, ctype)
            if rest.endswith("replace-background-and-relight") or rest.endswith("upscale/creative"):
                return self.send_json(200, {"id": "st-async-1"})
            src = (f.get("image") or f.get("subject_image") or [b""])[0]
            w, h = png_size(src) or (1024, 1024)
            if rest.endswith("outpaint"):
                w += sum(int(f.get(k, [b"0"])[0]) for k in ("left", "right")); h += sum(int(f.get(k, [b"0"])[0]) for k in ("up", "down"))
            if "upscale" in rest:
                w, h = w * 2, h * 2
            return self.send_json(200, {"image": base64.b64encode(png(w, h, COLORS["stability"])).decode(), "finish_reason": "SUCCESS", "seed": 1234})
        return self.notfound()

    # ---- fal (queue)
    def p_fal(self, method, rest, body, ctype, u, scen):
        m = re.match(r"(.*)/requests/([\w-]+)(/status|/cancel)?$", rest)
        if m:
            app, rid, tail = m.group(1), m.group(2), m.group(3) or ""
            if rid not in STATE["polls"]:
                if self.headers.get("Authorization", "").startswith("Key "):
                    return self.send_json(404, {"detail": "Request not found"})
                return self.send_json(401, {"detail": "Unauthorized"})
            if tail == "/cancel":
                return self.send_json(202, {"status": "CANCELLATION_REQUESTED"})
            with LOCK:
                c = STATE["polls"][rid]; STATE["polls"][rid] = c + 1
            if tail == "/status":
                if scen == "slow" or c == 0:
                    return self.send_json(202, {"status": "IN_QUEUE", "queue_position": 2, "request_id": rid})
                if c == 1:
                    return self.send_json(202, {"status": "IN_PROGRESS", "request_id": rid, "logs": [{"message": "step 10/28"}]})
                return self.send_json(200, {"status": "COMPLETED", "request_id": rid, "logs": [], "metrics": {"inference_time": 1.2}})
            info = STATE["polls"].get(rid + ":info", {"n": 1, "w": 512, "h": 512, "single": False})
            url = "http://%s/files/fal_%dx%d.png" % (self.headers.get("Host"), info["w"], info["h"])
            if info["single"]:
                return self.send_json(200, {"image": {"url": url, "width": info["w"], "height": info["h"], "content_type": "image/png"}})
            return self.send_json(200, {"images": [{"url": url.replace(".png", "_v%d.png" % i), "width": info["w"], "height": info["h"], "content_type": "image/png"} for i in range(info["n"])], "seed": 99})
        if method == "POST":
            j = json.loads(body or b"{}")
            with LOCK:
                rid = "req-%d" % (len(LOG))
                STATE["polls"][rid] = 0
                size = first_png_size_json(j) or (768, 512)
                STATE["polls"][rid + ":info"] = {"n": int(j.get("num_images", 1)), "w": size[0], "h": size[1], "single": ("topaz" in rest or "eraser" in rest)}
            b = self.base("fal") + rest
            return self.send_json(200, {"request_id": rid, "response_url": b + "/requests/" + rid, "status_url": b + "/requests/" + rid + "/status",
                                        "cancel_url": b + "/requests/" + rid + "/cancel", "queue_position": 0})
        return self.notfound()

    # ---- fal Platform API (https://api.fal.ai): billing + usage, admin-scope keys only
    def p_falapi(self, method, rest, body, ctype, u, scen):
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Key "):
            return self.send_json(401, {"error": {"type": "authorization_error", "message": "Authentication required", "request_id": "mock-1"}})
        if auth != "Key test-fal-admin-key":
            return self.send_json(403, {"error": {"type": "authorization_error", "message": "Access denied", "request_id": "mock-2"}})
        q = parse_qs(u.query)
        if rest == "/v1/account/billing" and method == "GET":
            out = {"username": "mock-team"}
            if "credits" in q.get("expand", []):
                out["credits"] = {"current_balance": 24.5, "currency": "USD"}
            return self.send_json(200, out)
        if rest == "/v1/models/usage" and method == "GET":
            try:
                start = datetime.date.fromisoformat(q.get("start", ["2026-09-01"])[0][:10])
            except ValueError:
                return self.send_json(400, {"error": {"type": "validation_error", "message": "Invalid request parameters"}})

            def row(endpoint, qty, price):
                cost = round(qty * price, 4)
                return {"endpoint_id": endpoint, "unit": "image", "quantity": qty, "unit_price": price, "percent_discount": None,
                        "cost_subtotal": cost, "cost_discount": 0, "cost_total": cost, "cost": cost, "currency": "USD"}

            def bucket(day, rows):
                return {"bucket": (start + datetime.timedelta(days=day)).isoformat() + "T00:00:00+00:00", "results": rows}
            expand = q.get("expand", ["time_series"])
            out = {}
            if q.get("cursor", [None])[0] == "page2":
                if "time_series" in expand:
                    out["time_series"] = [bucket(2, [row("fal-ai/topaz/upscale/image", 2, 0.08)])]
                out.update(next_cursor=None, has_more=False)
            else:
                if "time_series" in expand:
                    out["time_series"] = [bucket(0, [row("fal-ai/flux-pro/v1/fill", 6, 0.05)]),
                                          bucket(1, [row("fal-ai/flux-pro/v1/fill", 6, 0.05), row("fal-ai/nano-banana-2/edit", 5, 0.08)])]
                out.update(next_cursor="page2", has_more=True)
            if "summary" in expand:
                out["summary"] = [row("fal-ai/flux-pro/v1/fill", 12, 0.05), row("fal-ai/nano-banana-2/edit", 5, 0.08), row("fal-ai/topaz/upscale/image", 2, 0.08)]
            return self.send_json(200, out)
        return self.notfound()

    # ---- Replicate
    def p_replicate(self, method, rest, body, ctype, u, scen):
        b = self.base("replicate")
        if rest == "/v1/account":
            return self.send_json(200, {"type": "user", "username": "mock-user", "name": "Mock"})
        if rest == "/v1/files" and method == "POST":
            f = parse_multipart(body, ctype)
            size = len(f.get("content", [b""])[0])
            return self.send_json(201, {"id": "file-1", "size": size, "content_type": f.get("type", [b""])[0].decode(), "urls": {"get": b + "/v1/files/file-1"}})
        if rest.startswith("/v1/files/") and method == "DELETE":
            self.send_response(204); self.send_header("Content-Length", "0"); self.end_headers(); return
        m = re.match(r"/v1/models/([\w-]+)/([\w.-]+)/predictions$", rest)
        if m and method == "POST":
            with LOCK:
                pid = "pred-%d" % len(LOG); STATE["polls"][pid] = 0
            return self.send_json(201, {"id": pid, "status": "starting", "input": {}, "output": None, "error": None,
                                        "urls": {"get": b + "/v1/predictions/" + pid, "cancel": b + "/v1/predictions/" + pid + "/cancel"}})
        m = re.match(r"/v1/predictions/([\w-]+)(/cancel)?$", rest)
        if m:
            pid = m.group(1)
            if m.group(2):
                return self.send_json(200, {"id": pid, "status": "canceled"})
            with LOCK:
                c = STATE["polls"].get(pid, 0); STATE["polls"][pid] = c + 1
            if c < 1 or scen == "slow":
                return self.send_json(200, {"id": pid, "status": "processing", "output": None})
            return self.send_json(200, {"id": pid, "status": "succeeded", "output": "http://%s/files/replicate_640x480.png" % self.headers.get("Host")})
        return self.notfound()

    # ---- Black Forest Labs
    def p_bfl(self, method, rest, body, ctype, u, scen):
        if rest == "/v1/credits":
            return self.send_json(200, {"credits": 1234})
        if rest == "/v1/get_result":
            jid = parse_qs(u.query).get("id", [""])[0]
            with LOCK:
                c = STATE["polls"].get(jid, 0)
                if c != "moderated":
                    STATE["polls"][jid] = c + 1
            if c == "moderated":
                return self.send_json(200, {"id": jid, "status": "Content Moderated", "details": {"Moderation Reasons": ["Derivative Works Filter"]}})
            if c < 1 or scen == "slow":
                return self.send_json(200, {"id": jid, "status": "Pending", "progress": 0.4})
            info = STATE["polls"].get(jid + ":info", (640, 480))
            return self.send_json(200, {"id": jid, "status": "Ready", "result": {"sample": "http://%s/files/bfl_%dx%d.png" % (self.headers.get("Host"), info[0], info[1]), "seed": 5}})
        if method == "POST":
            j = json.loads(body or b"{}")
            with LOCK:
                jid = "bfl-%d" % len(LOG); STATE["polls"][jid] = 0
                size = first_png_size_json(j) or (j.get("width") or 640, j.get("height") or 480)
                if "expand" in rest:
                    size = (size[0] + j.get("left", 0) + j.get("right", 0), size[1] + j.get("top", 0) + j.get("bottom", 0))
                STATE["polls"][jid + ":info"] = size
            return self.send_json(200, {"id": jid, "polling_url": self.base("bfl") + "/v1/get_result?id=" + jid, "cost": 5})
        return self.notfound()


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 18777
    srv = ThreadingHTTPServer(("127.0.0.1", port), H)
    print("mock listening on", port, flush=True)
    srv.serve_forever()
