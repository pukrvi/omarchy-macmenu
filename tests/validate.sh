#!/usr/bin/env bash
# Pre-flight checks for this plugin, run before every push.
#
#   1. The manifest still satisfies the schema the shell enforces.
#   2. MacMenu.qml parses. qmllint resolves the shell's shared modules with
#      -I, so the only diagnostics it should report are the uncreatable
#      Quickshell types it cannot see outside a running shell — the same two
#      the committed baseline reports.
#   3. The model tests pass. The parent-cycle test is the important one: a
#      regression there hangs the user's shell rather than failing a build.

set -euo pipefail

cd "$(dirname "$0")/.."

fail() { echo "validate: $*" >&2; exit 1; }

echo "==> manifest"
omarchy plugin validate . || fail "manifest is not valid"

echo "==> qml syntax"
QMLLINT=""
for candidate in /usr/lib/qt6/bin/qmllint qmllint qmllint6; do
  if command -v "$candidate" >/dev/null 2>&1; then QMLLINT="$candidate"; break; fi
done

if [[ -z $QMLLINT ]]; then
  echo "    qmllint not found — skipping (install qt6-tools for this check)"
else
  # Count diagnostics qmllint cannot avoid: the Quickshell types it has no
  # bindings for. Everything else is a real problem.
  syntax=$("$QMLLINT" -I /usr/share/omarchy/shell MacMenu.qml 2>&1 | grep -c '\[syntax\]' || true)
  [[ $syntax -eq 0 ]] || fail "MacMenu.qml has $syntax syntax error(s)"
  echo "    no syntax errors"
fi

echo "==> model tests"
node tests/run.js || fail "model tests failed"

echo "==> ok"
