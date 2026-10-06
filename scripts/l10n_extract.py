#!/usr/bin/env python3
"""Finds every user-facing string of ImageCrat in the Swift sources.

    scripts/l10n_extract.py [--out Localization/strings-en.json] [--report]

Scans Sources/Lumen (the app) and the display catalogues of Sources/ImageCratCore (filter / adjustment / blend-mode /
effect names and parameter labels) and writes Localization/strings-en.json:

    {"strings": [{"key": "Gaussian Blur", "english": "Gaussian Blur", "contexts": ["Filters/…swift:12 displayName"]}, …]}

The key is the English text as the app looks it up: string interpolations become "%@" (and a literal "%" in an
interpolated string "%%"), exactly as `tr("…\\(x)…")` and SwiftUI's LocalizedStringKey build it.

What counts as user-facing (see RULES below):
  - SwiftUI: the first argument of Text / Button / Label / Toggle / Picker / Menu / Section / TextField / …, .help(),
    .navigationTitle(), .accessibilityLabel(), CommandMenu();
  - tr("…"), NSLocalizedString("…");
  - AppKit: NSAlert messageText / informativeText / addButton(withTitle:), NSMenuItem(title:), tool tips, panel
    messages and prompts, button titles and labels;
  - labelled arguments named title:, label:, help:, message:, subtitle:, tooltip:, placeholder:, … of any call;
  - MenuRegistry.add(menu, title, submenu:) (menu paths are split at "/");
  - display properties: `var displayName / title / menuTitle / label / help / tooltip / subtitle / … : String { … }`
    (catalogues, also in the core), `errorDescription`;
  - raw values of String enums that read like text ("Medium Gray", "Pixels");
  - arrays of names (`sections`, `titles`, `l10nKeys`, `.choice([...])`);
  - helpers of this app whose String parameter ends up in one of the above (found automatically: `ValueSlider(label:)`,
    `Toggle2(label:)`, `PanelHeader("…")` …), setStatus(), AppActions.alert(), history step names (commit("…")).
Not extracted: self tests and QA code, print / log output, user content, scripting API names, PSD keys.

New files (another feature's panels and dialogs) are picked up automatically.
"""
import json
import os
import re
import sys
from collections import defaultdict

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))

# ----------------------------------------------------------------------------------------------------------------------
# Lexer: string literals (with interpolations), comments, and a "masked" copy of the code in which string contents and
# comments are blanked (quotes kept) so brackets can be matched on it.
# ----------------------------------------------------------------------------------------------------------------------

class Lit:
    __slots__ = ("start", "end", "line", "parts", "multiline", "raw", "nested", "text")

    def __init__(self, start, line, multiline, raw, nested):
        self.start = start
        self.end = start
        self.line = line
        self.parts = []       # ("lit", text) | ("expr", code)
        self.multiline = multiline
        self.raw = raw
        self.nested = nested
        self.text = None


ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "0": "\0", '"': '"', "'": "'", "\\": "\\"}


def lex(src):
    n = len(src)
    masked = list(src)
    lits = []
    line_starts = [0]
    for i, c in enumerate(src):
        if c == "\n":
            line_starts.append(i + 1)

    import bisect

    def line_of(pos):
        return bisect.bisect_right(line_starts, pos)

    def blank(a, b):
        for k in range(a, b):
            if masked[k] != "\n":
                masked[k] = " "

    def skip_comment(i):
        # returns index after a comment starting at i, or i if none
        if src.startswith("//", i):
            j = src.find("\n", i)
            j = n if j < 0 else j
            blank(i, j)
            return j
        if src.startswith("/*", i):
            depth = 0
            j = i
            while j < n:
                if src.startswith("/*", j):
                    depth += 1
                    j += 2
                elif src.startswith("*/", j):
                    depth -= 1
                    j += 2
                    if depth == 0:
                        break
                else:
                    j += 1
            blank(i, j)
            return j
        return i

    def string_start(i):
        # returns (hashes, multiline, content_start) if a string literal starts at i
        j = i
        while j < n and src[j] == "#":
            j += 1
        hashes = j - i
        if j < n and src[j] == '"':
            if src.startswith('"""', j):
                return hashes, True, j + 3
            return hashes, False, j + 1
        return None

    def parse_code(i, end_char, nested):
        # code until the matching end_char (for interpolations); returns index of end_char
        depth = 0
        while i < n:
            c = src[i]
            k = skip_comment(i)
            if k != i:
                i = k
                continue
            if c == "#" or c == '"':
                st = string_start(i)
                if st is not None and (c == '"' or True):
                    # (a lone # is a directive / raw-string start; only treat as string if a quote follows)
                    i = parse_string(i, st, nested=True)
                    continue
            if c in "([{":
                depth += 1
            elif c in ")]}":
                if depth == 0 and c == end_char:
                    return i
                depth -= 1
            i += 1
        return i

    def parse_string(i, st, nested):
        hashes, multi, j = st
        lit = Lit(i, line_of(i), multi, hashes > 0, nested)
        close = ('"""' if multi else '"') + "#" * hashes
        esc = "\\" + "#" * hashes
        buf = []
        while j < n:
            if src.startswith(close, j):
                if buf:
                    lit.parts.append(("lit", "".join(buf)))
                j += len(close)
                break
            if src.startswith(esc, j):
                k = j + len(esc)
                c = src[k] if k < n else ""
                if c == "(":
                    if buf:
                        lit.parts.append(("lit", "".join(buf)))
                        buf = []
                    e = parse_code(k + 1, ")", nested=True)
                    lit.parts.append(("expr", src[k + 1:e]))
                    j = e + 1
                    continue
                if c == "u" and k + 1 < n and src[k + 1] == "{":
                    e = src.find("}", k)
                    try:
                        buf.append(chr(int(src[k + 2:e], 16)))
                    except ValueError:
                        pass
                    j = e + 1
                    continue
                if multi and c == "\n":   # line continuation
                    j = k + 1
                    continue
                if c in ESCAPES:
                    buf.append(ESCAPES[c])
                    j = k + 1
                    continue
                buf.append(src[j])
                j += 1
                continue
            if not multi and src[j] == "\n":   # unterminated: give up on this line
                break
            buf.append(src[j])
            j += 1
        lit.end = j
        if multi:
            lit.parts = dedent_multiline(lit.parts, src, i, j, len(close))
        lits.append(lit)
        # mask the literal's inside (keep the delimiters' positions as quotes so tokens stay apart)
        blank(i, j)
        masked[i] = '"'
        if j - 1 > i:
            masked[j - 1] = '"'
        return j

    i = 0
    while i < n:
        k = skip_comment(i)
        if k != i:
            i = k
            continue
        c = src[i]
        if c == '"' or (c == "#" and i + 1 < n and src[i + 1] in '#"'):
            st = string_start(i)
            if st is not None:
                i = parse_string(i, st, nested=False)
                continue
        i += 1
    return lits, "".join(masked), line_of


