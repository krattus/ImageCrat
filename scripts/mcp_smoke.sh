#!/bin/bash
# Manual smoke test of ImageCrat's local MCP server (docs/MCP.md) with curl.
#
#   1. In ImageCrat: Preferences ▸ Integrations ▸ turn on "Enable the local MCP server" and click Copy next to the token.
#   2. IMAGECRAT_MCP_TOKEN='<paste>' scripts/mcp_smoke.sh [http://127.0.0.1:47800/mcp]
#
# It checks auth, the initialize handshake, tools/list, then creates a small document, adds text, exports a PNG to a
# temporary folder (or $MCP_SMOKE_OUT), closes the document without saving and ends the session. It touches nothing
# else. The token is sent only in the Authorization header (never in a URL). Needs curl and python3 (Xcode command
# line tools). Exit status 0 = all checks passed. The app's `mcp` self test also runs this script.
set -u
URL="${1:-${MCP_URL:-http://127.0.0.1:47800/mcp}}"
TOKEN="${IMAGECRAT_MCP_TOKEN:-}"
if [ -z "$TOKEN" ]; then
    echo "Set IMAGECRAT_MCP_TOKEN to the token from ImageCrat ▸ Preferences ▸ Integrations." >&2
    exit 2
fi
OUT="${MCP_SMOKE_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/imagecrat-mcp-smoke.XXXXXX")}"
mkdir -p "$OUT"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/imagecrat-mcp-curl.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
fails=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1${2:+ — $2}"; fails=$((fails + 1)); }

# json <file> <python expression on d> — prints the value (jq-free fallback)
json() {
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "import json,sys; d=json.load(open(sys.argv[1])); v=($2); print(v if not isinstance(v,(dict,list)) else json.dumps(v))" "$1" 2>/dev/null
    else
        echo "python3 is needed to read the JSON replies" >&2; return 1
    fi
}

SESSION=""
# post <name> <json body> → status in $STATUS, body in $TMP/<name>.json, headers in $TMP/<name>.h
post() {
    local name=$1 body=$2
    local args=(-sS --max-time 120 -o "$TMP/$name.json" -D "$TMP/$name.h" -w '%{http_code}' -X POST "$URL"
                -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream')
    [ -n "$SESSION" ] && args+=(-H "Mcp-Session-Id: $SESSION" -H 'MCP-Protocol-Version: 2025-06-18')
    STATUS=$(curl "${args[@]}" --data-binary "$body")
}
ID=10
tool() {   # tool <name> <arguments json>
    ID=$((ID + 1))
    post "$1" "{\"jsonrpc\":\"2.0\",\"id\":$ID,\"method\":\"tools/call\",\"params\":{\"name\":\"$1\",\"arguments\":$2}}"
}
is_ok() { [ "$STATUS" = 200 ] && [ "$(json "$TMP/$1.json" "d['result']['isError']")" = "False" ]; }

# 1. auth
code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' -X POST "$URL" -H 'Content-Type: application/json' --data-binary '{"jsonrpc":"2.0","id":1,"method":"ping"}')
[ "$code" = 401 ] && pass "no token → 401" || fail "no token → 401" "got $code (is the server on, at $URL?)"

# 2. handshake
post init '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"mcp_smoke.sh","version":"1"}}}'
SESSION=$(grep -i '^mcp-session-id:' "$TMP/init.h" | head -1 | cut -d: -f2 | tr -d ' \r\n')
ver=$(json "$TMP/init.json" "d['result']['protocolVersion']")
[ "$STATUS" = 200 ] && [ "$ver" = 2025-06-18 ] && [ -n "$SESSION" ] && pass "initialize (session ${SESSION:0:8}…)" || fail "initialize" "HTTP $STATUS, version '$ver'"
post initialized '{"jsonrpc":"2.0","method":"notifications/initialized"}'
[ "$STATUS" = 202 ] && pass "notifications/initialized → 202" || fail "notifications/initialized" "HTTP $STATUS"
post ping '{"jsonrpc":"2.0","id":2,"method":"ping"}'
[ "$STATUS" = 200 ] && pass "ping" || fail "ping" "HTTP $STATUS"

# 3. tools
post list '{"jsonrpc":"2.0","id":3,"method":"tools/list"}'
n=$(json "$TMP/list.json" "len(d['result']['tools'])")
[ "${n:-0}" -ge 40 ] && pass "tools/list ($n tools)" || fail "tools/list" "got '$n'"

# 4. a short editing session
tool new_document '{"width":320,"height":200,"background":"#F4F1EA","name":"MCP smoke"}'
DOC=$(json "$TMP/new_document.json" "d['result']['structuredContent']['id']")
is_ok new_document && [ -n "$DOC" ] && pass "new_document" || fail "new_document" "$(cat "$TMP/new_document.json")"
tool add_text "{\"text\":\"Hello from curl\",\"size\":32,\"color\":\"#1B1F3A\",\"position\":{\"x\":20,\"y\":70},\"doc_id\":\"$DOC\"}"
is_ok add_text && pass "add_text" || fail "add_text" "$(cat "$TMP/add_text.json")"
tool render_preview "{\"max_size\":160,\"doc_id\":\"$DOC\"}"
mime=$(json "$TMP/render_preview.json" "d['result']['content'][0]['mimeType']")
[ "$mime" = image/png ] && pass "render_preview returns a PNG" || fail "render_preview" "mimeType '$mime'"
tool export_image "{\"path\":\"$OUT/mcp-smoke.png\",\"doc_id\":\"$DOC\"}"
is_ok export_image && [ -s "$OUT/mcp-smoke.png" ] && pass "export_image → $OUT/mcp-smoke.png" || fail "export_image" "$(cat "$TMP/export_image.json")"
tool get_document_info "{\"bogus\":1,\"doc_id\":\"$DOC\"}"
[ "$(json "$TMP/get_document_info.json" "d['result']['isError']")" = True ] && pass "wrong argument → isError" || fail "wrong argument → isError"
tool close_document "{\"discard_changes\":true,\"doc_id\":\"$DOC\"}"
is_ok close_document && pass "close_document" || fail "close_document" "$(cat "$TMP/close_document.json")"

# 5. end the session
code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' -X DELETE "$URL" -H "Authorization: Bearer $TOKEN" -H "Mcp-Session-Id: $SESSION")
[ "$code" = 204 ] && pass "DELETE ends the session" || fail "DELETE session" "HTTP $code"

if [ $fails -eq 0 ]; then echo "mcp_smoke: all checks passed"; else echo "mcp_smoke: $fails check(s) failed"; fi
[ $fails -eq 0 ]
