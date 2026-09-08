# Evaluation tests for the Hetzner Vaultwarden domain.
#
# Pure, and deliberately never touching the real image builder: hcloudimage
# requires image_sha256 alongside image_path, and hashFile READS the file, so
# forcing the real path would build a disk image inside the gate. The checks
# pass a null builder and assert the placeholder behaviour instead.
{
  irs,
  envs,
  checkVars,
  servedName,
  hosts,
  hetznerWithImage,
  hcloudimageBin,
  devShellPackagePaths,
  ...
}:
let
  ir = irs."030_vaultwarden_hetzner";
  env = envs.demo;

  byType = ty: builtins.head (builtins.filter (r: r.type == ty) ir.resources);
  types = map (r: r.type) ir.resources;
  has = ty: builtins.elem ty types;

  isRefTo =
    id: attr: v:
    builtins.isAttrs v && v ? __ref && v.__ref.resource == id && v.__ref.path == [ attr ];

  ipId = "hcloud.hcloud_primary_ip.vaultwarden";
  serverId = "hcloud.hcloud_server.vaultwarden";
  volId = "hcloud.hcloud_volume.data";

  expectedName = servedName "vault-hetzner" checkVars.domain;
  record = byType "aws_route53_record";
  fw = byType "hcloud_firewall";
  openPorts = map (r: r.port) fw.config.rule;

  consumerIds = map (c: c.id) ir.nixConsumers;

  ledgerA = {
    outputs = { };
    vars = {
      domain = checkVars.domain;
      awsAccountId = checkVars.awsAccountId;
      stateBucket = "check-bucket";
    };
  };

  t = name: ok: { inherit name ok; };
  tWith = name: ok: detail: {
    inherit name ok;
    detail = if ok then "" else " — ${detail}";
  };