def dedent_multiline(parts, src, start, end, close_len):
    # indentation of the closing delimiter line
    close_pos = end - close_len
    ls = src.rfind("\n", 0, close_pos) + 1
    indent = src[ls:close_pos]
    if indent.strip():
        indent = ""
    out = []
    first = True
    for kind, text in parts:
        if kind == "lit":
            if first and text.startswith("\n"):
                text = text[1:]
            lines = text.split("\n")
            text = "\n".join(l[len(indent):] if l.startswith(indent) else l for l in lines)
        out.append((kind, text))
        first = False
    if out and out[-1][0] == "lit" and out[-1][1].endswith("\n"):
        out[-1] = ("lit", out[-1][1][:-1])
    return out


def literal_key(lit):
    """The lookup key: interpolations → %@, and a literal % → %% when the string has interpolations."""
    has_expr = any(k == "expr" for k, _ in lit.parts)
    out = []
    for k, t in lit.parts:
        if k == "lit":
            out.append(t.replace("%", "%%") if has_expr else t)
        else:
            out.append("%@")
    return "".join(out)


# ----------------------------------------------------------------------------------------------------------------------
# Context of a literal in the masked code
# ----------------------------------------------------------------------------------------------------------------------

IDENT_CHAIN = re.compile(r"((?:[A-Za-z_][A-Za-z0-9_]*\s*(?:\?|!)?\s*\.\s*)*\.?\s*[A-Za-z_][A-Za-z0-9_]*)\s*(?:<[^<>()]*>)?\s*$")


def enclosing_open(masked, pos, limit=6000):
    """Index of the unmatched ( [ { before pos (or -1)."""
    depth = 0
    i = pos - 1
    lo = max(0, pos - limit)
    while i >= lo:
        c = masked[i]
        if c in ")]}":
            depth += 1
        elif c in "([{":
            if depth == 0:
                return i
            depth -= 1
        i -= 1
    return -1


def callee_before(masked, paren):
    m = IDENT_CHAIN.search(masked[max(0, paren - 200):paren])
    if not m:
        return None
    chain = re.sub(r"\s+", "", m.group(1))
    return chain


def arg_info(masked, paren, pos):
    """(index, label) of the argument at pos inside the call whose ( is at paren."""
    depth = 0
    idx = 0
    seg_start = paren + 1
    i = paren + 1
    while i < pos:
        c = masked[i]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif c == "," and depth == 0:
            idx += 1
            seg_start = i + 1
        i += 1
    seg = masked[seg_start:pos]
    m = re.match(r"\s*([A-Za-z_][A-Za-z0-9_]*)\s*:(?!:)", seg)
    label = m.group(1) if m else None
    # a ternary's ":" is not a label: "a ? b : c" — labels come first in the segment
    if label and re.match(r"\s*[A-Za-z_][A-Za-z0-9_]*\s*\?", seg):
        label = None
    return idx, label, seg


