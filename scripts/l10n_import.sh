#!/bin/bash
# Reads a reviewed CSV (from scripts/l10n_export.sh, edited in a spreadsheet) and writes the Estonian strings back to
# Resources/et.lproj/Localizable.strings. Rows are checked first: placeholders (%@, %1$@, %d …) must fit the English,
# Estonian values must not be empty, and rows whose English was changed (or no longer exists in the app) are listed
# and skipped. Nothing is written when a row has a placeholder problem (pass --partial to import the good rows anyway).
#
# Usage: scripts/l10n_import.sh <file.csv> [--partial]
set -u
cd "$(dirname "$0")/.." || exit 2
[ $# -ge 1 ] || { echo "usage: scripts/l10n_import.sh <file.csv> [--partial]"; exit 2; }
f="$1"; shift
case "$f" in /*) ;; *) f="$OLDPWD/$f" ;; esac
python3 scripts/l10n_tool.py import "$f" "$@" || exit $?
plutil -lint -s Resources/et.lproj/Localizable.strings || { echo "l10n_import: the written table does not parse"; exit 1; }
python3 scripts/l10n_tool.py check --no-extract | head -1