in
[
  # --- the pipeline --------------------------------------------------------
  (t "hetzner: image, primary ip, firewall, volume, server, attachment, record" (
    has "hcloudimage_image"
    && has "hcloud_primary_ip"
    && has "hcloud_firewall"
    && has "hcloud_volume"
    && has "hcloud_server"
    && has "hcloud_volume_attachment"
    && has "aws_route53_record"
  ))
  (t "hetzner: three providers — hcloud, hcloudimage and aws in one domain" (
    builtins.sort builtins.lessThan (builtins.attrNames ir.providers) == [
      "aws"
      "hcloud"
      "hcloudimage"
    ]
  ))

  # --- no image, no build --------------------------------------------------
  (tWith "hetzner: evaluates with no image, using a placeholder" (
    (byType "hcloudimage_image").config.image_path == "/placeholder/nixos.img"
  ) "got ${toString (byType "hcloudimage_image").config.image_path}")
  (t "hetzner: the placeholder carries a placeholder hash, so nothing is hashed" (
    (byType "hcloudimage_image").config.image_sha256
    == "0000000000000000000000000000000000000000000000000000000000000000"
  ))
  (t "hetzner: the image is x86, so it builds without emulation" (
    (byType "hcloudimage_image").config.architecture == "x86"
  ))

  # --- the server boots OUR snapshot ---------------------------------------
  (t "hetzner: the server boots the snapshot this repo produced" (
    isRefTo "hcloudimage.hcloudimage_image.os" "id" (byType "hcloud_server").config.image
  ))
  (t "hetzner: the server uses the reserved primary IP" (
    isRefTo ipId "id" (builtins.head (byType "hcloud_server").config.public_net).ipv4
  ))
  (t "hetzner: the volume attaches to the server" (
    isRefTo volId "id" (byType "hcloud_volume_attachment").config.volume_id
    && isRefTo serverId "id" (byType "hcloud_volume_attachment").config.server_id
  ))
  (t "hetzner: the host mounts the volume itself, so hcloud must not" (
    (byType "hcloud_volume_attachment").config.automount == false
  ))
  (t "hetzner: the primary IP is not deleted with the server" (
    (byType "hcloud_primary_ip").config.auto_delete == false
  ))

  # --- firewall ------------------------------------------------------------
  (tWith "hetzner: only 443 and 80 are open to the world" (
    builtins.sort builtins.lessThan openPorts == [
      "443"
      "80"
    ]
  ) "open: ${builtins.concatStringsSep ", " openPorts}")

  # --- DNS: Hetzner address, AWS zone, one apply ---------------------------
  (t "hetzner: the zone is an AWS data source, not a state read" (
    builtins.any (d: d.type == "aws_route53_zone") ir.dataSources
  ))
  (tWith "hetzner: served at its own subdomain" (
    record.config.name == expectedName
  ) "record is ${toString record.config.name}, expected ${expectedName}")
  (t "hetzner: the two demos do not share a record name" (
    let
      ec2Record = builtins.head (
        builtins.filter (r: r.type == "aws_route53_record") irs."020_vaultwarden_ec2".resources
      );
    in
    record.config.name != ec2Record.config.name
  ))
  (t "hetzner: neither demo claims the apex" (
    builtins.all (
      i: builtins.all (r: r.type != "aws_route53_record" || r.config.name != checkVars.domain) i.resources
    ) (builtins.attrValues irs)
  ))

  # --- the image path, exercised with a stand-in ---------------------------
  (t "hetzner: a supplied image becomes a __build leaf" (
    let
      src =
        (builtins.head (
          builtins.filter (r: r.type == "hcloudimage_image") ((hetznerWithImage "a") ledgerA).resources
        )).config.image_path;
    in
    builtins.deepSeq src (builtins.isAttrs src && src ? __build)
  ))
  (t "hetzner: a supplied image is hashed for real, not with the placeholder" (
    let
      sha =
        (builtins.head (
          builtins.filter (r: r.type == "hcloudimage_image") ((hetznerWithImage "a") ledgerA).resources
        )).config.image_sha256;
    in
    builtins.deepSeq sha (
      builtins.match "[0-9a-f]{64}" sha != null && builtins.match "0{64}" sha == null
    )
  ))
  (t "hetzner: a new image replaces neither the volume, the IP, nor the record" (
    let
      pick =
        tag: ty:
        builtins.head (builtins.filter (r: r.type == ty) ((hetznerWithImage tag) ledgerA).resources);
    in
    builtins.all (ty: pick "a" ty == pick "b" ty) [
      "hcloud_volume"
      "hcloud_primary_ip"
      "aws_route53_record"
    ]
  ))
  (t "hetzner: the A record is fed by the Hetzner primary IP" (
    isRefTo ipId "ip_address" (builtins.head record.config.records)
  ))

  # --- outputs and state ---------------------------------------------------
  (t "hetzner: outputs public_ip, data_volume_id and url" (
    builtins.elem "output.public_ip" consumerIds
    && builtins.elem "output.data_volume_id" consumerIds
    && builtins.elem "output.url" consumerIds
  ))
  (t "hetzner: state key is <domain>/state.json" (
    ir.backend.key == "030_vaultwarden_hetzner/state.json"
  ))

  # --- the provider binary must actually exist at apply time ---------------
  # nivis execs the provider by path. The IR carries that path as a plain
  # string, so nothing realises it: if the package was never built, the apply
  # dies with ENOENT on a path that looks perfectly valid. Keeping it in the
  # devShell is what guarantees `nix develop -c ./stackctl ...` has it, and this
  # asserts the two have not drifted apart.
  (tWith "hetzner: the provider binary comes from a package in the devShell" (builtins.any
    (pkgPath: builtins.substring 0 (builtins.stringLength pkgPath) hcloudimageBin == pkgPath)
    devShellPackagePaths
  ) "the provider path ${hcloudimageBin} is under no devShell package, so nothing builds it")

  # --- the reuse claim, checked --------------------------------------------
  # demos-vaultwarden says a second cloud reuses the module unchanged. Both
  # hosts must therefore agree on everything the module decides, and differ
  # only in what the platform forces.
  (t "hetzner: the host serves the same Vaultwarden config shape as EC2" (
    let
      h = hosts.vaultwarden-hetzner.config.services.vaultwarden.config;
      e = hosts.vaultwarden-ec2.config.services.vaultwarden.config;
    in
    h.ROCKET_ADDRESS == e.ROCKET_ADDRESS
    && h.DATA_FOLDER == e.DATA_FOLDER
    && h.SIGNUPS_ALLOWED == e.SIGNUPS_ALLOWED
  ))
  (t "hetzner: both hosts mount the vault by the same label" (
    hosts.vaultwarden-hetzner.config.fileSystems."/var/lib/vaultwarden".device
    == hosts.vaultwarden-ec2.config.fileSystems."/var/lib/vaultwarden".device
  ))
  (t "hetzner: the host reads its token by path, like EC2" (
    builtins.match "/run/.*" (
      toString hosts.vaultwarden-hetzner.config.services.vaultwarden.environmentFile
    ) != null
  ))
]
