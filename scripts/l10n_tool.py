#!/usr/bin/env python3
"""ImageCrat localization tool (see Localization/README.md).

    l10n_tool.py extract                 re-scan the sources → Localization/strings-en.json
    l10n_tool.py check [--no-extract]    fail when a user-facing string has no Estonian entry (or a broken one)
    l10n_tool.py export [out.csv]        Localization/ImageCrat-et.csv for review (key, English, Estonian, context/screen, notes)
    l10n_tool.py import <file.csv>       validate a reviewed CSV and write the Estonian strings back
    l10n_tool.py merge <file.tsv|json>   (developer) add translations: TSV "English<TAB>Estonian" or a JSON object
    l10n_tool.py stats                   counts

The Estonian table is Resources/et.lproj/Localizable.strings (UTF-8, keyed by the English text).
Strings that stay English on purpose are listed in Localization/allowlist.txt (reviewed).
"""
import csv
import hashlib
import io
import json
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

STRINGS_EN = os.path.join(ROOT, "Localization", "strings-en.json")
ET_TABLE = os.path.join(ROOT, "Resources", "et.lproj", "Localizable.strings")
ALLOWLIST = os.path.join(ROOT, "Localization", "allowlist.txt")
CSV_OUT = os.path.join(ROOT, "Localization", "ImageCrat-et.csv")
NOTES = os.path.join(ROOT, "Localization", "review-notes-et.json")

SPEC = re.compile(r"%(?:(\d+)\$)?[-+0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|h|ll|l|q|L|z|t|j)?[@dDiuUxXoOfFeEgGaAcCsSp]|%%")
SWIFT_INTERP = re.compile(r"\\\(")


# ----------------------------------------------------------------------------------------------------------------------
# .strings files
# ----------------------------------------------------------------------------------------------------------------------

def _unescape(s):
    out = []
    i = 0
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s):
            n = s[i + 1]
            if n == "n":
                out.append("\n")
            elif n == "t":
                out.append("\t")
            elif n == "r":
                out.append("\r")
            elif n == "U" or n == "u":
                h = s[i + 2:i + 6]
                try:
                    out.append(chr(int(h, 16)))
                    i += 6
                    continue
                except ValueError:
                    out.append(n)
            else:
                out.append(n)
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def _escape(s):
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t").replace("\r", "\\r")


def read_strings(path):
    """{key: value} of a .strings file (comments ignored)."""
    if not os.path.exists(path):
        return {}
    text = open(path, encoding="utf-8").read()
    out = {}
    i = 0
    n = len(text)

    def skip_ws(i):
        while i < n:
            if text.startswith("/*", i):
                j = text.find("*/", i + 2)
                i = n if j < 0 else j + 2
            elif text.startswith("//", i):
                j = text.find("\n", i)
                i = n if j < 0 else j + 1
            elif text[i].isspace():
                i += 1
            else:
                break
        return i

    def read_quoted(i):
        assert text[i] == '"', f"expected a quote at {i}: {text[i:i+40]!r}"
        j = i + 1
        buf = []
        while j < n:
            c = text[j]
            if c == "\\":
                buf.append(text[j:j + 2])
                j += 2
                continue
            if c == '"':
                break
            buf.append(c)
            j += 1
        return _unescape("".join(buf)), j + 1

    while True:
        i = skip_ws(i)
        if i >= n:
            break
        k, i = read_quoted(i)
        i = skip_ws(i)
        assert text[i] == "=", f"expected = after {k!r}"
        i = skip_ws(i + 1)
        v, i = read_quoted(i)
        i = skip_ws(i)
        if i < n and text[i] == ";":
            i += 1
        out[k] = v
    return out


def write_strings(path, table, contexts=None, header=None):
    contexts = contexts or {}
    os.makedirs(os.path.dirname(path), exist_ok=True)
    lines = []
    lines.append("/*")
    lines.append(header or " ImageCrat — Estonian (eesti) interface strings, keyed by the English text.\n"
                           " Edited through Localization/ImageCrat-et.csv (scripts/l10n_export.sh / scripts/l10n_import.sh).\n"
                           " %@ (or %1$@, %2$@ …) is a value filled in at runtime; %% is a percent sign.")
    lines.append("*/")
    lines.append("")
    for k in sorted(table, key=lambda s: (s.lower(), s)):
        ctx = contexts.get(k)
        if ctx:
            c = "; ".join(ctx[:2]).replace("*/", "* /")
            lines.append(f"/* {c} */")
        lines.append(f'"{_escape(k)}" = "{_escape(table[k])}";')
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")


# ----------------------------------------------------------------------------------------------------------------------
# Inputs
# ----------------------------------------------------------------------------------------------------------------------

