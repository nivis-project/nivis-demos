# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- `plan` after a successful `apply` reported the EC2 demo's SSM policy as
  changed, every time, even though the applied policy was correct. Its document
  was derived from a data source at run time, which cannot be resolved while
  planning; it is now built from the account id you already supply as a
  variable. A plan with no changes is now empty.

- The Hetzner demo failed on its first apply because the hcloudimage provider
  binary had never been built: nivis execs a provider by path, and nothing
  realised it. The provider is now part of the dev shell, so
  `nix develop -c ./stackctl …` guarantees it exists.

- The EC2 demo's image was never actually wired up: the domain shipped a
  placeholder path, the builder was called with a missing argument, and the
  image attribute did not exist in this nixpkgs. All three were invisible to the
  checks, which probed the value's shape without evaluating it.
- The vault's data volume was mounted at a device path that could never resolve
  — the AWS by-id path contains the volume's own id, unknown when the image is
  built. It is now mounted by filesystem label, prepared on first boot, so the
  mount works on a machine the image never saw and survives replacement.

- The EC2 demo could not be applied. Its machine image was built with the
  checks-only fixture name baked in, so it served `demo.invalid` and would
  request a certificate for a name nobody owns. Images are now built for the
  name the deployment actually serves.
- `versioning_configuration` on the state bucket was an attrset where the AWS
  provider requires a one-element list, so the very first `apply` failed
  part-way through creating the bucket.
- The AWS region was written twice — once for the provider, once for the state
  backend — with nothing keeping them in step. One variable now feeds both.

### Changed

- Requires nivis >= 0.6.1: `plan` fails on any domain that builds an image
  before that release.

- Requires nivis >= 0.6.0. Building a machine image during an apply needs the
  `__build` fix from that release: before it, nivis could only substitute a
  prebuilt path, so a locally-built image failed with "no substituter that can
  build it".

- Each demo is served at its own name under your domain (`vault-ec2.<domain>`)
  instead of the apex, so several demos coexist and the apex stays yours.
  **Breaking** if you already applied the EC2 demo: its record moves and a
  certificate re-issues for the new name.
- The AWS account is now pinned by a required `awsAccountId` variable wired to
  the provider's `allowed_account_ids`, so an apply with credentials for another
  account fails before creating anything. Hetzner needs no equivalent: its API
  tokens are project-scoped.

### Added

- Vaultwarden on Hetzner (`stack/030_vaultwarden_hetzner`): the same workload as
  the EC2 demo, importing `nixos/vaultwarden` unchanged. A NixOS image built by
  this repo is uploaded and snapshotted by our own hcloudimage provider, and the
  server boots straight from it. Mixed-cloud in one apply: Hetzner server,
  volume and address, with the DNS record in AWS Route 53 fed by the address
  Hetzner allocates.
- The admin token on Hetzner uses agenix, with the server enrolled as a
  recipient after its first boot — a documented two-step, during which
  Vaultwarden stays down rather than serving an unauthenticated admin page.

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
- Vaultwarden on EC2 (`stack/020_vaultwarden_ec2`): a NixOS image built by this
  repo becomes an AMI and is launched behind Caddy with TLS. The vault lives on
  its own EBS volume and the address on an Elastic IP, so replacing the machine
  keeps both — and the A record is bound from the allocated address inside the
  same apply. Applying it costs money and needs a delegated domain.
- The Vaultwarden workload is a cloud-agnostic NixOS module (`nixos/vaultwarden`),
  so the coming Hetzner demo imports it unchanged.
- Secrets for cloud hosts are delivered out of band: the domain grants the
  instance permission to read one SSM parameter by name, and the value is put
  there with `aws ssm put-parameter`. No secret value enters an IR, a plan, or a
  state file.
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
