# vaultwarden-ec2 — the EC2 host. Everything cloud-specific lives here; the
# workload itself is the cloud-agnostic module in ../vaultwarden.
#
# Built as an Amazon image by the flake and launched by
# stack/020_vaultwarden_ec2. Replacing this configuration replaces the instance;
# the data volume and the Elastic IP survive that.
{
  domain,
  ssmParameterName,
  awsRegion,
  ...
}:
{
  modulesPath,
  pkgs,
  lib,
  ...
}:
let
  # Where the admin token is placed at runtime. Not in the Nix store, not in a
  # unit file — a path, written at boot by the fetch unit below.
  adminTokenPath = "/run/vaultwarden/admin-token.env";

  # The data volume as attached by the domain. Nitro instances rename block
  # devices, so this is the stable by-id path rather than the requested name.
  dataDevice = "/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_vol_data";
in
{
  imports = [
    (modulesPath + "/virtualisation/amazon-image.nix")
    (import ../vaultwarden { inherit domain dataDevice adminTokenPath; })
  ];

  # --- the secret, fetched at boot ---------------------------------------
  # The instance is AUTHORISED to read this parameter (see the domain's IAM
  # policy); the value was put there out of band. Nothing about the value is
  # known to nivis, so it never reaches an IR, a plan, or a state file.
  systemd.services.vaultwarden-admin-token = {
    description = "Fetch the Vaultwarden admin token from SSM Parameter Store";
    wantedBy = [ "multi-user.target" ];
    before = [ "vaultwarden.service" ];
    requiredBy = [ "vaultwarden.service" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      RuntimeDirectory = "vaultwarden";
      RuntimeDirectoryMode = "0700";
      UMask = "0377";
    };
    path = [
      pkgs.awscli2
      pkgs.coreutils
    ];
    script = ''
      set -euo pipefail
      token=$(aws ssm get-parameter \
        --name ${lib.escapeShellArg ssmParameterName} \
        --with-decryption \
        --region ${lib.escapeShellArg awsRegion} \
        --query Parameter.Value --output text)
      # The token never reaches a log or an argument list: it goes straight to a
      # root-only file, which is what Vaultwarden reads.
      umask 077
      printf 'ADMIN_TOKEN=%s\n' "$token" > ${adminTokenPath}
      chmod 0400 ${adminTokenPath}
    '';
  };

  # SSH is how you get in if something goes wrong; the key comes from the
  # instance's key pair via the amazon-image module's cloud-init.
  services.openssh.enable = true;
  networking.firewall.allowedTCPPorts = [ 22 ];

  system.stateVersion = "25.05";
}
