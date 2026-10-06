#!/bin/bash
# Localization check (Localization/README.md): re-extracts every user-facing string of the app
# (scripts/l10n_extract.py → Localization/strings-en.json) and fails when one has no Estonian entry in
# Resources/et.lproj/Localizable.strings (and is not on the reviewed allow-list, Localization/allowlist.txt), or when a
# translation's placeholders (%@, %1$@ …) don't fit the English. New source files are picked up automatically.
#
# Usage: scripts/check_l10n.sh [--no-extract] [--obsolete]      (exit 0 = every string translated)
set -u
cd "$(dirname "$0")/.." || exit 2
plutil -lint -s Resources/et.lproj/Localizable.strings || { echo "check_l10n: Resources/et.lproj/Localizable.strings does not parse"; exit 1; }
exec python3 scripts/l10n_tool.py check "$@"