def statement_before(masked, pos):
    """Code between the start of the statement and pos (same bracket level)."""
    i = pos - 1
    depth = 0
    while i >= 0:
        c = masked[i]
        if c in ")]}":
            depth += 1
        elif c in "([{":
            if depth == 0:
                break
            depth -= 1
        elif c in ";\n" and depth == 0:
            # a statement can continue on the next line after an operator; good enough for our purposes
            j = i - 1
            while j >= 0 and masked[j] in " \t":
                j -= 1
            if j >= 0 and masked[j] in "=+?:,&|(":
                i -= 1
                continue
            break
        i -= 1
    return masked[i + 1:pos]


DECL_RE = re.compile(r"(?:(?:static|class|private|fileprivate|public|package|internal|override|final|nonisolated|@\w+(?:\([^)]*\))?)\s+)*"
                     r"(?:var|let|func)\s+([A-Za-z_][A-Za-z0-9_]*)[^{=]*$", re.S)


def enclosing_decl(masked, pos):
    """Name of the innermost `var NAME …{` / `func NAME(…) {` whose body contains pos (skips closures / switch / if)."""
    p = pos
    for _ in range(12):
        o = enclosing_open(masked, p, limit=20000)
        if o < 0:
            return None, None
        if masked[o] == "{":
            head = masked[max(0, o - 400):o]
            # cut at the previous statement boundary
            cut = max(head.rfind("}"), head.rfind(";"), head.rfind("{"))
            h = head[cut + 1:]
            m = DECL_RE.search(h)
            if m and re.search(r"\b(var|func|let)\b", h):
                kind = "func" if re.search(r"\bfunc\b", h) else "var"
                return m.group(1), (kind, h)
        p = o
    return None, None


# ----------------------------------------------------------------------------------------------------------------------
# Rules
# ----------------------------------------------------------------------------------------------------------------------

# first positional argument of these is shown
UI_CALLS = {
    "Text", "Button", "Label", "Toggle", "Picker", "Menu", "Section", "TextField", "SecureField", "Stepper", "LabeledContent",
    "DisclosureGroup", "GroupBox", "Link", "ProgressView", "ColorPicker", "DatePicker", "CommandMenu", "ControlGroup",
    "Tab", "MenuButton", "PasteButton", "ShareLink",
    "help", "navigationTitle", "accessibilityLabel", "accessibilityHint", "accessibilityValue", "alert", "confirmationDialog", "badge",
    "tr", "NSLocalizedString", "setAccessibilityLabel", "setAccessibilityHelp", "setAccessibilityTitle",
    "setStatus", "status", "flash", "toast", "showStatus", "notify",
}
# every positional argument
UI_CALLS_ALL_ARGS = {"alert", "tr"}
# labelled arguments that are shown, whatever the call
UI_LABELS = {
    "title", "label", "help", "message", "subtitle", "tooltip", "toolTip", "placeholder", "prompt", "hint", "caption", "info",
    "full", "compact", "tiny",   # status-bar chip labels (StatusChipSpec)
    "header", "footer", "heading", "buttonTitle", "confirmTitle", "okTitle", "cancelTitle", "informativeText", "messageText",
    "explanation", "summary", "menuTitle", "shortTitle", "displayName", "withTitle", "labelWithString", "wrappingLabelWithString",
    "checkboxWithTitle", "radioButtonWithTitle", "detail", "details", "note", "warning", "question", "emptyText", "emptyMessage",
    "commitName", "actionName", "historyName", "stepName", "undoName", "unit", "suffix", "prefix", "trailing", "leading",
    "description", "why", "what", "reason", "status", "statusText", "titleOn", "titleOff", "onTitle", "offTitle", "confirm",
    "lowLabel", "highLabel", "minLabel", "maxLabel", "leftLabel", "rightLabel", "sectionTitle", "groupTitle", "categoryTitle",
    "placeholderText", "emptyTitle", "doneTitle", "actionTitle", "primary", "secondary", "accessibility", "caption2",
}
# labels that are never text (even in a UI call)
NON_UI_LABELS = {"systemImage", "image", "symbol", "icon", "id", "key", "identifier", "named", "systemName", "selection", "value",
                 "format", "font", "name", "text", "url", "path", "ext", "fileExtension", "domain", "suite", "forKey", "keyPath",
                 "tag", "kind", "type", "style", "category", "group", "menu", "pattern", "separator", "with", "of", "by", "in", "at",
                 "options", "into", "from", "to", "forType", "ofType", "withExtension", "subdirectory", "localization", "table",
                 "tableName", "bundle", "comment", "verbatim", "specifier", "attribute", "forAttribute", "action", "selector"}
# assignments `x.NAME = "…"`
UI_ASSIGN = {"messageText", "informativeText", "toolTip", "title", "message", "prompt", "placeholderString", "stringValue",
             "nameFieldLabel", "statusMessage", "label", "help", "subtitle", "headerText", "placeholder", "accessibilityLabelText",
             "helpText", "hint", "caption", "detail", "status"}
