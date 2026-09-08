# Vaultwarden, as a cloud-agnostic NixOS module.
#
# This file names NO cloud provider, instance type, or provider-specific
# resource. Everything that genuinely differs between clouds arrives as an
# argument, so the EC2 and Hetzner demos import this unchanged and differ only in
# their catstack domain.
#
#   domain          the name the certificate is issued for
#   dataDevice      block device holding the vault (NOT the root disk)
#   adminTokenPath  runtime path the admin token is placed at, by whatever
#                   mechanism the platform uses to deliver it
{
  domain,
  dataDevice,
  adminTokenPath,
  ...
}:
{ config, lib, ... }:
let
  dataDir = "/var/lib/vaultwarden";
in
{
  # --- the vault lives on its own volume ---------------------------------
  # The machine is cattle: replacing it must not lose the vault. The data
  # directory IS the mount point, so nothing is written to the root disk.
  # Mounted by LABEL, not by device path. A cloud that renames block devices
  # (AWS Nitro) or assigns an id only after the volume exists makes any baked-in
  # device path a guess — and a wrong one fails at boot, long after the apply
  # reported success. The label is stable across instance replacement, which is
  # the whole reason this volume is separate.
  #
  # The platform is responsible for a device carrying this label existing; each
  # host does that in its own first-boot unit, and declares it here with
  # x-systemd.requires so the mount cannot run before it.
  fileSystems.${dataDir} = {
    device = dataDevice;
    fsType = "ext4";
    options = [
      "x-systemd.requires=vaultwarden-data-prepare.service"
      "x-systemd.device-timeout=30s"
    ];
  };

  services.vaultwarden = {
    enable = true;
    dbBackend = "sqlite";
    config = {
      DOMAIN = "https://${domain}";
      DATA_FOLDER = dataDir;

      # Bound to loopback: the only way in is through the TLS terminator below.
      ROCKET_ADDRESS = "127.0.0.1";
      ROCKET_PORT = 8222;

      SIGNUPS_ALLOWED = false;
    };
    # The admin token is NOT in this config: it arrives as a file at runtime,
    # read by systemd below. Putting it here would place it in the Nix store.
    environmentFile = adminTokenPath;
  };

  systemd.services.vaultwarden = {
    # The vault must be mounted before the service that writes to it.
    after = [ "${lib.replaceStrings [ "/" ] [ "-" ] (lib.removePrefix "/" dataDir)}.mount" ];
    requires = [ "${lib.replaceStrings [ "/" ] [ "-" ] (lib.removePrefix "/" dataDir)}.mount" ];
    # No token file, no service. Vaultwarden reads ADMIN_TOKEN from it, and an
    # absent token means the admin page is simply not served — the service must
    # not start into a state where the admin interface exists unauthenticated.
    unitConfig.ConditionPathExists = adminTokenPath;
  };

  # --- TLS ----------------------------------------------------------------
  services.caddy = {
    enable = true;
    virtualHosts.${domain}.extraConfig = ''
      reverse_proxy 127.0.0.1:${toString config.services.vaultwarden.config.ROCKET_PORT}
    '';
  };

  # Caddy serves the ACME challenge on 80 and redirects everything else to 443;
  # no application route is bound to plain HTTP.
  networking.firewall.allowedTCPPorts = [
    80
    443
  ];
}
