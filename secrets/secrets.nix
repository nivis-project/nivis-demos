# agenix recipient rules: which keys may decrypt which secret.
#
# Run `agenix -e <file>` from this directory (or `nix run github:ryantm/agenix`)
# to create or edit a secret; agenix reads this file to decide the recipients.
#
# Everything here is PUBLIC by design:
#   - Public keys are not secret material, and agenix cannot encrypt without one.
#   - The values inside the .age files are FAKE, exactly like the environment's
#     fake defaults, so the committed ciphertext protects nothing real. It is
#     here to show the shape.
#
# The secrets are encrypted to the maintainer's key only, so a clone cannot
# decrypt them. That is expected. To take ownership:
#
#   1. replace `maintainer` below with your own public key
#   2. rm secrets/*.age
#   3. agenix -e vaultwarden-admin-token.age     (put any fake value in it)
#
# Note step 2 is required, and `agenix -r` is NOT the answer: re-keying decrypts
# before it re-encrypts, so it needs an identity that can already read the file —
# which by design you do not have. `agenix -e` on an existing file fails the same
# way. Since every value here is fake, there is nothing to preserve; recreating
# them is the whole job.
#
# Private keys and age identities are NEVER committed; .gitignore blocks them.
let
  maintainer = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEY25ZaYRuKUJuVuzqK4c8dKkSxN6Cd9yhbDTa/5Njmh post@pimsnel.com";

  # Every recipient allowed to decrypt a given secret. A host would be added
  # here by its own ssh host key once it exists and needs to decrypt at boot.
  all = [ maintainer ];
in
{
  "vaultwarden-admin-token.age".publicKeys = all;
}
