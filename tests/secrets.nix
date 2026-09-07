# Evaluation tests for the agenix wiring.
#
# Pure: asserts on the demo host's evaluated configuration and on the recipient
# rules. No decryption, no age identity, no credentials — the point is that the
# wiring is checked, not that the ciphertext can be opened here.
{
  hosts,
  secretsRules,
  irs,
  ...
}:
let
  toList = v: if builtins.isList v then v else [ v ];
  cfg = hosts.vaultwarden-ec2.config;
  secretName = "vaultwarden-admin-token";
  fakeToken = "fake-demo-token-not-a-real-secret-0000000000";

  declaredSecrets = builtins.attrNames cfg.age.secrets;
  ruleFiles = builtins.attrNames secretsRules;

  unit = cfg.systemd.services.vaultwarden.serviceConfig;
  secretPath = toString cfg.services.vaultwarden.environmentFile;

  # Any host that DOES decrypt a committed file must have every secret it
  # declares present in secrets/secrets.nix — nobody could have encrypted it to a
  # recipient otherwise. No host decrypts one today (the cloud host reads its
  # secret out of band), so this holds vacuously and stays as the guard for the
  # next host that does.
  undeclared = builtins.concatMap (
    h:
    builtins.filter (n: !(builtins.elem "${n}.age" ruleFiles)) (
      builtins.attrNames (h.config.age.secrets or { })
    )
  ) (builtins.attrValues hosts);

  t = name: ok: { inherit name ok; };
  tWith = name: ok: detail: {
    inherit name ok;
    detail = if ok then "" else " — ${detail}";
  };
in
[
  # --- recipient rules still guard any decrypting host --------------------
  (tWith "secrets: every secret any host declares has a rule in secrets/secrets.nix" (
    undeclared == [ ]
  ) "undeclared: ${builtins.concatStringsSep ", " undeclared}")
  (t "secrets: the committed rule names at least one recipient" (
    builtins.length secretsRules."${secretName}.age".publicKeys >= 1
  ))

  # --- consumed by PATH, never by value ------------------------------------
  # EnvironmentFile is a LIST: the nixpkgs module contributes a store-path file
  # holding the non-secret config, and the secret arrives as a separate runtime
  # path. Both is correct; what matters is that the secret is one of them, and
  # that no secret is in the store-path one (asserted elsewhere).
  (tWith "secrets: the service reads the secret through its runtime path" (builtins.elem secretPath (
    map toString (toList unit.EnvironmentFile)
  )) "EnvironmentFile is ${toString unit.EnvironmentFile}, expected it to include ${secretPath}")
  (t "secrets: the runtime path is outside the nix store" (
    builtins.match "/nix/store/.*" secretPath == null
  ))
  (t "secrets: the plaintext token is not in the unit definition" (
    builtins.match ".*${fakeToken}.*" (builtins.toJSON unit) == null
  ))
  (t "secrets: the plaintext token is not in the host's evaluated service config" (
    builtins.match ".*${fakeToken}.*" (builtins.toJSON cfg.services.vaultwarden.config) == null
  ))

  # --- out-of-band delivery: the EC2 host is not a recipient ---------------
  # Its ssh host key is generated at first boot, so it cannot be declared in
  # secrets/secrets.nix. It reads its secret at runtime instead — but the rule
  # that no secret reaches the infrastructure layer still holds.
  (t "secrets: the demonstrating host declares no age secrets" ((cfg.age.secrets or { }) == { }))
  (t "secrets: it still consumes its secret by runtime path" (
    builtins.match "/run/.*" secretPath != null
  ))

  # --- secrets stop at the host boundary -----------------------------------
  (t "secrets: no domain IR contains the token" (
    builtins.all (ir: builtins.match ".*${fakeToken}.*" (builtins.toJSON ir) == null) (
      builtins.attrValues irs
    )
  ))
]
