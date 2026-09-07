---
# nivis-demos-0l7l
title: Catstack scaffold and environments
status: completed
type: epic
priority: normal
created_at: 2026-09-07T14:44:54Z
updated_at: 2026-09-07T18:11:25Z
openspec-link: openspec/changes/archive/2026-09-07-catstack-scaffold-and-state-backend
parent: nivis-demos-78i0
---

Lay out the repo catstack-style (stack/ domains, environments/, stackctl entrypoint) mirroring the private infra repo, but public and disposable.

## Summary of Changes

Shipped as OpenSpec change `catstack-scaffold-and-state-backend` (archived `openspec/changes/archive/2026-09-07-catstack-scaffold-and-state-backend` in the shared `nivis` store).

- Catstack layout: `stack/<domain>/domain.nix`, `environments/demo.nix`, and the `stackctl` entrypoint, mirroring the private `infra` repo.
- `environments/demo.nix` holds a deliberately *invalid* bucket placeholder (`REPLACE_ME-nivis-demos-state`) so AWS rejects it outright rather than creating something under an unchosen name; a test asserts it stays invalid.
- Domains are exposed as `nivis.<env>."<domain>"`; adding one needs no `stackctl` edit.
- Eval tests (`tests/*.nix`) assert on a domain's IR at flake-eval time — no credentials, no network — plus `tests/stackctl.sh` for argument handling. 28 + 6 assertions.
- Spec: `demos-catstack-layout` (4 requirements) in the store.
