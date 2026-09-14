---
# nivis-demos-u4x9
title: Let S3 verify the image upload, instead of trusting that it arrived
status: todo
type: task
created_at: 2026-09-14T20:23:46Z
updated_at: 2026-09-14T20:23:46Z
---

The image uploads here set no checksum, so nothing verifies that what S3 holds
is what we built.

```
checksum_algorithm = None
source_hash        = None
```

That is how an upload that stopped at 1,053,818,880 bytes of a 1,890,006,016
byte VHD passed as a success, imported into a snapshot without complaint, and
produced an AMI that booted nothing.

## The change

On every `aws_s3_object` that carries an image:

```nix
checksum_algorithm = "SHA256";
```

The SDK then computes a checksum per part and S3 validates it server side. A
part that does not match is refused, and an upload that stops halfway cannot
complete into an object. This moves the guarantee from "we watched it" to "it
could not have happened".

Applies to 020, 040, and 030 if it grows an upload.

## Relation to the other two

- nivis-demos-1wj0 is about the image reaching the machine at all, which is
  identity, not integrity
- nixform2-sqco is the general form: nivis recording what a `__build` leaf
  produced, so the expectation exists somewhere even for providers that offer
  no checksum

Those three are the same failure seen from three sides. This one is the cheapest
and it is one line.

## Todo

- [ ] `checksum_algorithm = "SHA256"` on the image object in 040
- [ ] Same in 020
- [ ] Gate test asserting the image upload declares a checksum algorithm
- [ ] Confirm the reported `checksum_sha256` matches the local file after apply
