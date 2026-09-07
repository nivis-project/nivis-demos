#!/usr/bin/env bash
# coverage-gate.sh — the coverage half of `nix flake check`.
#
# This repo's unit of work is a catstack *domain* (`stack/<name>/domain.nix`),
# not a package of functions, so "coverage" here means: what share of the
# declared domains is exercised by at least one test under `tests/`?
# A domain counts as covered when some file in `tests/` names it.
#
# Thresholds and the core-domain list come from flake.nix (single source of
# truth) via the environment:
#   OVERALL_MIN  default 70   — every domain in stack/
#   CORE_MIN     default 80   — the load-bearing domains every demo depends on
#   CORE_DOMAINS space-separated domain names
set -euo pipefail

OVERALL_MIN="${OVERALL_MIN:-70}"
CORE_MIN="${CORE_MIN:-80}"
CORE_DOMAINS="${CORE_DOMAINS:-}"

cd "${1:-.}"

domains=()
for d in stack/*/domain.nix; do
  [[ -e "$d" ]] || continue
  domains+=("$(basename "$(dirname "$d")")")
done

testfiles=()
if [[ -d tests ]]; then
  while IFS= read -r f; do testfiles+=("$f"); done \
    < <(find tests -type f \( -name '*.nix' -o -name '*.sh' \) | sort)
fi

if [[ ${#domains[@]} -eq 0 ]]; then
  cat >&2 <<'MSG'
coverage: FAIL — no stack domains found under stack/*/domain.nix

  Nothing has been built yet, so there is nothing this gate can vouch for.
  This is the expected state for a fresh scaffold: write the first domain and
  its test before the first `/mip:ship`.
MSG
  exit 1
fi

if [[ ${#testfiles[@]} -eq 0 ]]; then
  cat >&2 <<MSG
coverage: FAIL — ${#domains[@]} domain(s) but no tests under tests/

  Domains: ${domains[*]}
  Add tests/<something>.nix naming each domain it exercises.
MSG
  exit 1
fi

is_core() {
  local name="$1" c
  for c in $CORE_DOMAINS; do [[ "$c" == "$name" ]] && return 0; done
  return 1
}

covered=0 total=0 core_covered=0 core_total=0
echo "coverage: domain -> covered by tests/"
for name in "${domains[@]}"; do
  total=$((total + 1))
  is_core "$name" && core_total=$((core_total + 1))
  if grep -qlF -- "$name" "${testfiles[@]}" 2>/dev/null; then
    covered=$((covered + 1))
    is_core "$name" && core_covered=$((core_covered + 1))
    printf '  %-24s yes%s\n' "$name" "$(is_core "$name" && echo '  (core)' || true)"
  else
    printf '  %-24s NO%s\n' "$name" "$(is_core "$name" && echo '   (core)' || true)"
  fi
done

pct() { # numerator denominator -> integer percent (100 when denominator is 0)
  if [[ "$2" -eq 0 ]]; then echo 100; else echo $(( $1 * 100 / $2 )); fi
}

overall="$(pct "$covered" "$total")"
core="$(pct "$core_covered" "$core_total")"

echo
echo "coverage: overall ${overall}% (${covered}/${total}), need >=${OVERALL_MIN}%"
if [[ "$core_total" -eq 0 ]]; then
  echo "coverage: core     n/a (no core domains declared in flake.nix)"
else
  echo "coverage: core     ${core}% (${core_covered}/${core_total}), need >=${CORE_MIN}%"
fi

fail=0
[[ "$overall" -lt "$OVERALL_MIN" ]] && { echo "coverage: FAIL overall ${overall}% < ${OVERALL_MIN}%" >&2; fail=1; }
[[ "$core_total" -gt 0 && "$core" -lt "$CORE_MIN" ]] && { echo "coverage: FAIL core ${core}% < ${CORE_MIN}%" >&2; fail=1; }
[[ "$fail" -eq 0 ]] && echo "coverage: PASS"
exit "$fail"
