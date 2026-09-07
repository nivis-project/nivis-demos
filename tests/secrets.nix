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
  cfg = hosts.demo-host.config;
  secretName = "vaultwarden-admin-token";
  fakeToken = "fake-demo-token-not-a-real-secret-0000000000";

  declaredSecrets = builtins.attrNames cfg.age.secrets;
  ruleFiles = builtins.attrNames secretsRules;

  unit = cfg.systemd.services.demo-secret-consumer.serviceConfig;
  secretPath = cfg.age.secrets.${secretName}.path;

  # Every secret the host declares must appear in secrets/secrets.nix, or nobody
  # could have encrypted it to a recipient the host can use.
  undeclared = builtins.filter (n: !(builtins.elem "${n}.age" ruleFiles)) declaredSecrets;

  t = name: ok: { inherit name ok; };
  tWith = name: ok: detail: {
    inherit name ok;
    detail = if ok then "" else " — ${detail}";
  };
in
[
  # --- the host declares the secret ---------------------------------------
  (t "secrets: the demo host declares the vaultwarden admin token" (
    builtins.elem secretName declaredSecrets
  ))
  (tWith "secrets: every secret the host declares has a rule in secrets/secrets.nix" (
    undeclared == [ ]
  ) "undeclared: ${builtins.concatStringsSep ", " undeclared}")
  (t "secrets: the rule names at least one recipient" (
    builtins.length secretsRules."${secretName}.age".publicKeys >= 1
  ))
  (t "secrets: the host declares an identity to decrypt with" (
    builtins.length cfg.age.identityPaths >= 1
  ))

  # --- consumed by PATH, never by value ------------------------------------
  (tWith "secrets: the service reads the secret through its runtime path" (
    unit.EnvironmentFile == secretPath
  ) "EnvironmentFile is ${toString unit.EnvironmentFile}, expected ${toString secretPath}")
  (t "secrets: the runtime path is outside the nix store" (
    builtins.match "/nix/store/.*" secretPath == null
  ))
  (t "secrets: the plaintext token is not in the unit definition" (
    builtins.match ".*${fakeToken}.*" (builtins.toJSON unit) == null
  ))
  (t "secrets: the plaintext token is not in the host's age configuration" (
    builtins.match ".*${fakeToken}.*" (builtins.toJSON cfg.age.secrets) == null
  ))

  # --- secrets stop at the host boundary -----------------------------------
  (t "secrets: no domain IR contains the token" (
    builtins.all (ir: builtins.match ".*${fakeToken}.*" (builtins.toJSON ir) == null) (
      builtins.attrValues irs
    )
  ))
]
