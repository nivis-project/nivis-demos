---
# nivis-demos-z5uc
title: 02 Vaultwarden demos
status: completed
type: milestone
priority: normal
created_at: 2026-09-07T14:44:54Z
updated_at: 2026-09-08T14:39:48Z
---

The same service — Vaultwarden — deployed twice, once on AWS EC2 and once on Hetzner compute, so the two cloud targets can be read side by side. This is the headline pair of demos: one readable stack per provider, same workload.

## Summary of Changes

Both epics shipped:

- nivis-demos-d27r — Vaultwarden on AWS EC2 (two changes: dns-zone, vaultwarden-on-ec2, plus two follow-up fix changes)
- nivis-demos-4hf6 — Vaultwarden on Hetzner compute

The pair now demonstrates what it was meant to: one cloud-agnostic NixOS module
deployed to two clouds, differing only in the catstack domain. The EC2 side has
been applied for real and serves a page over HTTPS with a valid Let's Encrypt
certificate; the Hetzner side is checked but not yet applied.

Along the way this milestone drove three fixes into nivis itself
(nixform2-ebx5 state migration, nixform2-ebon buildable __build realisation,
nixform2-hytv plan on __build) — the demos were the first configurations to
exercise those paths normally.
