---
# nivis-demos-e6ct
title: Secrets with agenix
status: completed
type: epic
priority: normal
created_at: 2026-09-07T14:44:54Z
updated_at: 2026-09-07T18:54:30Z
openspec-link: openspec/changes/archive/2026-09-07-agenix-secrets
parent: nivis-demos-78i0
---

agenix for secrets, with sample environments containing deliberately fake values so the repo stays public and clonable.

## Summary of Changes

Shipped as OpenSpec change `agenix-secrets` (archived `openspec/changes/archive/2026-09-07-agenix-secrets` in the shared `nivis` store).

- `secrets/secrets.nix` recipient rules + `secrets/vaultwarden-admin-token.age`, encrypted to the maintainer's key only. The value inside is deliberately fake.
- `nixos/demo-host`: a NixOS host evaluated by `nix flake check` and never deployed, so the wiring is *checked* — verified that a host declaring a secret absent from `secrets.nix` fails the gate.
- The secret is consumed by **path** (`EnvironmentFile`), never by value; tests assert the plaintext appears in no unit, no age config, and no domain IR.
- Account-specific config moved to nivis variables: `environments/demo.nix` declares `stateBucket` with a fake default; real values come from a gitignored `environments/demo.vars.json` (passed by `stackctl` as `--var-file`), `NIVIS_VAR_*`, or `--var`.
- 46 eval assertions + 9 stackctl script assertions.

**Two corrections found by implementing rather than assuming:**
- `agenix -r` (and `agenix -e` on an existing file) cannot be used by a cloner: both decrypt before re-encrypting. The documented path is `rm secrets/*.age` then recreate. The first draft of `secrets.nix` said `-r`; that was wrong and is fixed.
- `qt2d`'s "agenix ... including environment file" was deliberately not followed: encrypting the environment would force every cloner through a re-key before they could set a bucket name, and bucket names are not secrets.

Specs: `demos-secrets` (new, 4 requirements); `demos-catstack-layout` and `demos-state-backend` modified.
