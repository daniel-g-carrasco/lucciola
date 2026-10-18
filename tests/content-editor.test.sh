#!/usr/bin/env bash
# Tests for the content editor (tools/content-editor): saving the website
# changes only what was edited (a save without edits is byte-identical), and
# the welcome window's data file passes its check, which refuses bad files in
# words. The cases live in content-editor.test.py; Python's standard library
# is all they need.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 -B "$ROOT/tests/content-editor.test.py"
