#!/usr/bin/env bash
# Script tests for ./stackctl — the 000_backend domain and demo environment are
# the fixtures. Covers argument validation and that extra args reach nivis.
#
# stackctl mkdir's a state/ dir under the repo root and exec's `nivis`, so this
# copies the repo to a writable temp dir and puts a stub `nivis` on PATH. No
# real nivis, no credentials, no network.
set -euo pipefail

repo_src=$(cd "$(dirname "$0")/.." && pwd)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp -r "$repo_src" "$work/repo"
chmod -R u+w "$work/repo"
repo="$work/repo"

# stackctl is run through `bash` rather than executed directly: the Nix sandbox
# has no /usr/bin/env, so its shebang cannot resolve there. The shebang is not
# what these tests are about.
bash_bin=$(command -v bash)
stackctl=(bash "$repo/stackctl")

# Stub nivis: record argv, exit 0.
mkdir -p "$work/bin"
{
  printf '#!%s\n' "$bash_bin"
  cat <<'STUB'
printf '%s\n' "$@" > "$NIVIS_ARGV_OUT"
STUB
} > "$work/bin/nivis"
chmod +x "$work/bin/nivis"
export PATH="$work/bin:$PATH"
export NIVIS_ARGV_OUT="$work/argv"

fails=0
ok()   { echo "    ok $1"; }
bad()  { echo "    FAIL $1" >&2; fails=$((fails + 1)); }

# --- unknown environment -------------------------------------------------
out=$("${stackctl[@]}" nope 000_backend plan 2>&1) && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then
  bad "unknown environment must exit non-zero"
elif ! grep -q "unknown environment: nope" <<<"$out"; then
  bad "unknown environment must name the bad environment (got: $out)"
elif ! grep -q "domains: .*000_backend" <<<"$out"; then
  bad "usage must list the domains that do exist (got: $out)"
else
  ok "unknown environment is rejected, listing real domains"
fi

# --- unknown domain ------------------------------------------------------
out=$("${stackctl[@]}" demo does-not-exist plan 2>&1) && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then
  bad "unknown domain must exit non-zero"
elif ! grep -q "unknown domain: does-not-exist" <<<"$out"; then
  bad "unknown domain must name the bad domain (got: $out)"
elif ! grep -q "domains: .*000_backend" <<<"$out"; then
  bad "usage must list the domains that do exist (got: $out)"
else
  ok "unknown domain is rejected, listing real domains"
fi

# An unknown domain must not reach nivis at all.
if [ -e "$NIVIS_ARGV_OUT" ]; then
  bad "nivis was invoked for an unknown domain"
else
  ok "nivis is not invoked when validation fails"
fi

# --- too few arguments ---------------------------------------------------
out=$("${stackctl[@]}" demo 2>&1) && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then
  bad "too few arguments must exit non-zero"
elif ! grep -q "usage:" <<<"$out"; then
  bad "too few arguments must print usage (got: $out)"
else
  ok "too few arguments prints usage and exits non-zero"
fi

# --- the happy path reaches nivis with the right attr --------------------
"${stackctl[@]}" demo 000_backend plan
argv=$(cat "$NIVIS_ARGV_OUT")
if ! grep -qx "plan" <<<"$argv"; then
  bad "verb must be passed to nivis (got: $argv)"
elif ! grep -qx 'nivis.demo."000_backend"' <<<"$argv"; then
  bad "attr must address nivis.<env>.\"<domain>\" (got: $argv)"
else
  ok "verb and --attr nivis.demo.\"000_backend\" reach nivis"
fi

# --- extra arguments are forwarded unchanged -----------------------------
rm -f "$NIVIS_ARGV_OUT"
"${stackctl[@]}" demo 000_backend plan --some-flag --other=value
argv=$(cat "$NIVIS_ARGV_OUT")
if ! grep -qx -- "--some-flag" <<<"$argv"; then
  bad "--some-flag must be forwarded (got: $argv)"
elif ! grep -qx -- "--other=value" <<<"$argv"; then
  bad "--other=value must be forwarded (got: $argv)"
else
  ok "extra arguments are forwarded to nivis unchanged"
fi

# --- --var-file: absent -> no flag; present -> forwarded ------------------
rm -f "$NIVIS_ARGV_OUT"
"${stackctl[@]}" demo 000_backend plan
argv=$(cat "$NIVIS_ARGV_OUT")
if grep -qx -- "--var-file" <<<"$argv"; then
  bad "--var-file must not be passed when the vars file does not exist (got: $argv)"
else
  ok "no --var-file when environments/demo.vars.json is absent"
fi

rm -f "$NIVIS_ARGV_OUT"
printf '{ "stateBucket": "a-real-looking-bucket-name" }\n' > "$repo/environments/demo.vars.json"
"${stackctl[@]}" demo 000_backend plan
argv=$(cat "$NIVIS_ARGV_OUT")
if ! grep -qx -- "--var-file" <<<"$argv"; then
  bad "--var-file must be passed when the vars file exists (got: $argv)"
elif ! grep -qx -- "$repo/environments/demo.vars.json" <<<"$argv"; then
  bad "--var-file must name the environment's vars file (got: $argv)"
else
  ok "--var-file environments/demo.vars.json forwarded when present"
fi

# A one-off --var must still be passed, and after the file so it wins.
rm -f "$NIVIS_ARGV_OUT"
"${stackctl[@]}" demo 000_backend plan --var stateBucket=cli-wins
argv=$(cat "$NIVIS_ARGV_OUT")
file_pos=$(grep -nx -- "--var-file" <<<"$argv" | cut -d: -f1)
flag_pos=$(grep -nx -- "--var" <<<"$argv" | cut -d: -f1)
if [ -z "$flag_pos" ]; then
  bad "--var must be forwarded (got: $argv)"
elif [ -n "$file_pos" ] && [ "$flag_pos" -lt "$file_pos" ]; then
  bad "--var must come after --var-file so the flag wins (got: $argv)"
else
  ok "--var is forwarded after --var-file, preserving precedence"
fi
rm -f "$repo/environments/demo.vars.json"

if [ "$fails" -ne 0 ]; then
  echo "stackctl: $fails assertion(s) failed" >&2
  exit 1
fi
echo "    stackctl: all assertions passed"