# display properties `var NAME: String { … }` (also computed in switches)
UI_PROPS = {"displayName", "title", "menuTitle", "shortTitle", "label", "help", "helpText", "tooltip", "toolTip", "hint",
            "subtitle", "caption", "summary", "explanation", "message", "heading", "placeholder", "kindName", "errorDescription",
            "failureReason", "recoverySuggestion", "localizedDescription", "statusText", "detailText", "longTitle", "shortName",
            "displayTitle", "buttonTitle", "paletteTitle", "menuName", "sectionTitle", "headline", "blurb", "tip", "tips",
            "userMessage", "uiName", "uiTitle", "niceName", "prettyName", "readable", "humanName", "noun", "verb", "titleText",
            "longName", "longDescription", "short", "abbreviation", "unitLabel", "unitName", "categoryName", "groupName",
            "familyName", "presetName", "description2", "name", "names", "titles", "labels", "options", "choices",
            "descriptionText", "infoText", "note", "warning", "emptyText", "emptyMessage", "body"}
# properties named like this count only when they are computed from a switch / literal list (not "var name = …" data)
WEAK_PROPS = {"name", "names", "short", "body", "options", "choices", "verb", "noun", "note", "warning", "tips"}
# arrays of shown names
UI_ARRAY_NAMES = re.compile(r"(?i)^(l10nKeys|.*(titles|labels|sections|headings|hints|captions|choices|names|options|items|steps|tips|categories|presets|modes|columns|messages))$")
UI_ARRAY_CALLS = {"choice", "options", "segments", "SegmentedPicker", "Segmented", "MiniSegmented", "segmented"}

DEFAULT_NAME_TYPES = {"BrushPreset", "BrushRecord", "ColorGradient", "TextureGen", "LibraryShape", "DocPreset", "RecordedAction", "Workspace",
                      "ActionSet", "SocialFormat", "DuotoneInk", "Preset", "ParticlePreset", "StylePreset", "ToolPreset", "Swatch",
                      "SwatchGroup", "PatternPreset", "ShapePreset", "LookPreset", "RecipePreset"}

LOG_CALLS = {"print", "debugPrint", "NSLog", "os_log", "log", "logger", "note", "warning", "error", "debug", "info", "notice",
             "fault", "trace", "fatalError", "precondition", "preconditionFailure", "assert", "assertionFailure", "check", "say",
             "FuzzLog", "DiagLog", "record", "expect", "fail", "report", "write", "append", "appendLine", "emit", "line",
             "logLine", "dump", "trace2", "perf", "measure", "QA", "scenario", "require", "verbose", "breadcrumb"}

SKIP_FILE = re.compile(r"(SelfTest|Selftest|TestCorpus|TestBuilder|/QA/|Tests?/|PerfTest|FixtureS?|Fixtures|Samples\.swift|Synthetic|Corpus|WebExport/Engine/)")
CORE_ROOT = "Sources/ImageCratCore"
# The MCP server's tools, protocol and errors are read by the model (MCP clients) and stay English: in these files only
# text wrapped in tr() (alerts and status shown to the user) is user-facing.
TR_ONLY_FILE = re.compile(r"(Sources/Lumen/MCP/MCPTools[^/]*\.swift|Sources/Lumen/MCP/MCPServer\.swift|Sources/ImageCratCore/MCP/)")
APP_ROOT = "Sources/Lumen"

TEXTY = re.compile(r"[A-Za-z]")


def strip_specs(s):
    return re.sub(r"%(\d+\$)?[-+ #0]*\d*(\.\d+)?(ll|l|h|hh|q|z|t|j)?[@dDiuUxXoOfFeEgGcCsSp]|%%", "", s)


def is_texty(s):
    """Has letters outside format specifiers, and does not look like an identifier / key / path / code."""
    t = strip_specs(s)
    if not TEXTY.search(t):
        return False
    st = t.strip()
    if not st:
        return False
    if re.fullmatch(r"[a-z]+[A-Z][A-Za-z0-9]*", st):                 # camelCase identifier
        return False
    if re.fullmatch(r"[A-Za-z0-9_]+(\.[A-Za-z0-9_]+){1,}", st):        # dotted id / file name / bundle id
        return False
    if re.fullmatch(r"[a-z0-9]+(_[a-z0-9]+)+", st):                     # snake_case
        return False
    if re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)+", st) and len(st) > 12:    # kebab ids
        return False
    if st.startswith(("http://", "https://", "/", "~/", "#", "{", "<", "x-", "public.", "com.", "app.", "org.", "NS", "CI", "AX")) and " " not in st:
        return False
    if re.fullmatch(r"[A-Z]{2,}[a-z]*\d*", st) and len(st) <= 6:        # RGB, CMYK, PNG …
        return True
    return True


def looks_like_display(s):
    """Stricter: for literals in non-UI positions (enum raw values, arrays): Title Case words or a sentence."""
    if not is_texty(s):
        return False
    st = strip_specs(s).strip()
    if " " in st:
        return bool(re.search(r"[A-Za-z]{2}", st))
    return bool(re.fullmatch(r"[A-Z][a-z]+[a-z0-9]*[…]?|[A-Z][a-z]+(/[A-Z][a-z]+)+|[A-Z]{1,5}|[A-Z][a-z]+-[A-Z]?[a-z]+", st))


