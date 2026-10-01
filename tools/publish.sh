#!/usr/bin/env bash
# Publish this checkout to its GitHub repository.
#
# The two id forms are deliberate and cannot both live in one file:
#
#   local manifest   vishnawat.macmenu      matches this folder's name, which is
#                                           how the shell resolves a user plugin
#                                           and how your bar config refers to it
#   repo manifest    io.github.pukrvi.macmenu
#                                           what `omarchy plugin add` uses on a
#                                           fresh machine — it names the cloned
#                                           directory from the manifest id, so a
#                                           published plugin must carry the
#                                           io.github.* form
#
# So the two differ in exactly one line, and this script keeps them apart
# without ever force-pushing. It builds a `publish` branch whose only change
# is that line (plus the README commands that quote the id), and pushes that
# branch to the repository's main. Your local main is never modified, so the
# plugin on this machine keeps resolving exactly as it does now.

set -euo pipefail

cd "$(dirname "$0")/.."

LOCAL_ID="vishnawat.macmenu"
PUBLISHED_ID="io.github.pukrvi.macmenu"
REPO="pukrvi/omarchy-macmenu"
BRANCH="publish"

fail() { echo "publish: $*" >&2; exit 1; }

echo "==> checking the working copy is clean"
[[ -z $(git status --porcelain) ]] || fail "uncommitted changes; commit them first"

echo "==> running the tests"
./tests/validate.sh >/dev/null || fail "tests failed; not publishing"

echo "==> building the $BRANCH branch"
git branch -D "$BRANCH" >/dev/null 2>&1 || true
git checkout -q -b "$BRANCH"

# Restore local state whatever happens below.
trap 'git checkout -q main 2>/dev/null || true' EXIT

python3 - "$LOCAL_ID" "$PUBLISHED_ID" <<'PY'
import io, re, sys
local_id, published_id = sys.argv[1], sys.argv[2]

s = io.open("manifest.json", encoding="utf-8").read()
s = s.replace('"id": "%s"' % local_id, '"id": "%s"' % published_id)
io.open("manifest.json", "w", encoding="utf-8").write(s)

r = io.open("README.md", encoding="utf-8").read()
o = r
r = r.replace("omarchy plugin disable %s" % local_id,
              "omarchy plugin disable %s" % published_id)
r = r.replace("omarchy plugin remove <plugin-id>",
              "omarchy plugin remove %s" % published_id)
# The note explaining the two ids only makes sense in the local checkout.
r = re.sub(r"\n`omarchy plugin list` shows the id your install uses\.[^\n]*\n[^\n]*\n", "\n", r)
if r != o:
    io.open("README.md", "w", encoding="utf-8").write(r)
PY

echo "==> validating the published form"
omarchy plugin validate . || fail "the published form does not validate"
grep -q "\"id\": \"$PUBLISHED_ID\"" manifest.json || fail "id was not rewritten"

git -c user.name=vishnawat -c user.email=pukrvi@users.noreply.github.com \
  commit -q --all -m "Publish: carry the io.github.* manifest id

\`omarchy plugin add\` names the directory it clones into from the manifest
id, so a published plugin has to use the io.github.* form. The local
checkout keeps vishnawat.macmenu, which is what this machine's bar config
references, and that is the only difference between the two."

echo "==> pushing to $REPO main"
# Refuses rather than overwriting if the remote has moved on. If it has,
# fetch and rebase this branch first — no history is ever rewritten here.
git fetch -q origin main
git rebase -q origin/main "$BRANCH"
git push -q origin "$BRANCH":main

git checkout -q main
trap - EXIT

echo "==> published $REPO"
echo "    local manifest id: $LOCAL_ID"
echo "    published id:      $PUBLISHED_ID"
