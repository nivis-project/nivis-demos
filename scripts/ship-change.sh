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

# Which capabilities does this change touch? Read it BEFORE archiving moves the
# directory away. Archive folds these deltas into openspec/specs/<capability>/,
# and those are the only spec paths this ship may commit.
CAPS=()
if [[ -d "${CHANGE_DIR}/specs" ]]; then
  while IFS= read -r dir; do
    CAPS+=("${dir#"${CHANGE_DIR}/specs/"}")
  done < <(find "${CHANGE_DIR}/specs" -mindepth 1 -name spec.md -printf '%h\n' | sort -u)
fi

echo "==> [3/6] archive OpenSpec change: ${CHANGE}"
openspec archive "${CHANGE}" --yes

echo "==> [4/6] commit + push the OpenSpec store (${OSROOT})"
# The store is SHARED with the other nivis repos, so it routinely holds unrelated
# in-progress changes. Stage only the paths this ship actually produced —
# `add -A` would sweep someone else's work into a commit claiming to archive
# this change.
ARCHIVED="$(basename "$(find "${OSROOT}/openspec/changes/archive" -maxdepth 1 -type d -name "*-${CHANGE}" | sort | tail -1)")"
CANDIDATES=("openspec/changes/${CHANGE}")
[[ -n "$ARCHIVED" ]] && CANDIDATES+=("openspec/changes/archive/${ARCHIVED}")
for cap in "${CAPS[@]+"${CAPS[@]}"}"; do
  CANDIDATES+=("openspec/specs/${cap}")
done

# Keep only paths git can act on: present on disk, or tracked (so a move's
# deletion side is staged too).
PATHS=()
for p in "${CANDIDATES[@]}"; do
  if [[ -e "${OSROOT}/${p}" ]] || git -C "$OSROOT" ls-files --error-unmatch -- "$p" >/dev/null 2>&1; then
    PATHS+=("$p")
  fi
done

if [[ ${#PATHS[@]} -eq 0 ]]; then
  echo "    nothing from this change to commit in the store" >&2
else
  # A detached HEAD here is silently destructive: the commit lands on no branch
  # and `push origin main` then reports "Everything up-to-date" while the archive
  # is orphaned. Refuse rather than pretend to have shipped.
  STORE_BRANCH="$(git -C "$OSROOT" branch --show-current)"
  if [[ "$STORE_BRANCH" != "main" ]]; then
    echo "ship: the store at ${OSROOT} is not on main (branch: '${STORE_BRANCH:-detached HEAD}')." >&2
    echo "      Committing here would not reach origin/main. Fix the store first:" >&2
    echo "        git -C ${OSROOT} checkout main" >&2
    exit 1
  fi

  git -C "$OSROOT" add -A -- "${PATHS[@]}"
  if git -C "$OSROOT" diff --cached --quiet; then
    echo "    store already up to date for ${CHANGE}"
  else
    git -C "$OSROOT" commit -m "Archive ${CHANGE} (nivis-demos)"
    git -C "$OSROOT" push origin main
    # Prove it actually landed: `push` can no-op without failing.
    if [[ "$(git -C "$OSROOT" rev-parse main)" != "$(git -C "$OSROOT" rev-parse origin/main)" ]]; then
      echo "ship: store push did not land — main and origin/main differ" >&2
      exit 1
    fi
  fi
fi

# Anything else dirty in the store is someone else's work: say so, leave it be.
if [[ -n "$(git -C "$OSROOT" status --porcelain)" ]]; then
  echo "    note: the store has other uncommitted changes, left untouched:"
  git -C "$OSROOT" status --porcelain | sed 's/^/      /' | head -10
fi

echo "==> [5/6] commit"
git add -A
jj commit -m "${SUBJECT}"

echo "==> [6/6] push main"
jj bookmark set main -r @-
jj git push --bookmark main

echo "==> shipped ${CHANGE}"