def load_en(extract_now=True):
    if extract_now:
        import l10n_extract
        strings, _ = l10n_extract.build(ROOT)
        with open(STRINGS_EN, "w", encoding="utf-8") as fh:
            json.dump({"about": "User-facing strings of ImageCrat (scripts/l10n_extract.py). Key = English text; %@ = a value filled in at runtime.",
                       "count": len(strings), "strings": strings}, fh, ensure_ascii=False, indent=1)
            fh.write("\n")
        return strings
    return json.load(open(STRINGS_EN, encoding="utf-8"))["strings"]


def load_allowlist():
    exact, patterns = set(), []
    if os.path.exists(ALLOWLIST):
        for line in open(ALLOWLIST, encoding="utf-8"):
            line = line.rstrip("\n")
            if not line.strip() or line.startswith("#"):
                continue
            if line.startswith("re:"):
                patterns.append(re.compile(line[3:]))
            else:
                exact.add(line.replace("\\n", "\n"))
    return exact, patterns


def allowed(key, allow):
    exact, patterns = allow
    return key in exact or any(p.fullmatch(key) for p in patterns)


def string_id(key):
    return "s" + hashlib.sha1(key.encode("utf-8")).hexdigest()[:8]


# ----------------------------------------------------------------------------------------------------------------------
# Placeholders
# ----------------------------------------------------------------------------------------------------------------------

def slots(s):
    """[(index or None)] of the format slots ("%%" excluded)."""
    out = []
    for m in SPEC.finditer(s):
        if m.group(0) == "%%":
            continue
        out.append(int(m.group(1)) if m.group(1) else None)
    return out


def same_blanks(key, value):
    """The translation with the English's leading / trailing blanks (spreadsheets and editors drop them)."""
    lead = key[:len(key) - len(key.lstrip())]
    trail = key[len(key.rstrip()):]
    return lead + value.strip() + trail


def placeholder_problem(key, value):
    """None when the translation's placeholders fit the key's, else a message."""
    if SWIFT_INTERP.search(value):
        return "contains a Swift interpolation \\( … ) — use %@ (or %1$@, %2$@ …)"
    ks = slots(key)
    vs = slots(value)
    n = len(ks)
    if n == 0:
        if vs:
            return f"has placeholders {[m.group(0) for m in SPEC.finditer(value) if m.group(0) != '%%']} but the English has none"
        return None
    positional = [v for v in vs if v is not None]
    plain = [v for v in vs if v is None]
    if positional and plain:
        return "mixes %@ and %1$@ — use one style"
    if positional:
        bad = [v for v in positional if v < 1 or v > n]
        if bad:
            return f"refers to value {bad[0]} but the English has only {n}"
        missing = [i for i in range(1, n + 1) if i not in positional]
        # a dropped value is fine only where the English uses it as an ending ("layer%@" → "s")
        endings = plural_endings(key)
        real = [i for i in missing if i not in endings]
        if real:
            return f"leaves out value %{real[0]}$@ of the English"
        return None
    if len(plain) != n:
        return f"has {len(plain)} placeholder(s), the English has {n} (use %1$@ … to reorder or drop an ending)"
    return None


def plural_endings(key):
    """1-based indices of slots that directly follow letters (the "s" of "layer%@")."""
    out = set()
    idx = 0
    for m in SPEC.finditer(key):
        if m.group(0) == "%%":
            continue
        idx += 1
        if m.start() > 0 and key[m.start() - 1].isalpha():
            out.add(idx)
    return out


# ----------------------------------------------------------------------------------------------------------------------
# Commands
# ----------------------------------------------------------------------------------------------------------------------

def cmd_check(args):
    strings = load_en(extract_now="--no-extract" not in args)
    et = read_strings(ET_TABLE)
    allow = load_allowlist()
    missing, broken, empty = [], [], []
    translated = allowed_n = 0
    for s in strings:
        k = s["key"]
        if k in et:
            v = et[k]
            if not v.strip():
                empty.append(s)
                continue
            p = placeholder_problem(k, v)
            if p:
                broken.append((s, p))
            translated += 1
        elif allowed(k, allow):
            allowed_n += 1
        else:
            missing.append(s)
    keys = {s["key"] for s in strings}
    obsolete = [k for k in et if k not in keys and "::" not in k]
    print(f"l10n check: {len(strings)} user-facing strings · {translated} translated · {allowed_n} stay English (allow-list) · "
          f"{len(missing)} missing · {len(broken)} broken · {len(empty)} empty · {len(obsolete)} unused entries")
    for s in missing[:200]:
        print(f"  missing: {s['key']!r}  ({s['contexts'][0] if s['contexts'] else ''})")
    if len(missing) > 200:
        print(f"  … and {len(missing) - 200} more")
    for s, p in broken[:100]:
        print(f"  broken:  {s['key']!r} → {et[s['key']]!r}: {p}")
    for s in empty[:50]:
        print(f"  empty:   {s['key']!r}")
    if "--obsolete" in args:
        for k in obsolete:
            print(f"  unused:  {k!r}")
    return 1 if (missing or broken or empty) else 0


