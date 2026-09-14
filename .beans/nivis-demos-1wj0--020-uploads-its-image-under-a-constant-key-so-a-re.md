---
# nivis-demos-1wj0
title: 020 uploads its image under a constant key, so a rebuilt image never reaches the machine
status: todo
type: bug
created_at: 2026-09-14T20:23:33Z
updated_at: 2026-09-14T20:23:33Z
---

Same hole `040_tunnel_target` had, fixed there in commit 5749514 and still open
here.

`stack/020_vaultwarden_ec2/domain.nix` uploads the image as `nixos.vhd`, a name
that never changes:

```nix
key = "nixos.vhd";
...
s3_key = "nixos.vhd";
```

`aws_ebs_snapshot_import` depends on a bucket and that key. Neither changes when
the image does, so a rebuilt image uploads a new file under the same name and
nothing downstream moves: no new snapshot, no new AMI, no new machine. The apply
reports success.

That is the worst property a deploy step can have. A step that fails is a step
you fix. A step that quietly does nothing is one you trust.

## Observed in 040

The ledger after an apply that had rebuilt the image:

```
s3 source   6f6p36r1... (new)        etag ...-506 (was ...-201)
snapshot    snap-07765dc0a0d021386   UNCHANGED
ami         ami-02f1477c07117d1c5    UNCHANGED
instance    i-0904f2989c600b9e7      UNCHANGED
```

## The fix, as applied in 040

Name the object after the image, so the image becomes part of the snapshot
identity:

```nix
imageKey = if image != null then "${baseNameOf image.outPath}.vhd" else "placeholder.vhd";
```

and a gate test tying the uploaded key to the imported one, in
`tests/040_tunnel_target.nix`.

## Note

Replacing the snapshot this way currently trips a nivis ordering bug: the
snapshot is destroyed before the AMI that holds it. See nixform2-nwnf. Until
that is fixed, the first apply after an image change needs a manual
`aws ec2 deregister-image`.

## Todo

- [ ] Derive the S3 key from the image store hash in 020
- [ ] Port the key coupling test to `tests/020_vaultwarden_ec2.nix`
- [ ] Check 030 (Hetzner) for the same shape
