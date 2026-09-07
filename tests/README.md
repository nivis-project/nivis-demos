# tests

`nix flake check` runs everything here, and `scripts/coverage-gate.sh` reads
this directory to decide which catstack domains are covered.

## The convention

A domain `stack/<name>/domain.nix` counts as **covered** when some file in this
directory (`*.nix` or `*.sh`) contains the literal string `<name>`. Since a test
that exercises a domain names it anyway, coverage follows from writing the test —
there is no separate registry to keep in sync.

## The gate

Thresholds live in `flake.nix` under `coverage` (the single source of truth):

| Metric  | Threshold | Scope                                              |
| ------- | --------- | -------------------------------------------------- |
| overall | >= 70%    | every `stack/*/domain.nix`                         |
| core    | >= 80%    | the domains listed in `coverage.coreDomains`       |

`coreDomains` is empty until milestone 01 lands the foundation domains; add each
load-bearing domain there as it appears.

## Shape of a test

- `*.sh` — run directly by the `tests` check, in a Nix sandbox. Plain bash,
  non-zero exit means failure.
- `*.nix` — evaluation assertions over a domain's IR. Wire these into
  `checks.tests` in `flake.nix` when the first one lands; a domain's IR is a
  pure Nix value, so most assertions need no build.