def notes_for(s, key):
    notes = []
    n = len(slots(key))
    if n:
        notes.append("%@ = a value filled in by the app" if n == 1 else f"{n} values (%@): reorder with %1$@, %2$@ …")
    if plural_endings(key):
        notes.append("the last %@ is an English plural ending (‘s’): it may be left out")
    kinds = set(k.split(":")[0] for k in s.get("kinds", []))
    if "menu" in kinds or "CommandMenu" in kinds:
        notes.append("menu item: keep it short")
    if "help" in kinds or "IconButton" in "".join(s.get("kinds", [])):
        notes.append("tool tip")
    if any(k.startswith("helper:Toggle2") or k.startswith("helper:ValueSlider") or k == "Picker" for k in s.get("kinds", [])):
        notes.append("label in a narrow panel: keep it short")
    if key.endswith("…"):
        notes.append("keep the …")
    if re.search(r"[⌘⌥⇧⌃]", key):
        notes.append("keyboard shortcuts stay as they are")
    return "; ".join(notes)


def screen_of(ctx):
    # "UI/Panels/LayersPanel.swift:120 Text" → "LayersPanel (Text)"
    m = re.match(r"(?:Core/)?(?:.*/)?([^/]+)\.swift:(\d+) (.*)", ctx)
    if not m:
        return ctx
    return f"{m.group(1)}:{m.group(2)} ({m.group(3)})"


def cmd_export(args):
    out = args[0] if args and not args[0].startswith("-") else CSV_OUT
    strings = load_en(extract_now="--no-extract" not in args)
    et = read_strings(ET_TABLE)
    allow = load_allowlist()
    rows = 0
    with open(out, "w", encoding="utf-8-sig", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["key", "English", "Estonian", "context/screen", "notes"])
        def order(s):
            c = s["contexts"][0] if s["contexts"] else "~"
            m = re.match(r"(.*?):(\d+)", c)
            return (m.group(1), int(m.group(2))) if m else (c, 0)
        for s in sorted(strings, key=order):
            k = s["key"]
            if allowed(k, allow) and k not in et:
                continue
            ctx = " | ".join(screen_of(c) for c in s["contexts"][:3])
            w.writerow([string_id(k), k, et.get(k, ""), ctx, notes_for(s, k)])
            rows += 1
    print(f"l10n export: {rows} rows → {os.path.relpath(out, ROOT)}")
    return 0


def read_csv_any(path):
    raw = open(path, "rb").read()
    for enc in ("utf-8-sig", "utf-16", "cp1257", "latin-1"):
        try:
            text = raw.decode(enc)
            break
        except UnicodeDecodeError:
            continue
    # Excel in Estonia writes ";" (decimal comma locale), Google Sheets ",", some tools tabs: the header line decides
    header = text.split("\n", 1)[0]
    delim = max([",", ";", "\t"], key=header.count)
    return list(csv.reader(io.StringIO(text), delimiter=delim))


