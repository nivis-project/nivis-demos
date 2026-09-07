# demo-host — a NixOS host that exists to be **evaluated, never deployed**.
#
# Its whole job is to make the agenix wiring real: `nix flake check` forces this
# configuration, so a secret missing from secrets/secrets.nix, or a service that
# interpolates a secret *value* instead of reading its path, fails the gate. The
# first host that actually boots arrives with the Vaultwarden demos.
{
  config,
  pkgs,
  ...
}:
{
  # The identity the host decrypts WITH. On a real machine this is the key
  # generated at first boot, and its *public* half is what you add to
  # secrets/secrets.nix so the host becomes a permitted recipient. This host is
  # never deployed, so the path is conventional rather than real.
  age.identityPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  # The encrypted file is decrypted at activation by one of the host's
  # identities and placed at config.age.secrets.<name>.path, owned by root.
  # Nothing here ever sees the plaintext at evaluation time.
  age.secrets.vaultwarden-admin-token.file = ../../secrets/vaultwarden-admin-token.age;

  # The consumer. EnvironmentFile takes a PATH: systemd reads it at start, so the
  # token never enters the unit file, the Nix store, or a process argument list.
  # Passing `config.age.secrets.<name>.path` is the whole pattern.
  systemd.services.demo-secret-consumer = {
    description = "Demo consumer of an agenix-managed secret";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      DynamicUser = true;
      EnvironmentFile = config.age.secrets.vaultwarden-admin-token.path;
      # Proves the value is available at runtime without ever printing it.
      ExecStart = "${pkgs.bash}/bin/bash -c '[ -n \"$ADMIN_TOKEN\" ]'";
    };
  };

  # Minimal facts so the configuration evaluates as a bootable system. This host
  # is never installed, so these are placeholders, not a machine description.
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };
  boot.loader.grub.device = "/dev/sda";

  system.stateVersion = "25.05";
}
