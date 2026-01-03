#!/usr/bin/env bash
set -euo pipefail

SQLITE_PACKAGE=".build/checkouts/SQLite.swift/Package.swift"
PHONE_NUMBER_BUNDLE=".build/checkouts/PhoneNumberKit/PhoneNumberKit/Bundle+Resources.swift"

if [[ ! -f "$SQLITE_PACKAGE" ]]; then
  exit 0
fi

chmod u+w "$SQLITE_PACKAGE" || true

# Try python3, then python, then fail
if command -v python3 >/dev/null 2>&1; then
  PYTHON_BIN="python3"
elif command -v python >/dev/null 2>&1; then
  PYTHON_BIN="python"
else
  echo "Error: Python not found. Please install Python 3."
  exit 1
fi

$PYTHON_BIN - <<'PY'
from pathlib import Path
path = Path('.build/checkouts/SQLite.swift/Package.swift')
text = path.read_text()
if 'PrivacyInfo.xcprivacy' in text:
    raise SystemExit(0)
needle = 'exclude: [\n            "Info.plist"\n        ]'
replacement = 'exclude: [\n            "Info.plist",\n            "PrivacyInfo.xcprivacy"\n        ]'
if needle in text:
    text = text.replace(needle, replacement)
    path.write_text(text)
PY

if [[ -f "$PHONE_NUMBER_BUNDLE" ]]; then
  chmod u+w "$PHONE_NUMBER_BUNDLE" || true
  $PYTHON_BIN - <<'PY'
from pathlib import Path

path = Path(".build/checkouts/PhoneNumberKit/PhoneNumberKit/Bundle+Resources.swift")
text = path.read_text()

updated = False
if "#if DEBUG && SWIFT_PACKAGE" in text:
    text = text.replace("#if DEBUG && SWIFT_PACKAGE", "#if SWIFT_PACKAGE")
    updated = True

needle = "Bundle.main.bundleURL,\n"
insert = "Bundle.main.bundleURL,\n            Bundle.main.bundleURL.resolvingSymlinksInPath(),\n"
if "resolvingSymlinksInPath()" not in text and needle in text:
    text = text.replace(needle, insert)
    updated = True

if updated:
    path.write_text(text)
PY
fi
