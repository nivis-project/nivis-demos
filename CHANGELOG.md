# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Project scaffold: OpenSpec wired to the shared `nivis` store, beans tracker
  with milestones for the mixed-cloud foundation and the Vaultwarden and
  Minecraft demos, and a gated `scripts/ship-change.sh`.
- Catstack layout for the demo stacks: `stack/<domain>/domain.nix`,
  `environments/demo.nix`, and a `stackctl` entrypoint
  (`./stackctl <env> <domain> <verb>`) that forwards extra arguments to nivis.
- `stack/000_backend`: the self-managed S3 state bucket, with versioning and
  public access fully blocked, plus the per-domain `<domain>/state.json` state
  key convention. The one-time bootstrap is three commands and is documented in
  the new README; it requires nivis >= 0.5.0.
- Domain evaluation tests: `tests/*.nix` assert on a domain's IR at flake-eval
  time (no credentials, no network), so a failing assertion fails
  `nix flake check` before anything is built.