# ----------------------------------------------------------------------------------------------------------------------
# Helper discovery: functions / views of the app whose String parameter is shown
# ----------------------------------------------------------------------------------------------------------------------

PARAM_RE = re.compile(r"(?:^|,)\s*(?:@\w+\s+)?(_|[A-Za-z_][A-Za-z0-9_]*)?\s*([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(?:@escaping\s+)?(String\??|LocalizedStringKey|L10nString|Substring|StringProtocol)\b")


def find_blocks(masked, header_re):
    """(name, params_text, body_start, body_end) for each match whose header is followed by a { … } body."""
    out = []
    for m in header_re.finditer(masked):
        o = masked.find("{", m.end())
        if o < 0:
            continue
        # the header must end right before {
        between = masked[m.end():o]
        if ";" in between or "\n\n" in between:
            continue
        depth = 0
        j = o
        L = len(masked)
        while j < L:
            c = masked[j]
            if c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        out.append((m, o, j))
    return out


def split_params(text):
    """Top-level comma split of a parameter list."""
    out, depth, cur = [], 0, []
    for c in text:
        if c in "([{<":
            depth += 1
        elif c in ")]}>":
            depth -= 1
        if c == "," and depth == 0:
            out.append("".join(cur))
            cur = []
        else:
            cur.append(c)
    if cur:
        out.append("".join(cur))
    return out


def param_list(masked, open_paren):
    depth = 0
    j = open_paren
    while j < len(masked):
        c = masked[j]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                break
        j += 1
    return masked[open_paren + 1:j], j


SHOW_USE = None


def shows(body, name, helpers):
    """Whether `name` (a parameter / property) is displayed in `body` (masked code)."""
    n = re.escape(name)
    calls = "|".join(sorted(UI_CALLS | {"Text", "tr"}))
    pats = [
        rf"\b(?:{calls})\(\s*(?:tr\(\s*)?(?:self\.)?{n}\b(?!\s*\.)(?!\s*\()",
        rf"\b(?:{calls})\(\s*(?:tr\(\s*)?(?:self\.)?{n}\s*\?\?",
        rf"\b(?:{'|'.join(sorted(UI_ASSIGN))})\s*=\s*(?:tr\(\s*)?(?:self\.)?{n}\b(?!\s*\.)",
        rf"\b(?:{'|'.join(sorted(UI_LABELS - NON_UI_LABELS))})\s*:\s*(?:tr\(\s*)?(?:self\.)?{n}\b(?!\s*\.)(?!\s*\()",
        rf"\bText\(\s*(?:tr\(\s*)?(?:self\.)?{n}\s*\+",
    ]
    for p in pats:
        if re.search(p, body):
            return True
    # passed on to another helper that shows it
    for h, spec in helpers.items():
        for pos in spec["pos"]:
            if pos == 0 and re.search(rf"\b{re.escape(h)}\(\s*(?:tr\(\s*)?(?:self\.)?{n}\b(?!\s*\.)", body):
                return True
        for lab in spec["labels"]:
            if re.search(rf"\b{re.escape(h)}\([^()]*\b{re.escape(lab)}\s*:\s*(?:tr\(\s*)?(?:self\.)?{n}\b(?!\s*\.)", body):
                return True
    return False


