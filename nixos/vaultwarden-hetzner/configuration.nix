# vaultwarden-hetzner — the Hetzner host.
#
# It imports ../vaultwarden UNCHANGED. That module was written cloud-agnostic
# and this is the test of that claim: everything here is either a Hetzner fact
# (device discovery, boot layout) or a value the module already takes.
#
# The admin token arrives by agenix, not out of band as on EC2. Hetzner has no
# SSM or IAM equivalent, and the server's ssh host key is generated at first
# boot — so it cannot be a recipient when the secret is encrypted. Enrolment is
# a documented two-step: boot, read the host key, add it to secrets/secrets.nix,
# re-key, redeploy. Until that completes the token is absent and Vaultwarden
# does not start, which is the specified behaviour rather than a degraded mode.
{
  domain,
  ...
}:
{
  config,
  pkgs,
  modulesPath,
  ...
}:
let
  dataLabel = "vaultwarden";
in
{
  imports = [
    # Hetzner Cloud is KVM and presents everything over virtio — the system
    # disk as virtio-scsi (hence /dev/sda and the scsi-0HC_Volume_* ids the
    # unit below looks for). The stock initrd module set is bare-metal (ahci,
    # nvme, ata_piix) and carries no virtio driver, so Linux would see no disk
    # at all: GRUB loads the kernel over BIOS INT13h, then the root device
    # never appears and stage 1 drops to emergency. This profile is what makes
    # the disk visible to the kernel.
    "${modulesPath}/profiles/qemu-guest.nix"

    (import ../vaultwarden {
      inherit domain;
      dataDevice = "/dev/disk/by-label/${dataLabel}";
      adminTokenPath = config.age.secrets.vaultwarden-admin-token.path;
    })
  ];

  # Decrypted at activation with the host's own ssh key, whose public half must
  # already be a recipient in secrets/secrets.nix.
  age.secrets.vaultwarden-admin-token.file = ../../secrets/vaultwarden-admin-token.age;
  age.identityPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  # --- first boot: label the data volume ---------------------------------
  # Same contract as the EC2 host, different device naming: a Hetzner volume
  # appears as /dev/disk/by-id/scsi-0HC_Volume_<id>, and that id is not known
  # when this image is built. Discovery is therefore the platform-specific part
  # and lives here; the module only ever sees a label.
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
      for dev in /dev/disk/by-id/scsi-0HC_Volume_* /dev/sdb /dev/sdc; do
        [ -b "$dev" ] || continue
        [ "$dev" = "$root_src" ] && continue
        # Only a device with NO signature at all is formatted, so a volume that
        # already holds a vault can never be wiped here.
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

  # --- boot ---------------------------------------------------------------
  # Hetzner Cloud x86 boots legacy BIOS (SeaBIOS); only the ARM `cax*` line is
  # UEFI. A UEFI-only image gets as far as SeaBIOS printing "Booting from Hard
  # Disk" and then stops, because a GPT+ESP disk carries no MBR bootloader for
  # it to chain into. So this host is GRUB on an MBR disk, from the `raw` image
  # variant — the one real cost of diverging from the infra repo's ARM.
  boot.loader.grub.enable = true;
  # Hetzner presents SCSI: the system disk is sda, volumes are sdb onwards.
  # The `raw` variant defaults this to /dev/vda, which is not what boots here.
  boot.loader.grub.devices = [ "/dev/sda" ];
  boot.loader.systemd-boot.enable = false;

  # The raw image defines this itself, but only inside the image variant — the
  # base configuration does not get it, so `system.build.toplevel` fails its
  # root-filesystem assertion without it. Declaring the same value keeps the
  # host evaluable on its own, which is also what makes
  # `nixos-rebuild --target-host` usable for the host-key enrolment step.
  # Value matches nixos/modules/virtualisation/disk-image.nix exactly. There is
  # no /boot entry: a legacy image has no ESP.
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    autoResize = true;
    fsType = "ext4";
  };

  services.openssh.enable = true;
  # 22 is open here because you genuinely need a way in to enrol the host key —
  # that is the second step of the secret bootstrap, not an oversight. The
  # firewall in the domain narrows what reaches it.
  networking.firewall.allowedTCPPorts = [
    22
    80
    443
  ];

  system.stateVersion = "25.05";
}
