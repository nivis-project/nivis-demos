---
# nivis-demos-4hf6
title: Vaultwarden on Hetzner compute
status: completed
type: epic
priority: normal
created_at: 2026-09-07T14:44:55Z
updated_at: 2026-09-08T14:39:34Z
openspec-link: openspec/changes/archive/2026-09-08-vaultwarden-on-hetzner
parent: nivis-demos-z5uc
---

The same Vaultwarden workload on Hetzner compute, booted from a Nix-built snapshot via terraform-provider-hcloudimage.

## Summary of Changes

Shipped as OpenSpec change vaultwarden-on-hetzner (archived
openspec/changes/archive/2026-09-08-vaultwarden-on-hetzner).

**The reuse claim holds.** nixos/vaultwarden is imported unchanged: both hosts
pass exactly the same three arguments (domain, dataDevice, adminTokenPath), and
tests assert the two hosts agree on the Vaultwarden config shape and mount the
vault by the same label. The module needed no edits, which is what the demo set
out to prove.

**Mixed-cloud in one apply.** Hetzner server, volume and primary IP; the DNS
record lives in AWS Route 53 and is fed by the address Hetzner allocates. Three
providers in a single domain: hcloud, hcloudimage and aws.

**The machine is a derivation.** A NixOS raw-efi image built here is uploaded and
snapshotted by our own hcloudimage provider; the server boots from that snapshot.
x86 (cx22) rather than infra's ARM, so the image builds natively anywhere.

**Secrets by agenix, enrolled after first boot.** Hetzner has no SSM, and a
server's ssh host key does not exist when the secret is encrypted, so enrolment
is a documented two-step. Vaultwarden stays down until it completes rather than
serving an unauthenticated admin page. This gave agenix a consumer again after
demo-host was retired.

19 new assertions (148 total), 4/4 domains covered, gate green in ~25s with no
image build: the checks pass a null image builder, which is what keeps
hcloudimage's required image_sha256 from forcing an eval-time build.

## Not yet validated

The Hetzner demo has never been applied - no HCLOUD_TOKEN was available. Only
its IR and host configuration are checked. The EC2 twin got as far as serving a
real page over HTTPS.

Two provider block shapes are inferred rather than verified, and only an apply
will settle them: hcloud_server.public_net and hcloud_firewall.rule are written
as one-element lists on the reading that both are TypeList in the provider
schema. The infra repo writes public_net as a bare attrset, so one of us is
wrong. If nivis rejects it, the error names the attribute and the fix is
mechanical.

Rough edge worth revisiting: the firewall exposes only 80 and 443, so reading the
host key in enrolment step 2 goes through the Hetzner web console. There is no
ssh route in from outside.
