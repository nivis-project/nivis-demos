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
- DNS: `stack/010_dns` manages the Route 53 hosted zone for your domain and
  outputs its name servers for a one-time registrar delegation. The zone is its
  own domain so destroying a workload never takes your name servers with it.
- Configuration variables may now be **required**: declared with no default, they
  fail by name when unset rather than acting on a placeholder. `domain` is the
  first — no fake domain name is safe, since a certificate would be requested for
  it. The checks use an internal `demo.invalid` fixture, so `nix flake check`
  still passes on a fresh clone with nothing supplied.
- Secrets with agenix: age-encrypted files under `secrets/` with recipient rules
  in `secrets/secrets.nix`, and a `demo-host` NixOS configuration that is
  evaluated by `nix flake check` (never deployed) so the wiring is checked — a
  secret missing from the rules, or a service using a secret's value instead of
  its path, fails the gate. Committed values are deliberately fake.
- Account-specific configuration now uses nivis variables instead of literals in
  the environment: `environments/<env>.nix` declares them with fake defaults, and
  real values come from a gitignored `environments/<env>.vars.json` (passed by
  `stackctl`), `NIVIS_VAR_*`, or `--var`. Nothing real is edited into a tracked
  file, and `nix flake check` runs on the fake defaults.
