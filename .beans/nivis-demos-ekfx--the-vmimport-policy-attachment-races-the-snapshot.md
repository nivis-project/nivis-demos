---
# nivis-demos-ekfx
title: The vmimport policy attachment races the snapshot import
status: todo
type: bug
created_at: 2026-09-14T21:25:59Z
updated_at: 2026-09-14T21:25:59Z
---

In both `020_vaultwarden_ec2` and `040_tunnel_target`, nothing orders the IAM
policy attachment before the snapshot import that depends on it.

```
aws_iam_role.vmimport ────┬──> aws_iam_role_policy_attachment.vmimport
aws_iam_policy.vmimport ──┘

aws_iam_role.vmimport ────────> aws_ebs_snapshot_import.bootstrap
aws_s3_bucket.image ──────────>
```

EC2 assumes the vmimport role to read the image out of S3. That read is allowed
by the policy, and the policy only applies once it is attached. The import
references the role; the attachment references the role and the policy; neither
references the other. Nivis derives ordering from references, so they are
siblings and run together:

```
Phase 2  3 nodes
  = aws.aws_iam_role_policy_attachment.vmimport  213ms
  = aws.aws_s3_object.image  143ms
  -/+ aws.aws_ebs_snapshot_import.bootstrap  7m22s
```

## Why it has never failed

An attachment finishes in a fifth of a second and an import is slow to get
going, so the attachment has always won. IAM is also eventually consistent, so
even a completed attachment is not immediately visible everywhere, which means
winning the race is not the same as being correct.

A failure would look like the import rejecting the role with an access error,
after the upload has already happened. Rare, confusing, and it would arrive
during someone else first run rather than ours.

## Two ways to fix it

**Now, with what exists**: give the snapshot a reference to the attachment. The
only honest carrier is `role_name`, rendered through a `derived` whose input is
the attachment. This is the same trick `040` uses for `stream_id`, and it has
the same cost: the IR then claims a value derives from something it does not.

**Properly**: `nixform2-n7h6` in the nivis repo, an ordering edge that is not a
value. This bean is the motivating example for it, and the cleanest outcome is
to fix it there and let both domains state the edge plainly.

Not urgent: it has never fired, and the workaround trades one defect for one
untruth. Worth holding until n7h6 lands, and worth writing down now so nobody
rediscovers it from an access error.

## Todo

- [ ] Decide: work around now, or wait for nixform2-n7h6
- [ ] Fix in `020` and `040` together, since they share the shape
- [ ] Gate test: the snapshot import depends on the policy attachment
