# Claude Code / MCP

ImageCrat has a built-in [Model Context Protocol](https://modelcontextprotocol.io) server. With it, Claude Code (or
any other MCP client on the same Mac) can drive the running app: open and create documents, add text, shapes and
layers, apply filters, adjustments and layer styles, paint, run scripts and actions, look at a rendered preview, and
save or export the result. You see every change in the window as it happens, and every call is one undo step
(“MCP: Add Text Layer”) that you can take back with ⌘Z.

The server is **off by default**. It runs inside the app, listens only on `127.0.0.1`, and needs a secret token on
every request.

## Set up Claude Code

1. In ImageCrat, open **Preferences ▸ Integrations** and turn on **Enable the local MCP server**.
   The status line shows `Listening on 127.0.0.1:47800`. If port 47800 is taken, ImageCrat uses another free port
   and shows it there.
2. Click **Copy Claude Code setup command** and paste it into Terminal:

   ```bash
   claude mcp add --transport http imagecrat http://127.0.0.1:47800/mcp --header "Authorization: Bearer <token>"
   ```

   The copied command already contains your port and token. Add `--scope user` after `add` to make the server
   available in every project, not only the current folder.
3. Start Claude Code and type `/mcp`. `imagecrat` should show as connected, with its tools listed.
4. Ask for something, for example:
   - “Make a 1080 × 1080 poster in ImageCrat: dark blue background, the title ‘Night Market’ in a bold font,
     a soft drop shadow, then export it to ~/Desktop/poster.png.”
   - “Open ~/Pictures/beach.jpg, remove the background and save it as a PSD next to the original.”
   - “Show me a preview of the current document and suggest three adjustments.”

While the server is on, a status-bar chip shows `MCP · :47800`. Click it to open Preferences ▸ Integrations.

**Other MCP clients** use the same URL and header. For a project-level `.mcp.json`:

```json
{
  "mcpServers": {
    "imagecrat": {
      "type": "http",
      "url": "http://127.0.0.1:47800/mcp",
      "headers": { "Authorization": "Bearer <token>" }
    }
  }
}
```

The token works like a password, so don't commit it to a repository.

**Regenerate** (Preferences ▸ Integrations) makes a new token, and clients set up with the old one then get
`401 Unauthorized`. Run the copied setup command again to update them: `claude mcp remove imagecrat` first, then add
it again.

## Conventions

- **Coordinates** are document pixels, with the origin at the top-left. Rectangles are `{x, y, width, height}` and
  points are `{x, y}`.
- **Colours** are `"#RRGGBB"` / `"#RRGGBBAA"`, a few names (`"white"`, `"black"`, `"red"` …), or `[r, g, b]` /
  `[r, g, b, a]` with components from 0 to 255.
- **Ids.** Documents and layers have UUID ids. `list_documents` and `get_document_info` list them.
  - Without `doc_id`, a tool acts on the active document.
  - Without `layer_id`, it acts on the active layer.
  - A tool makes the document it works on the active one, so you can see the result.
- **Paths** are absolute (`~` is expanded).
  - Tools can read and write anywhere your user account can.
  - Every file a tool writes is named in the status bar and in the diagnostic log, along with files written by
    `run_script`.
- **Undo.** Each call is one history step called “MCP: <tool title>”, however many commands it ran inside.
  - `undo` and `redo` step through the history.
  - `get_history` lists it.
- **Errors** come back as tool results with `isError: true` and a message that says what to fix, for example
  “No document is open. Use new_document or open_document first.” or ``"`size` must be ≤ 5000 (got 9000)."``.
- While a dialog is open in ImageCrat, editing tools are refused until you close it. Read-only tools still work.
- Calls run one at a time, in order, on the app's main thread.

## Tools

