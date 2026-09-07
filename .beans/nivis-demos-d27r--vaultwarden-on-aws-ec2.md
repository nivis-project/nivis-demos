---
# nivis-demos-d27r
title: Vaultwarden on AWS EC2
status: completed
type: epic
priority: normal
created_at: 2026-09-07T14:44:54Z
updated_at: 2026-09-07T20:06:00Z
parent: nivis-demos-z5uc
---

Vaultwarden on an EC2 instance in the personal AWS playground account, with best practices worth showing off.

## Summary of Changes

Shipped as two OpenSpec changes, both archived in the shared nivis store:

- openspec/changes/archive/2026-09-07-dns-zone
- openspec/changes/archive/2026-09-07-vaultwarden-on-ec2

**DNS (010_dns).** A Route 53 hosted zone of its own, outputting name_servers for
a one-time registrar delegation. Separate from the workload on purpose: a zone
outlives every machine, so destroying a demo must not take your name servers with
it. Introduced required configuration variables (no default, fail by name) plus a
checks-only demo.invalid fixture, since no fake domain name is safe to act on.

**Vaultwarden (020_vaultwarden_ec2).** A NixOS image built by this repo becomes
an AMI and is launched behind Caddy with TLS. The vault sits on its own EBS
volume and the address on an Elastic IP, so replacing the machine keeps both, and
the A record is bound from the allocated address inside the same apply via
nivis's round trip. The workload itself is a cloud-agnostic module
(nixos/vaultwarden) that the Hetzner demo will import unchanged.

**Secrets.** The admin token is delivered out of band: the domain grants the
instance permission to read one SSM parameter by name, and the value is put there
with aws ssm put-parameter. No secret value enters an IR, a plan, or a state file.

**Three things implementation changed:**

- The gitignored .local.nix override that was originally planned cannot work: a
  flake evaluated at "." cannot see a gitignored file, and path: copies .git and
  every ignored directory on every run. Replaced with nivis's own --var-file /
  --var / NIVIS_VAR_ mechanism, which resolves in the executor.
- nixos/demo-host was removed, but the EC2 host could not inherit its role: a
  cloud instance generates its ssh host key at first boot, so it can never be an
  agenix recipient. The demos-secrets requirement was amended so the demonstrator
  may use either delivery mechanism, since what it demonstrates is consumption by
  path.
- Deep-forcing the IR caught a wrong nivis.derived signature that lazy evaluation
  had hidden.

108 eval assertions and 9 script assertions; 3/3 domains covered; no credentials,
no network, no image build in the gate.