def discover_helpers(files):
    """{name: {"pos": set(indices), "labels": set(labels)}} for app functions / views that show a String parameter."""
    helpers = {}
    struct_re = re.compile(r"\b(?:struct|class|enum|final\s+class)\s+([A-Z][A-Za-z0-9_]*)[^{;]*$", re.M)
    func_re = re.compile(r"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?:<[^>]*>)?\s*\(")
    init_re = re.compile(r"\binit\s*\??\s*(?:<[^>]*>)?\s*\(")
    parsed = []
    for path, masked in files:
        parsed.append((path, masked))
    for _round in range(4):
        changed = False
        for path, masked in parsed:
            # structs: stored String properties shown in the body → memberwise label
            for m in re.finditer(r"\b(?:struct|final class|class)\s+([A-Z][A-Za-z0-9_]*)\b[^{;\n]*\{", masked):
                name = m.group(1)
                o = m.end() - 1
                depth = 0
                j = o
                while j < len(masked):
                    if masked[j] == "{":
                        depth += 1
                    elif masked[j] == "}":
                        depth -= 1
                        if depth == 0:
                            break
                    j += 1
                body = masked[o:j]
                # only properties at the struct's own level
                props = []
                d = 0
                k = 0
                lines = []
                for c in body[1:]:
                    pass
                for pm in re.finditer(r"(?m)^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:private\s+|fileprivate\s+|package\s+)?(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(String\??|LocalizedStringKey)\s*(?:=\s*\"[^\n]*)?$", body):
                    props.append(pm.group(1))
                if not props:
                    continue
                spec = helpers.setdefault(name, {"pos": set(), "labels": set(), "files": set()})
                spec["files"].add(path)
                for p in props:
                    if p in spec["labels"]:
                        continue
                    if shows(body, p, helpers):
                        spec["labels"].add(p)
                        changed = True
                # custom inits mapping positional / labelled params onto shown properties
                for im in init_re.finditer(body):
                    params, close = param_list(body, im.end() - 1)
                    for idx, prm in enumerate(split_params(params)):
                        pm = re.match(r"\s*(?:@\w+\s+)?(_|[A-Za-z_][A-Za-z0-9_]*)?\s*([A-Za-z_][A-Za-z0-9_]*)?\s*:\s*(?:@escaping\s+)?(String\??|LocalizedStringKey|L10nString)\b", prm)
                        if not pm:
                            continue
                        ext, internal = pm.group(1), pm.group(2) or pm.group(1)
                        ib = body[close:close + 3000]
                        target_shown = any(re.search(rf"(?:self\.)?{re.escape(p)}\s*=\s*(?:tr\()?{re.escape(internal)}\b", ib) for p in spec["labels"]) or shows(ib[:1500], internal, helpers)
                        if target_shown:
                            if ext == "_":
                                if idx not in spec["pos"]:
                                    spec["pos"].add(idx); changed = True
                            else:
                                if ext not in spec["labels"]:
                                    spec["labels"].add(ext); changed = True
                if not spec["pos"] and not spec["labels"]:
                    helpers.pop(name, None)
            # functions
            for fm in func_re.finditer(masked):
                name = fm.group(1)
                if name in ("body", "makeNSView", "updateNSView"):
                    continue
                params, close = param_list(masked, fm.end() - 1)
                o = masked.find("{", close)
                if o < 0 or ";" in masked[close:o] or "\n\n" in masked[close:o]:
                    continue
                depth = 0
                j = o
                while j < len(masked):
                    if masked[j] == "{":
                        depth += 1
                    elif masked[j] == "}":
                        depth -= 1
                        if depth == 0:
                            break
                    j += 1
                body = masked[o:j]
                for idx, prm in enumerate(split_params(params)):
                    pm = re.match(r"\s*(?:@\w+\s+)?(_|[A-Za-z_][A-Za-z0-9_]*)?\s*([A-Za-z_][A-Za-z0-9_]*)?\s*:\s*(?:@escaping\s+)?(String\??|LocalizedStringKey|L10nString)\s*(?:[,=)]|$)", prm)
                    if not pm:
                        continue
                    ext, internal = pm.group(1), pm.group(2) or pm.group(1)
                    if ext == "_" and not pm.group(2):
                        continue
                    if not shows(body, internal, helpers):
                        continue
                    spec = helpers.setdefault(name, {"pos": set(), "labels": set(), "files": set()})
                    spec["files"].add(path)
                    if ext == "_":
                        if idx not in spec["pos"]:
                            spec["pos"].add(idx); changed = True
                    elif pm.group(2) is None:   # `title: String` → label is the name
                        if ext not in spec["labels"]:
                            spec["labels"].add(ext); changed = True
                    else:
                        if ext not in spec["labels"]:
                            spec["labels"].add(ext); changed = True
        if not changed:
            break
    # never treat logging helpers as UI
    for k in list(helpers):
        if k in LOG_CALLS or k.lower().startswith(("log", "print", "trace", "debug")):
            helpers.pop(k)
    return helpers


# ----------------------------------------------------------------------------------------------------------------------
# Extraction
# ----------------------------------------------------------------------------------------------------------------------

def helper_applies(name, helpers, path):
    """Types (capitalised) and long, unique function names are global; short / lower-case helpers only count in the
    file that defines them (`s(…)`, `kp(…)`, `row(…)` mean different things in different files)."""
    spec = helpers.get(name)
    if not spec:
        return False
    if name[:1].isupper():
        return True
    files = spec.get("files", set())
    if len(files) == 1 and len(name) >= 6:
        return True
    return path in files


