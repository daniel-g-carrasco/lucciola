#!/usr/bin/env bash
# Tests for the content editor (tools/content-editor): saving the website
# changes only what was edited (a save without edits is byte-identical), and
# the welcome window's data file passes its check, which refuses bad files in
# words. The cases live in content-editor.test.py; Python's standard library
# is all they need. content-editor-server.test.py starts the server and
# checks that only the page opened with its key can use the API.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 -B "$ROOT/tests/content-editor.test.py"
python3 -B "$ROOT/tests/content-editor-server.test.py"
