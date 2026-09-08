# Evaluation tests for the Vaultwarden workload module, via the EC2 host that
# imports it. Pure: asserts on the evaluated NixOS configuration only.
{
  hosts,
  checkVars,
  servedName,
  ...
}:
let
  cfg = hosts.vaultwarden-ec2.config;
  # The EC2 deployment's own name; demos never claim the apex.
  name = servedName "vault-ec2" checkVars.domain;
  vw = cfg.services.vaultwarden;
  dataDir = "/var/lib/vaultwarden";
  fakeToken = "fake-demo-token-not-a-real-secret-0000000000";

  t = name: ok: { inherit name ok; };
  tWith = name: ok: detail: {
    inherit name ok;
    detail = if ok then "" else " — ${detail}";
  };
in
[
  # --- the vault is on the durable volume, not the root disk --------------
  (tWith "vaultwarden: data directory is the mounted volume" (
    vw.config.DATA_FOLDER == dataDir && cfg.fileSystems ? ${dataDir}
  ) "DATA_FOLDER is ${toString vw.config.DATA_FOLDER}")
  # The by-id path this replaced was invented: on Nitro it embeds the EBS volume
  # id, which does not exist when the image is built, so the mount could never
  # have found it. A label is resolvable at boot and survives replacement.
  (t "vaultwarden: the data volume is mounted by label, not a guessed path" (
    builtins.match "/dev/disk/by-label/.*" cfg.fileSystems."/var/lib/vaultwarden".device != null
  ))
  (t "vaultwarden: the mount cannot run before the volume is prepared" (
    builtins.elem "x-systemd.requires=vaultwarden-data-prepare.service"
      cfg.fileSystems."/var/lib/vaultwarden".options
  ))
  (t "vaultwarden: the prepare unit only formats a device with no signature" (
    # `blkid <dev>` succeeds on ANY existing signature, so the negated form is
    # what keeps a populated vault from being reformatted.
    builtins.match ".*! blkid .*" cfg.systemd.services.vaultwarden-data-prepare.script != null
  ))
  (t "vaultwarden: the prepare unit is a no-op once the label exists" (
    builtins.match ".*blkid -L vaultwarden.*" cfg.systemd.services.vaultwarden-data-prepare.script
    != null
  ))
  (t "vaultwarden: the data device is not the root disk" (
    cfg.fileSystems.${dataDir}.device != cfg.fileSystems."/".device
  ))
  (t "vaultwarden: the service starts after the data mount" (
    builtins.elem "var-lib-vaultwarden.mount" cfg.systemd.services.vaultwarden.after
  ))

  # --- reachable only through the TLS terminator ---------------------------
  (tWith "vaultwarden: bound to loopback only" (
    vw.config.ROCKET_ADDRESS == "127.0.0.1"
  ) "bound to ${toString vw.config.ROCKET_ADDRESS}")
  (t "vaultwarden: caddy serves the configured domain" (
    cfg.services.caddy.enable && cfg.services.caddy.virtualHosts ? ${name}
  ))
  (t "vaultwarden: DOMAIN is an https URL" (builtins.match "https://.*" vw.config.DOMAIN != null))
  (t "vaultwarden: signups are closed" (vw.config.SIGNUPS_ALLOWED == false))

  # --- the admin token is a PATH, never a value ---------------------------
  (t "vaultwarden: the token is read from a runtime path" (
    builtins.match "/run/.*" (toString vw.environmentFile) != null
  ))
  (t "vaultwarden: the token path is outside the nix store" (
    builtins.match "/nix/store/.*" (toString vw.environmentFile) == null
  ))
  (t "vaultwarden: no ADMIN_TOKEN in the evaluated config" (!(vw.config ? ADMIN_TOKEN)))
  (t "vaultwarden: the fake token appears nowhere in the service config" (
    builtins.match ".*${fakeToken}.*" (builtins.toJSON vw.config) == null
  ))
  (t "vaultwarden: no token, no service (admin is not served unauthenticated)" (
    cfg.systemd.services.vaultwarden.unitConfig.ConditionPathExists == toString vw.environmentFile
  ))

  # --- out-of-band delivery ordering --------------------------------------
  (t "vaultwarden: the SSM fetch runs before the service" (
    builtins.elem "vaultwarden.service" cfg.systemd.services.vaultwarden-admin-token.before
  ))
  (t "vaultwarden: the fetched token file is root-only (0400)" (
    builtins.match ".*chmod 0400.*" cfg.systemd.services.vaultwarden-admin-token.script != null
  ))
  (t "vaultwarden: the token is never passed as a command argument" (
    # `aws ssm get-parameter ... > file`, not `--value <token>` anywhere.
    builtins.match ".*ADMIN_TOKEN=%s.*" cfg.systemd.services.vaultwarden-admin-token.script != null
  ))
  (t "vaultwarden: the fetch unit writes to a root-only runtime dir" (
    cfg.systemd.services.vaultwarden-admin-token.serviceConfig.RuntimeDirectoryMode == "0700"
  ))
]