def classify(path, src, masked, lit, helpers, is_core, pos_override=None, depth=0):
    """Returns (kind, keys) for a literal that is shown, else None."""
    if lit.nested or depth > 3:
        return None
    key = literal_key(lit)
    pos = lit.start if pos_override is None else pos_override
    o = enclosing_open(masked, pos)
    before = statement_before(masked, pos)
    stripped = masked[max(0, pos - 300):pos].rstrip()

    def callinfo(paren):
        callee = callee_before(masked, paren)
        idx, label, seg = arg_info(masked, paren, pos)
        return callee, idx, label, seg

    # inside an interpolation of another string: skipped (nested=True already)
    # 1. call arguments
    if o >= 0 and masked[o] == "(":
        callee, idx, label, seg = callinfo(o)
        last = (callee or "").split(".")[-1]
        chain = callee or ""
        if last in LOG_CALLS or chain.split(".")[0] in LOG_CALLS:
            return None
        # String(format: "…", …) and "…".appending(…): shown if the String(…) itself is
        if last == "String" and label == "format" and idx == 0:
            cs = masked.rfind("String", 0, o)
            r = classify(path, src, masked, lit, helpers, is_core, pos_override=cs, depth=depth + 1)
            return (r[0] + "+format", r[1]) if r else None
        # default names of the catalogues the app ships (brushes, gradients, workspaces, document presets …): data, but
        # shown translated (a user's own names have no translation and stay as typed)
        if label == "name" and last in DEFAULT_NAME_TYPES and looks_like_display(key):
            return ("name:" + last, [key])
        if path.endswith("Tools/BrushDefaults.swift") and last == "add" and idx == 2 and label is None:
            return ("name:brush", [key])
        if label in NON_UI_LABELS:
            return None
        if chain.endswith("MenuRegistry.add") or (last == "add" and "MenuRegistry" in path) or last == "MenuItemSpec":
            if (idx == 0 and label is None) or label == "menu":
                return ("menu", [p for p in key.split("/") if p])
            if (idx == 1 and label is None) or label in ("title", "submenu"):
                return ("menu", [key])
            return None
        if last in ("commit", "commitHistory", "recordHistory", "pushHistory", "addHistory") and idx == 0 and label is None:
            return ("history", [key])
        if label is None and last in UI_CALLS and (idx == 0 or last in UI_CALLS_ALL_ARGS):
            return (last, [key])
        if label is None and last in helpers and idx in helpers[last]["pos"] and helper_applies(last, helpers, path):
            return ("helper:" + last, [key])
        if label is not None and last in helpers and label in helpers[last]["labels"] and helper_applies(last, helpers, path):
            return ("helper:" + last, [key])
        if label in UI_LABELS:
            return (label + ":", [key])
        if last in ("addButton", "insertItem", "addItem", "NSMenuItem", "NSButton", "NSTextField", "setTitle", "setLabel") and (label in ("withTitle", "title", "labelWithString", "wrappingLabelWithString", "checkboxWithTitle", "radioButtonWithTitle", None)):
            return (last, [key])
        if last in UI_ARRAY_CALLS:
            return (last, [key])
        # a literal in an expression of a UI argument: Text(cond ? "A" : "B"), Text("A" + x)
        if label is None and idx == 0 and last in UI_CALLS and re.search(r"[?:]|\?\?|\+", seg):
            return (last, [key])
        # fall through: maybe the call is inside a display property
    # 2. array literal
    if o >= 0 and masked[o] == "[":
        # what is the array?
        oo = enclosing_open(masked, o)
        decl = statement_before(masked, o)
        dm = re.search(r"\b(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?::[^=]*)?=\s*$", decl)
        if dm and UI_ARRAY_NAMES.match(dm.group(1)) and looks_like_display(key):
            # a dictionary literal's keys are ids: only values / plain elements
            seg = masked[o + 1:pos]
            if re.search(r":\s*$", masked[o:pos].split(",")[-1]) or not re.search(r'"\s*:\s*$', masked[max(o, pos - 3):pos]):
                return ("array:" + dm.group(1), [key])
        if oo >= 0 and masked[oo] == "(":
            callee = callee_before(masked, oo) or ""
            last = callee.split(".")[-1]
            idx, label, seg = arg_info(masked, oo, o)
            if last in UI_ARRAY_CALLS or label in ("choices", "options", "items", "titles", "labels", "segments"):
                if looks_like_display(key):
                    return ("array:" + (label or last), [key])
    # 3. assignment
    am = re.search(r"\.?\b([A-Za-z_][A-Za-z0-9_]*)\s*(?:\?\?)?=\s*(?:tr\(\s*)?$", masked[max(0, pos - 200):pos])
    if am and not re.search(r"[=!<>]=\s*$", masked[max(0, pos - 4):pos]):
        if am.group(1) in UI_ASSIGN:
            return ("=" + am.group(1), [key])
    # 4. display property / function body
    name, info = enclosing_decl(masked, pos)
    if name:
        if name in UI_PROPS:
            if name in WEAK_PROPS:
                kind, head = info
                body_has_switch = re.search(r"\bswitch\b|\bcase\b|\?", masked[max(0, pos - 2000):pos][-2000:])
                if not (body_has_switch and looks_like_display(key)):
                    return None
            # not a comparison / dictionary key / id inside the property
            tail = masked[max(0, pos - 30):pos]
            if re.search(r"(==|!=|hasPrefix\(|hasSuffix\(|contains\(|\[)\s*$", tail):
                return None
            return ("prop:" + name, [key])
        # function returning a display string named like a display property
        if info and info[0] == "func" and re.match(r"(?:display|title|label|menuTitle|tooltip|help|caption|subtitle|message|statusText|describe|summary|explain)", name):
            tail = masked[max(0, pos - 30):pos]
            if re.search(r"(==|!=|hasPrefix\(|hasSuffix\(|contains\(|\[)\s*$", tail):
                return None
            if looks_like_display(key) or " " in key:
                return ("func:" + name, [key])
    # 5. enum raw values
    em = re.search(r"\bcase\s+[A-Za-z_][A-Za-z0-9_]*\s*=\s*$|,\s*[A-Za-z_][A-Za-z0-9_]*\s*=\s*$", masked[max(0, pos - 120):pos])
    if em:
        # inside an enum with String raw values?
        eo = enclosing_open(masked, pos, limit=40000)
        if eo >= 0 and masked[eo] == "{":
            head = masked[max(0, eo - 200):eo]
            if re.search(r"\benum\s+\w+\s*:\s*String\b", head) and looks_like_display(key):
                return ("enum", [key])
    return None


