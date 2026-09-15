---
# nivis-demos-0u0c
title: Move the Hetzner secret out of the image, now that it no longer has to live there
status: todo
type: task
created_at: 2026-09-15T07:13:52Z
updated_at: 2026-09-15T07:13:52Z
---

Follow-up to `nivis-demos-x98i`, which recorded that the agenix enrolment on
Hetzner cannot converge. It now has an answer, from two directions.

This bean exists rather than a note on x98i because the project instructions
allow only `status` and `openspec-link` to change on an existing task file.

## Why x98i could not converge

The admin token is encrypted to the servers ssh host key. The server generates
that key at first boot, so it cannot be a recipient when the secret is
encrypted. Re-keying therefore builds a new image, which replaces the server,
which regenerates the host key the secret was just encrypted to. Forever.

The loop closes because the secret lives in the image and the image is the
machine.

## What changed

`040_tunnel_target` now demonstrates the split against real infrastructure: a
live NixOS configuration reaching a running machine without replacing it.

```
image route   2649 MiB   ~15 min   machine replaced
live change    343 KiB        4s   same machine
```

Two ways out follow, and they are not exclusive:

1. **The secret arrives in the live configuration.** It stops being part of the
   image, so re-keying no longer replaces the machine and the loop has nothing
   to close on. This is what the split buys.
2. **Push the host key instead of generating it.** Elastinix does this in
   `instance/script/local_exec_upload_ssh_workloads_key.sh`: the key is created
   by the operator, encrypted to them, and pushed in. The machine never
   generates an identity nobody expected. This removes the chicken and egg
   rather than working around it, and is recorded as `nivis-tunnel-jya1`.

The second is the stronger fix and the first is the cheaper one. Doing the
first is also a second, independent demonstration of the split, which is worth
something in a repo whose purpose is to show it off.

## Note

030 is currently destroyed. Reviving it costs a Hetzner server by the hour, so
this is not urgent, and the two-step enrolment in the README stays accurate
until it is done.

## Todo

- [ ] Decide between delivering the secret live, pushing the host key, or both
- [ ] If live: a `nixos_activation` in 030, which also needs an agent in the
      Hetzner image and a stream id for it
- [ ] Update the README, whose two-step enrolment describes the problem rather
      than a solution
- [ ] Close x98i when its loop is actually broken, not when it is explained
