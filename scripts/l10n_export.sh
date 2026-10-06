#!/bin/bash
# Writes Localization/ImageCrat-et.csv for review in Google Sheets / Excel / Numbers
# (columns: key, English, Estonian, context/screen, notes). See Localization/README.md.
#
# Usage: scripts/l10n_export.sh [out.csv]
set -u
cd "$(dirname "$0")/.." || exit 2
exec python3 scripts/l10n_tool.py export "$@"