def extract(root=ROOT, include_core=True):
    files = []
    for base in [APP_ROOT] + ([CORE_ROOT] if include_core else []):
        for dp, dn, fn in os.walk(os.path.join(root, base)):
            dn.sort()
            for f in sorted(fn):
                if f.endswith(".swift"):
                    rel = os.path.relpath(os.path.join(dp, f), root)
                    files.append(rel)
    lexed = {}
    for rel in files:
        with open(os.path.join(root, rel), encoding="utf-8") as fh:
            src = fh.read()
        lits, masked, line_of = lex(src)
        lexed[rel] = (src, lits, masked)
    app_files = [(rel, lexed[rel][2]) for rel in files if rel.startswith(APP_ROOT) and not SKIP_FILE.search(rel)]
    helpers = discover_helpers(app_files)
    # framework names that look like helpers but are not ours
    for k in ("init", "String", "format", "append", "replacingOccurrences", "contains", "hasPrefix", "hasSuffix", "split"):
        helpers.pop(k, None)
    found = defaultdict(lambda: {"contexts": [], "kinds": set()})
    for rel in files:
        if SKIP_FILE.search(rel):
            continue
        src, lits, masked = lexed[rel]
        is_core = rel.startswith(CORE_ROOT)
        if "// l10n-ignore-file" in src:
            continue
        lines = src.split("\n")
        for lit in lits:
            if lit.nested:
                continue
            if "// l10n-ignore" in lines[lit.line - 1]:
                continue
            r = classify(rel, src, masked, lit, helpers, is_core)
            if not r:
                continue
            kind, keys = r
            if TR_ONLY_FILE.search(rel) and kind.split("+")[0] != "tr":
                continue
            if is_core and not TR_ONLY_FILE.search(rel) and not (kind.startswith("prop:") or kind.startswith("array:") or kind.startswith("label") or kind in ("enum", "choice", "label:", "title:", "unit:") or kind.startswith("func:") or kind.startswith("name:")):
                continue
            for k in keys:
                if not is_texty(k):
                    continue
                if len(k) > 2000:
                    continue
                e = found[k]
                short = rel.replace(APP_ROOT + "/", "").replace(CORE_ROOT + "/", "Core/")
                if len(e["contexts"]) < 6:
                    e["contexts"].append(f"{short}:{lit.line} {kind}")
                e["kinds"].add(kind)
    return found, helpers


# extra keys that the extractor cannot see (strings composed at runtime, AppKit's own menu items …)
def extra_keys(root=ROOT):
    p = os.path.join(root, "Localization", "extra-keys.txt")
    out = []
    if os.path.exists(p):
        for line in open(p, encoding="utf-8"):
            line = line.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            out.append(line.replace("\\n", "\n"))
    return out


def build(root=ROOT):
    found, helpers = extract(root)
    for k in extra_keys(root):
        e = found[k]
        e["contexts"].append("Localization/extra-keys.txt")
        e["kinds"].add("extra")
    strings = []
    for k in sorted(found, key=lambda s: (s.lower(), s)):
        e = found[k]
        strings.append({"key": k, "english": k, "contexts": e["contexts"], "kinds": sorted(e["kinds"])})
    return strings, helpers


def main(argv):
    out = os.path.join(ROOT, "Localization", "strings-en.json")
    report = False
    i = 1
    while i < len(argv):
        if argv[i] == "--out":
            out = argv[i + 1]; i += 2; continue
        if argv[i] == "--report":
            report = True
        i += 1
    strings, helpers = build()
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as fh:
        json.dump({"about": "User-facing strings of ImageCrat (scripts/l10n_extract.py). Key = English text; %@ = a value filled in at runtime.",
                   "count": len(strings), "strings": strings}, fh, ensure_ascii=False, indent=1)
        fh.write("\n")
    print(f"l10n_extract: {len(strings)} strings → {os.path.relpath(out, ROOT)}")
    if report:
        print("helpers:", json.dumps({k: {"pos": sorted(v["pos"]), "labels": sorted(v["labels"])} for k, v in sorted(helpers.items())}, indent=0))
        kinds = defaultdict(int)
        for s in strings:
            for k in s["kinds"]:
                kinds[k.split(":")[0] + (":" if ":" in k else "")] += 1
        print("kinds:", dict(sorted(kinds.items(), key=lambda x: -x[1])))


if __name__ == "__main__":
    main(sys.argv)
