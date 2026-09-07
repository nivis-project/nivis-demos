#!/usr/bin/env bash
# ship-change.sh <change-name> [commit-subject]
#
# Gated tail for shipping ONE implemented OpenSpec change:
#   stage -> gate (nix flake check) -> archive -> commit -> push.
# If the gate fails this aborts before archiving or committing.
#
# NOTE: OpenSpec planning for this repo lives in the shared `nivis` store
# (see openspec/config.yaml), NOT under ./openspec. The change therefore lives
# in — and is archived into — the store's own git repo, which this script
# commits and pushes separately from this repo.
set -euo pipefail

CHANGE="${1:?usage: ship-change.sh <change-name> [commit-subject]}"
SUBJECT="${2:-Implement ${CHANGE}}"

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

# Resolve the OpenSpec root instead of assuming ./openspec — here it is the
# `nivis` store at a path outside this repo.
OSROOT="$(openspec context --json | python3 -c 'import sys,json;print(json.load(sys.stdin)["root"]["path"])')"
CHANGE_DIR="${OSROOT}/openspec/changes/${CHANGE}"
TASKS="${CHANGE_DIR}/tasks.md"

if [[ ! -d "$CHANGE_DIR" ]]; then
  echo "ship: no active change ${CHANGE} under ${OSROOT}/openspec/changes/" >&2
  exit 1
fi
if [[ -f "$TASKS" ]] && grep -qE "^\s*- \[ \]" "$TASKS"; then
  echo "ship: $TASKS still has unchecked tasks — finish the apply step first" >&2
  exit 1
fi

echo "==> [1/6] stage working tree (so nix flake sees new files)"
# git-level staging even though we commit with jj: `nix flake check` on a dirty
# tree only sees git-tracked paths, so new files must hit the index first.
git add -A

echo "==> [2/6] gate: nix flake check"
nix flake check

echo "==> [3/6] archive OpenSpec change: ${CHANGE}"
openspec archive "${CHANGE}" --yes

echo "==> [4/6] commit + push the OpenSpec store (${OSROOT})"
if [[ -n "$(git -C "$OSROOT" status --porcelain)" ]]; then
  git -C "$OSROOT" add -A
  git -C "$OSROOT" commit -m "Archive ${CHANGE} (nivis-demos)"
  git -C "$OSROOT" push origin main
else
  echo "    store clean, nothing to push"
fi

echo "==> [5/6] commit"
git add -A
jj commit -m "${SUBJECT}"

echo "==> [6/6] push main"
jj bookmark set main -r @-
jj git push --bookmark main

echo "==> shipped ${CHANGE}"
