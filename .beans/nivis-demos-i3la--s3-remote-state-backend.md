---
# nivis-demos-i3la
title: S3 remote state backend
status: completed
type: epic
priority: normal
created_at: 2026-09-07T14:44:54Z
updated_at: 2026-09-07T18:11:25Z
openspec-link: openspec/changes/archive/2026-09-07-catstack-scaffold-and-state-backend
parent: nivis-demos-78i0
---

A self-managed state bucket domain and the S3 backend wiring for remote nivis state.

## Summary of Changes

Shipped as OpenSpec change `catstack-scaffold-and-state-backend` (archived `openspec/changes/archive/2026-09-07-catstack-scaffold-and-state-backend` in the shared `nivis` store).

- `stack/000_backend`: the self-managed S3 state bucket with versioning enabled and all four public-access-block restrictions on, bucket name taken from the environment.
- Per-domain state keys (`<domain>/state.json`), asserted unique across domains.
- Registered as a core domain in `flake.nix` (`coverage.coreDomains`), held to the 80% bar.

**Blocked mid-flight and unblocked upstream.** Implementation established that nivis could not move state from local to a declared S3 backend, so a domain declaring its own bucket as its backend was unappliable — filed as `nixform2-ebx5` in the nivis repo. nivis 0.5.0 shipped `nivis state migrate` and `--backend=local`; the domain now declares its backend as specified and the bootstrap is the documented three commands (see README). The flake pins nivis v0.5.0 (`68053e5`) as the floor.

- Spec: `demos-state-backend` (3 requirements) in the store.