def cmd_import(args):
    if not args:
        print("usage: l10n_tool.py import <file.csv>")
        return 2
    path = args[0]
    rows = read_csv_any(path)
    if not rows:
        print("l10n import: empty file")
        return 1
    header = [h.strip().lower() for h in rows[0]]

    def col(name, *alts):
        for n in (name,) + alts:
            if n in header:
                return header.index(n)
        return None
    ci, ce, cet, cn = col("key", "id"), col("english", "en"), col("estonian", "eesti", "et"), col("notes", "märkused")
    if ce is None or cet is None:
        print("l10n import: the file needs the columns English and Estonian (and key)")
        return 1
    strings = load_en(extract_now="--no-extract" not in args)
    by_key = {s["key"]: s for s in strings}
    by_id = {string_id(s["key"]): s["key"] for s in strings}
    et = read_strings(ET_TABLE)
    allow = load_allowlist()
    errors, changed_en, empty, updated, same, added = [], [], [], 0, 0, 0
    notes = {}
    for ln, r in enumerate(rows[1:], start=2):
        if not any(c.strip() for c in r):
            continue
        r = r + [""] * (len(header) - len(r))
        english = r[ce].replace("\r\n", "\n")
        value = r[cet].replace("\r\n", "\n")
        rid = r[ci].strip() if ci is not None else ""
        key = by_id.get(rid) if rid else None
        if key is None and english in by_key:
            key = english
        if key is None:
            changed_en.append((ln, english, "no such string in the app any more (removed or reworded)"))
            continue
        if english != key:
            changed_en.append((ln, english, f"the English was changed (the app has {key!r}); the row was not imported"))
            continue
        if not value.strip():
            if not allowed(key, allow):
                empty.append((ln, key))
            continue
        # spreadsheets drop leading / trailing blanks: they come from the English (" — tool presets", "\nDouble-click …")
        value = same_blanks(key, value)
        p = placeholder_problem(key, value)
        if p:
            errors.append((ln, key, value, p))
            continue
        if cn is not None and r[cn].strip() and r[cn].strip() != notes_for(by_key[key], key):
            notes[key] = r[cn].strip()   # the reviewer's own note (not the one export wrote)
        if et.get(key) == value:
            same += 1
        else:
            if key in et:
                updated += 1
            else:
                added += 1
            et[key] = value
    for ln, en, why in changed_en:
        print(f"  line {ln}: {en[:70]!r}: {why}")
    for ln, k in empty[:100]:
        print(f"  line {ln}: {k[:70]!r}: empty Estonian value (left as it was)")
    for ln, k, v, p in errors:
        print(f"  line {ln}: {k[:60]!r} → {v[:60]!r}: {p}")
    if errors and "--partial" not in args:
        print(f"l10n import: {len(errors)} row(s) with placeholder problems — nothing written. Fix them (or pass --partial to import the rest).")
        return 1
    contexts = {s["key"]: s["contexts"] for s in strings}
    write_strings(ET_TABLE, et, contexts)
    if notes:
        old = json.load(open(NOTES, encoding="utf-8")) if os.path.exists(NOTES) else {}
        old.update(notes)
        with open(NOTES, "w", encoding="utf-8") as fh:
            json.dump(old, fh, ensure_ascii=False, indent=1, sort_keys=True)
    print(f"l10n import: {updated} changed · {added} new · {same} unchanged · {len(empty)} empty · {len(changed_en)} changed/removed English · "
          f"{len(errors)} placeholder problems → {os.path.relpath(ET_TABLE, ROOT)}" + (f"; {len(notes)} notes → {os.path.relpath(NOTES, ROOT)}" if notes else ""))
    return 1 if errors else 0


def cmd_merge(args):
    """Developer helper: merge translations (TSV English<TAB>Estonian, or JSON {English: Estonian})."""
    et = read_strings(ET_TABLE)
    strings = json.load(open(STRINGS_EN, encoding="utf-8"))["strings"] if os.path.exists(STRINGS_EN) else []
    contexts = {s["key"]: s["contexts"] for s in strings}
    n = 0
    bad = 0
    for path in args:
        if path.endswith(".json"):
            d = json.load(open(path, encoding="utf-8"))
            pairs = list(d.items())
        else:
            pairs = []
            for line in open(path, encoding="utf-8"):
                line = line.rstrip("\n")
                if not line or line.startswith("#") or "\t" not in line:
                    continue
                k, v = line.split("\t", 1)
                pairs.append((k.replace("\\n", "\n"), v.replace("\\n", "\n")))
        for k, v in pairs:
            v = same_blanks(k, v)
            p = placeholder_problem(k, v)
            if p:
                print(f"  {k!r} → {v!r}: {p}")
                bad += 1
                continue
            et[k] = v
            n += 1
    write_strings(ET_TABLE, et, contexts)
    print(f"l10n merge: {n} entries ({bad} rejected) → {os.path.relpath(ET_TABLE, ROOT)} ({len(et)} total)")
    return 1 if bad else 0


def cmd_stats(args):
    strings = load_en(extract_now=False)
    et = read_strings(ET_TABLE)
    allow = load_allowlist()
    t = sum(1 for s in strings if s["key"] in et)
    a = sum(1 for s in strings if s["key"] not in et and allowed(s["key"], allow))
    print(json.dumps({"strings": len(strings), "translated": t, "allowlisted": a, "missing": len(strings) - t - a, "table": len(et)}))
    return 0


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    cmd, args = argv[1], argv[2:]
    if cmd == "extract":
        strings = load_en(True)
        print(f"l10n extract: {len(strings)} strings → {os.path.relpath(STRINGS_EN, ROOT)}")
        return 0
    return {"check": cmd_check, "export": cmd_export, "import": cmd_import, "merge": cmd_merge, "stats": cmd_stats}.get(cmd, lambda a: (print(__doc__), 2)[1])(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
