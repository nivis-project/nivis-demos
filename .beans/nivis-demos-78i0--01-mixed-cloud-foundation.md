---
# nivis-demos-78i0
title: 01 Mixed-cloud foundation
status: completed
type: milestone
priority: normal
created_at: 2026-09-07T14:44:54Z
updated_at: 2026-09-07T18:54:30Z
---

Shared groundwork every demo builds on: catstack layout, AWS playground + Hetzner project as targets, agenix secrets with checked-in fake sample environments, and S3 as remote nivis state. Nothing here is a demo in itself — it is the substrate the demos plug into.

## Summary of Changes

All three epics shipped:

- `nivis-demos-0l7l` catstack scaffold and environments
- `nivis-demos-i3la` S3 remote state backend
- `nivis-demos-e6ct` secrets with agenix

The substrate every demo plugs into now exists: catstack layout with `stackctl`, a self-managed S3 state bucket with a working three-command bootstrap, agenix secrets proven by a checked (never deployed) NixOS host, and account-specific values supplied as nivis variables so nothing real is ever edited into a tracked file. `nix flake check` runs from a fresh clone with no credentials.

Note `nivis-demos-qt2d` remains draft: its scope spans milestones 02 and 03 (Hetzner compute, EC2 demos), not just this one.