| Group | Tool | What it does |
|---|---|---|
| Documents | `list_documents` | Open documents: id, name, size, path, unsaved changes, active |
| | `new_document` | `width`, `height`, `background` (colour or `"transparent"`), `resolution?`, `name?` |
| | `open_document` | `path`: .imagecrat, PSD/PSB, PNG, JPEG, TIFF, HEIC, WebP, RAW, PDF, SVG … |
| | `save_document` | `path?`, `format?` (imagecrat, psd, png, jpeg, tiff, webp), `quality?`. Without a path it saves to the document's own file |
| | `export_image` | Flattened copy: `path`, `format?` (png, jpeg, tiff, webp, heic, gif, bmp, psd), `quality?`, `size? {width, height}` |
| | `close_document` | `save?` or `discard_changes?`. It refuses to drop unsaved changes silently |
| | `set_active_document` | `doc_id` |
| Inspect | `get_document_info` | Size, colour mode, bit depth, resolution, selection, and the layer tree (top first): ids, kinds, visibility, opacity, blend mode, bounds, effects, text, children |
| | `render_preview` | PNG image of the document or one `layer_id`, fitted to `max_size` (default 1024) |
| | `get_selection` | Whether there is a selection, and its bounds |
| | `get_history` | Undo history and the current step |
| Layers | `add_layer` | `kind`: pixel, text, shape, solid_fill, gradient_fill, adjustment, group (+ that kind's arguments) |
| | `set_layer_properties` | `name`, `visible`, `opacity`, `fill_opacity`, `blend_mode`, `locked`, `clipped`, `position` |
| | `delete_layer`, `duplicate_layer` | By `layer_id` |
| | `move_layer` | `index` among siblings (0 = bottom, −1 = top), `above`, `below` or `into_group` |
| | `group_layers`, `merge_layers` | `layer_ids` |
| | `select_layer` | `layer_id`, `add?` |
| Editing | `list_filters`, `apply_filter` | `name`, `params`, `layer_id?`, `smart?` (editable smart filter) |
| | `list_adjustments`, `apply_adjustment` | `kind`, `params`, `as_layer?` (default true: an adjustment layer) |
| | `set_layer_style` | `drop_shadow`, `inner_shadow`, `outer_glow`, `inner_glow`, `stroke`, `color_overlay`, `gradient_overlay`, `bevel`, `satin` (each is an object of settings or `false`), `clear?` |
| | `transform_layer` | `scale` (% or `{x, y}`), `rotate` (°, clockwise), `translate {x, y}`, `flip` |
| | `make_selection` | `mode`: rect, ellipse, all, none, invert, subject, color_range, layer. Plus `combine`, `feather` |
| | `fill` | `color`, `selection?` (a rect just for this fill), `opacity?`, `blend_mode?` |
| | `crop`, `resize_image`, `resize_canvas` | Canvas geometry |
| | `undo`, `redo` | `steps?` |
| Text & shapes | `add_text`, `edit_text` | `text`, `font`, `size`, `color`, `position`, `alignment`, `box` (paragraph text) |
| | `add_shape` | `kind` (rect, ellipse, polygon, star, line), `bounds`, `fill`, `stroke`, `stroke_width`, `corner_radius`, `sides` |
| | `list_fonts` | `filter?` |
| Brushes | `list_brushes`, `paint_stroke` | `points [{x, y, pressure?}]`, `brush?`, `size?`, `hardness?`, `opacity?`, `color?`, `erase?`, `layer_id?` |
| Automation | `list_actions`, `run_action` | Recorded actions from the Actions panel |
| | `run_script` | `js`: JavaScript using the scripting API (below) |
| AI | `remove_background`, `select_subject` | On-device subject detection. Nothing leaves the Mac |
| | `generative_fill` | **Paid, cloud.** Refused unless you allow it (see Security) |

`tools/list` gives each tool's full JSON Schema and description. Tool names, schemas and messages are in English.
They are meant for the model, not shown in the app's interface.

### Examples

```jsonc
// a poster in five calls
{"name": "new_document", "arguments": {"width": 1080, "height": 1350, "background": "#14213D"}}
{"name": "add_text", "arguments": {"text": "Night Market", "font": "Avenir Next", "size": 140, "color": "#FCA311",
                                   "position": {"x": 80, "y": 900}, "box": {"width": 920, "height": 360}}}
{"name": "set_layer_style", "arguments": {"drop_shadow": {"distance": 12, "size": 24, "opacity": 60}}}
{"name": "apply_adjustment", "arguments": {"kind": "hueSaturation", "params": {"saturation": 15}}}
{"name": "export_image", "arguments": {"path": "/Users/me/Desktop/poster.png", "size": {"width": 1080}}}

// filters take their parameter keys from list_filters
{"name": "apply_filter", "arguments": {"name": "gaussianBlur", "params": {"radius": 8}, "smart": true}}
{"name": "apply_filter", "arguments": {"name": "Unsharp Mask", "params": {"amount": 80, "radius": 1.5}}}

// selections, fill and painting
{"name": "make_selection", "arguments": {"mode": "ellipse", "rect": {"x": 100, "y": 100, "width": 300, "height": 300}, "feather": 4}}
{"name": "fill", "arguments": {"color": "#E63946", "layer_id": "…"}}
{"name": "paint_stroke", "arguments": {"points": [{"x": 50, "y": 50, "pressure": 0.2}, {"x": 400, "y": 120, "pressure": 1}],
                                       "size": 24, "color": "#1D3557"}}

// anything the tools don't cover: the scripting API
{"name": "run_script", "arguments": {"js": "const d = app.activeDocument; d.layers.map(l => l.name)"}}
```

### Scripting API (run_script)

`run_script` runs JavaScript in the same engine as File ▸ Scripts. Its result is the value of the last expression plus
any `console.log` output.

- `app`: `documents`, `activeDocument`, `open(path)`, `newDocument(w, h, name, {background, resolution})`,
  `filters()`, `adjustments()`, `foregroundColor`, `backgroundColor`, `listFiles(folder, exts)`, `readFile(path)`,
  `writeFile(path, text)`.
- `Document`: `layers`, `allLayers`, `activeLayer`, `selection`, `addLayer`, `addGroup`, `addTextLayer`,
  `addShape`, `addAdjustmentLayer`, `placeFile`, `applyFilter`, `flatten`, `mergeVisible`, `resizeImage`,
  `resizeCanvas`, `rotateCanvas`, `flipCanvas`, `undo`, `redo`, `duplicate`, `save`, `exportAs`, `close`.
- `Layer`: `name`, `visible`, `opacity`, `fillOpacity`, `blendMode`, `kind`, `bounds`, `text`, `setTextStyle`,
  `translate`, `rotate`, `resize`, `duplicate`, `remove`, `applyFilter`, `adjust`, `rasterize`, `moveAbove`,
  `moveBelow`, `select`, `fill`.
- `Selection`: `selectAll`, `deselect`, `rect`, `ellipse`, `invert`, `bounds`, `fill`.

The tool's description has the full signatures. Calls to `alert`, `prompt` and `confirm` don't block: they are only
logged. A script runs on the app's main thread until it finishes, so don't write endless loops.

## Security

- **Off by default.** Nothing listens until you turn the server on. Turning it off stops the listener and closes
  open connections.
- **This Mac only.** The server is bound to the loopback interface `127.0.0.1`, so other computers can't reach it.
- **A token on every request.** Each request needs `Authorization: Bearer <token>` and gets `401` without it.
  - The token is 32 random bytes, stored in the macOS Keychain under its own item, and compared in constant time.
  - **Regenerate** replaces it.
  - The app never logs it.
- **No browsers.** Web pages can't use the server, even through DNS rebinding:
  - a request that carries an `Origin` header is refused with `403`;
  - so is a `Host` other than `127.0.0.1`, `localhost` or `[::1]`;
  - there are no CORS headers.
- **Your API keys stay private.** No tool can read your generative AI keys (fal.ai and the others) or any other
  secret.
  - The keys stay in the Keychain, and the scripting API has no access to them.
  - No tool changes ImageCrat's preferences.
- **Paid generative AI is opt-in.** `generative_fill` calls a paid cloud provider, so it is refused until you turn
  on **Allow paid generative AI calls from MCP**.
  - Even then, ImageCrat asks you to confirm each call and shows the estimated cost.
  - **Don't ask again for MCP** turns off that confirmation.
  - Your monthly budget limits still apply.
  - `remove_background` and `select_subject` run on the Mac.
- **Files.** Tools can read and write anywhere your user account can, like a script you run yourself. Every file a
  tool or a tool-run script writes is listed in the status bar, in Preferences ▸ Integrations (“Last file written”)
  and in the diagnostic log (Help ▸ Report a Bug…). Only connect clients you trust: a client that can write files
  anywhere can also overwrite your own files.
- **What clients can't do.** Clients can't run shell commands directly. They can't install anything or open the
  app's dialogs. Closing a document with unsaved changes needs an explicit `save` or `discard_changes`.
- **Automated runs** (self tests, `LUMEN_AUTOMATION`) never read or write the real Keychain item or the preferences:
  they use an in-memory token.

## Protocol details

The server uses the MCP **Streamable HTTP** transport at `POST http://127.0.0.1:<port>/mcp`. Replies are single JSON
objects (`application/json`). It doesn't use server-sent events.

It speaks both protocol eras:

- **Session-based** (`2025-11-25`, `2025-06-18`, `2025-03-26`, `2024-11-05`; this is what Claude Code uses today):
  1. `initialize` negotiates the version. If the server supports the client's version, it uses it; otherwise it
     answers with `2025-11-25`.
  2. The reply carries an `Mcp-Session-Id` header, which the client sends back with every later request.
  3. Then `notifications/initialized` (answered with `202`), `ping`, `tools/list` and `tools/call`.
  4. `DELETE` with the session id ends the session.
  5. Batches (JSON arrays) are accepted.
- **Stateless** (`2026-07-28`):
  - Every request carries `_meta["io.modelcontextprotocol/protocolVersion"]`. That request is served without a
    session.
  - The `MCP-Protocol-Version`, `Mcp-Method` and `Mcp-Name` headers must match the body. If they don't, the reply is
    `400` with `-32020 HeaderMismatch`.
  - An unknown version gets `400` with `-32022` and the list of supported versions.
  - `server/discover` is available.
- `GET` gets `405`, because there's no standalone event stream.

Errors:

| Error | Reply |
|---|---|
| Malformed JSON | `400` with `-32700` |
| Unknown method | `-32601` |
| Unknown tool | `-32602` (a protocol error) |
| Wrong arguments, or a failing tool | A normal result with `isError: true` and a message the model can act on |
| Missing or wrong token | `401` |
| Browser `Origin` or foreign `Host` | `403` |

### curl

```bash
TOKEN='<token>'; URL=http://127.0.0.1:47800/mcp
H=(-H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream')

# handshake: note the Mcp-Session-Id response header
curl -si "${H[@]}" "$URL" -d '{"jsonrpc":"2.0","id":1,"method":"initialize",
  "params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"1"}}}'
SID='<Mcp-Session-Id from above>'
curl -s "${H[@]}" -H "Mcp-Session-Id: $SID" "$URL" -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'

curl -s "${H[@]}" -H "Mcp-Session-Id: $SID" "$URL" -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
curl -s "${H[@]}" -H "Mcp-Session-Id: $SID" "$URL" -d '{"jsonrpc":"2.0","id":3,"method":"tools/call",
  "params":{"name":"new_document","arguments":{"width":800,"height":600,"background":"#FFFFFF"}}}'
```

A reply to a tool call looks like this:

```json
{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"Created “Untitled” (800 × 600 px).\n{…}"}],
 "structuredContent":{"id":"6F1C…","width":800,"height":600,"layers":[…]},"isError":false}}
```

`scripts/mcp_smoke.sh` runs a short session like this against a running app:

```bash
IMAGECRAT_MCP_TOKEN='<token>' scripts/mcp_smoke.sh http://127.0.0.1:47800/mcp
```

It checks auth and the handshake, creates a document, exports a PNG to a temporary folder and closes the document
again.

## Troubleshooting

- **`/mcp` shows “failed”.** Check that ImageCrat is running and that the server is on: the status line says
  “Listening on …”. Also check that the port in the command matches the one shown there. Copy the setup command
  again if ImageCrat had to switch to another port.
- **401 Unauthorized.** The token changed (Regenerate), or the header is missing. Remove the server
  (`claude mcp remove imagecrat`) and add it again with a freshly copied command.
- **403 Forbidden.** The request came from a web page (it carried an `Origin` header) or used a hostname other than
  `127.0.0.1` / `localhost`.
- **“ImageCrat has a dialog open”.** Close the dialog in the app and try again.

## For developers

| Layer | Where | What |
|---|---|---|
| Protocol | `Sources/ImageCratCore/MCP` (Foundation only) | `MCPEndpoint`: JSON-RPC, both protocol eras, sessions, auth, Origin and Host checks. `MCPSchema` / `MCPSchemaValidator`: schema builders, argument validation, schema checks. `MCPHTTP`: HTTP/1.1 parsing |
| App | `Sources/Lumen/MCP` | `MCPServer.swift`: the Network.framework loopback listener, settings, the Keychain token and status. `MCPTools*.swift`: tool definitions, which reuse `AppActions`, `ScriptAPI`, the filter catalog, `DocumentIO` and the brush engine. `MCPModule.swift`: the Preferences pane and the status chip |

The tests:

- `swift test --filter MCPProtocolTests` tests the protocol logic.
- `LUMEN_SELFTEST_ONLY=mcp .build/debug/Lumen --selftest <dir>` starts the real server on an ephemeral port with an
  in-memory token. It talks to the server over loopback HTTP: handshake, auth, Origin, errors, every tool's schema,
  and an editing session with undo/redo, save/reopen and export. It also runs `scripts/mcp_smoke.sh`.
- `LUMEN_MCP_EXTERNAL_CHECK='<command>'` also runs another client, such as a Node script using the official MCP
  SDK, against the test server. The command gets `MCP_URL` and `IMAGECRAT_MCP_TOKEN`.
