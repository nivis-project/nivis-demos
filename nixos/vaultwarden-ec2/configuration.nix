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

  # By label, not by path. The by-id path on Nitro embeds the EBS volume id,
  # which does not exist when this image is built; the prepare unit below puts
  # the label on the volume at first boot.
  dataLabel = "vaultwarden";
  dataDevice = "/dev/disk/by-label/${dataLabel}";
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

  # --- first boot: give the data volume its label ------------------------
  # Finds the attached-but-blank block device and formats it. Idempotent: if a
  # filesystem with the label already exists (every boot after the first, and
  # after an instance replacement re-attaches the volume) it does nothing.
  #
  # It only ever formats a device with NO filesystem or partition signature at
  # all, so a volume holding a vault can never be wiped by it.
  systemd.services.vaultwarden-data-prepare = {
    description = "Label the Vaultwarden data volume on first boot";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [
      pkgs.util-linux
      pkgs.e2fsprogs
      pkgs.coreutils
    ];
    script = ''
      set -euo pipefail

      if blkid -L ${dataLabel} >/dev/null 2>&1; then
        echo "data volume already labelled ${dataLabel}; nothing to do"
        exit 0
      fi

      root_src=$(findmnt -no SOURCE / || true)
      for dev in /dev/nvme1n1 /dev/nvme2n1 /dev/xvdf /dev/sdf; do
        [ -b "$dev" ] || continue
        [ "$dev" = "$root_src" ] && continue
        # blkid succeeds if ANY signature is present; only a truly blank device
        # gets formatted.
        if ! blkid "$dev" >/dev/null 2>&1; then
          echo "formatting blank data volume $dev as ${dataLabel}"
          mkfs.ext4 -L ${dataLabel} "$dev"
          exit 0
        fi
      done

      echo "no blank data device found, and no volume labelled ${dataLabel}" >&2
      exit 1
    '';
  };

  # SSH is how you get in if something goes wrong; the key comes from the
  # instance's key pair via the amazon-image module's cloud-init.
  services.openssh.enable = true;
  networking.firewall.allowedTCPPorts = [ 22 ];

  system.stateVersion = "25.05";
}
