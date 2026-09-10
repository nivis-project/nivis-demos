---
# nivis-demos-x98i
title: Hetzner agenix enrolment cannot converge
status: todo
type: bug
created_at: 2026-09-10T22:36:33Z
updated_at: 2026-09-10T22:36:33Z
---

The documented four-step agenix enrolment for `030_vaultwarden_hetzner` has no
fixed point. Vaultwarden can never start.

Step 3 re-encrypts `secrets/vaultwarden-admin-token.age`. That changes the store
path, the closure, the image, `image_sha256`, the snapshot id and therefore
`hcloud_server.image`, which forces a new server. The replacement generates a
fresh ssh host key at first boot, so the token just encrypted to key *n* cannot
be decrypted by key *n+1*. Enrolling again produces key *n+2*. The loop does not
converge — it is not a rough edge, it is unreachable.

Three separate things have to be true for enrolment to work, and none are:

1. **The identity does not survive replacement.** `age.identityPaths` points at
   `/etc/ssh/ssh_host_ed25519_key`, which lives on the root disk. The root disk
   is cattle; the primary IP and the data volume are the only pets.
2. **A restore-from-volume service runs too late.** agenix installs via an
   activation script (`sysusers` is off, so `system.activationScripts.agenixInstall`),
   and NixOS activation runs inside the initrd — `initrd-nixos-activation.service`,
   `After=initrd-switch-root.target`, chrooted into `/sysroot`. Any stage-2
   systemd unit has already missed it.
3. **There was no way to read the key.** README step 2 said to log in at the
   Hetzner console, but the host has `hashedPassword = null`, no
   `initialHashedPassword`, no authorized keys and no normal users, so the
   console shows "the root account is locked". Fixed separately: the domain now
   opens tcp/22 and the README uses `ssh-keyscan`, which reads the public host
   key from the protocol banner without authenticating.

## The attempted fix, and why it was reverted

Putting the identity on the data volume and marking it `neededForBoot` solves
(1) and (2) at once: NixOS adds `x-initrd.mount`, stage 1 mounts it before
activation, and the volume outlives the server. This was implemented and
verified as far as it could be — the stage-1 fstab gained
`/dev/disk/by-label/vaultwarden /var/lib/vaultwarden ext4 x-initrd.mount,...`,
the prepare unit moved into the initrd, and `blkid`/`findmnt`/`mkfs.ext4` were
added via `initrdBin`/`extraBin` (the stage-1 base has coreutils, e2fsprogs and
LVM but no util-linux).

It was reverted because of an ordering fact that defeats it: **hcloud_server has
no `volumes` attribute** in hetznercloud/hcloud v1.68.0, so a volume can only be
attached by the separate `hcloud_volume_attachment` resource, which applies
after the server is created and already booting:

    destroy attachment -> destroy server -> create server (BOOTS, no volume)
                                         -> create attachment (volume appears)

Every replacement boots with no volume attached, so a required `neededForBoot`
mount waits out the device timeout and drops to stage-1 emergency. A retry loop
in the prepare unit only narrows the race.

## Options

- Add the safety pieces and accept the race: `nofail` so a late volume cannot
  fail the boot, `RequiresMountsFor=/var/lib/vaultwarden` on `vaultwarden.service`
  so the vault can never be written to the ephemeral root disk, and probably
  `x-systemd.automount` so a volume arriving after `local-fs.target` still mounts.
- Commit a demo host keypair so the identity is constant across replacements.
  One apply, no enrolment at all. Every secret in this repo is already fake by
  design, but it does put a private ssh host key in a public repo.
- Break the coupling instead: deliver the token so that re-keying does not change
  the image, and the server is never replaced. That is the root cause — the
  replacement exists only because the secret is baked into the image.

## Scope

- [ ] Decide which of the three shapes the demo should show
- [ ] Implement it, and make step 4 actually reach a running Vaultwarden
- [ ] Rewrite the enrolment section of README.md to match what converges
- [ ] Note in the domain why the identity is where it is, as the IP and volume
      already document why they are pets
