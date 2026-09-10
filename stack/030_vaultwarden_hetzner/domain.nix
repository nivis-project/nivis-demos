# 030_vaultwarden_hetzner — the same Vaultwarden, on Hetzner compute.
#
# The workload module is imported unchanged by nixos/vaultwarden-hetzner; only
# this domain differs from the EC2 demo. That is the point: one workload, two
# clouds, and the difference is entirely in the infrastructure layer.
#
# Mixed-cloud in one apply: the server and its volume are Hetzner, the DNS
# record is AWS Route 53, and the address Hetzner allocates flows into that
# record without an intermediate step.
#
# Persistence discipline (the server is cattle, these are the pets):
#   - the primary IP survives server replacement, so DNS never churns
#   - the volume holds the vault
{
  nivis,
  env,
  # Builds the host image for a served name, or null to stand one in. REQUIRED,
  # for the reason documented in the EC2 domain: a default of null let a real
  # apply ship a placeholder.
  mkImage,
  # The hcloudimage provider binary as a store path.
  hcloudimageBin,
}:
ledger:
let
  inherit (nivis)
    mkResource
    mkData
    mkProvider
    toIR
    mkVars
    drv
    str
    derived
    ;

  vars = mkVars env.vars (ledger.vars or { });

  # hcloud is inconsistent about id types, and nivis encodes against the real
  # schema, so every crossing has to be spelled out. The provider reports most
  # resource ids as strings (the Terraform convention) while consuming them as
  # numbers: hcloud_firewall.id is a string, hcloud_server.firewall_ids is a
  # set of numbers. `num` bridges one such crossing once the ledger has the id.
  # (hcloud_primary_ip.id is already a number, so it needs no bridge.)
  num =
    r:
    derived {
      inputs = [ r ];
      render =
        vals:
        let
          v = builtins.head vals;
        in
        if builtins.isString v then builtins.fromJSON v else v;
    };

  name = "nivis-demos-vaultwarden-${vars.suffix}";
  servedName = "vault-hetzner.${vars.domain}";

  image = mkImage { domain = servedName; };

  # hcloudimage requires image_sha256 alongside image_path, and hashFile must
  # READ the file — so this forces the image to build during EVALUATION, plan
  # included. That is unavoidable while the provider demands the hash, but it is
  # confined to a real run: the checks pass a null builder and never reach here.
  imageSource = if image != null then drv image else "/placeholder/nixos.img";
  imageSha256 =
    if image != null then
      builtins.hashFile "sha256" "${image}/${image.passthru.filePath}"
    else
      "0000000000000000000000000000000000000000000000000000000000000000";

  osImage = mkResource {
    provider = "hcloudimage";
    type = "hcloudimage_image";
    name = "os";
    config = {
      image_path = imageSource;
      image_sha256 = imageSha256;
      architecture = "x86";
      compression = "none";
      location = vars.hcloudLocation;
      labels = {
        role = "vaultwarden";
        managed-by = "nivis";
      };
    };
  };

  # The address is a pet: it outlives every server booted behind it, so the DNS
  # record stays valid across a replacement.
  primaryIp = mkResource {
    provider = "hcloud";
    type = "hcloud_primary_ip";
    name = "vaultwarden";
    config = {
      name = name;
      type = "ipv4";
      location = vars.hcloudLocation;
      assignee_type = "server";
      auto_delete = false;
    };
  };

  # 443 serves the application; 80 exists only for the ACME challenge and the
  # redirect. 22 is open because the agenix enrolment needs the server's ssh
  # host key, and reading it is the one thing that cannot be done without
  # reaching the host: there is no console login (root is locked, no keys, no
  # users) and Hetzner has no SSM equivalent. `ssh-keyscan` takes the PUBLIC
  # host key from the protocol banner before authentication, so nothing here
  # grants a login — sshd on this host accepts none.
  firewall = mkResource {
    provider = "hcloud";
    type = "hcloud_firewall";
    name = "vaultwarden";
    config = {
      name = name;
      rule = [
        {
          direction = "in";
          protocol = "tcp";
          port = "443";
          source_ips = [
            "0.0.0.0/0"
            "::/0"
          ];
          description = "HTTPS";
        }
        {
          direction = "in";
          protocol = "tcp";
          port = "22";
          source_ips = [
            "0.0.0.0/0"
            "::/0"
          ];
          description = "ssh — host-key enrolment via ssh-keyscan; no login is possible";
        }
        {
          direction = "in";
          protocol = "tcp";
          port = "80";
          source_ips = [
            "0.0.0.0/0"
            "::/0"
          ];
          description = "ACME challenge and redirect to HTTPS";
        }
      ];
    };
  };

  volume = mkResource {
    provider = "hcloud";
    type = "hcloud_volume";
    name = "data";
    config = {
      name = "${name}-data";
      size = vars.hetznerVolumeSizeGb;
      location = vars.hcloudLocation;
      # The host formats and labels it on first boot; nothing here writes to it.
      format = null;
      delete_protection = false;
    };
  };

  server = mkResource {
    provider = "hcloud";
    type = "hcloud_server";
    name = "vaultwarden";
    config = {
      name = name;
      server_type = vars.hcloudServerType;
      location = vars.hcloudLocation;
      # Our snapshot, via our own provider — the round trip that makes the
      # machine a derivation rather than an image somebody uploaded once.
      # hcloudimage types the snapshot id as an int64 (it is one), while
      # hcloud_server.image is a string that happens to accept a numeric id.
      # `str` bridges the two: it renders the resolved id once the ledger has it.
      image = str [ (osImage.refAttr "id") ];
      firewall_ids = [ (num (firewall.refAttr "id")) ];
      public_net = [
        {
          ipv4_enabled = true;
          ipv4 = primaryIp.refAttr "id";
          ipv6_enabled = true;
        }
      ];
      labels = {
        role = "vaultwarden";
        managed-by = "nivis";
      };
    };
  };

  volumeAttachment = mkResource {
    provider = "hcloud";
    type = "hcloud_volume_attachment";
    name = "data";
    config = {
      volume_id = num (volume.refAttr "id");
      server_id = num (server.refAttr "id");
      automount = false; # the host mounts by label
    };
  };

  # --- DNS: the AWS zone 010_dns created, found by data source -------------
  zone = mkData {
    provider = "aws";
    type = "aws_route53_zone";
    name = "primary";
    config = {
      name = "${vars.domain}.";
      private_zone = false;
    };
  };

  aRecord = mkResource {
    provider = "aws";
    type = "aws_route53_record";
    name = "vaultwarden";
    config = {
      zone_id = zone.refAttr "zone_id";
      name = servedName;
      type = "A";
      ttl = 60;
      # Hetzner allocates the address, AWS publishes it, in one apply.
      records = [ (primaryIp.refAttr "ip_address") ];
    };
  };
in
toIR {
  providers = {
    hcloud = mkProvider {
      source = "registry.opentofu.org/hetznercloud/hcloud";
      config = { }; # HCLOUD_TOKEN; the token is scoped to one project
    };
    # A filesystem path: nivis uses the binary directly, no registry.
    hcloudimage = mkProvider {
      source = hcloudimageBin;
      config = { };
    };
    aws = mkProvider {
      source = "registry.opentofu.org/hashicorp/aws";
      config = {
        region = vars.awsRegion;
        allowed_account_ids = [ vars.awsAccountId ];
      };
    };
  };

  backend = env.backend // {
    bucket = vars.stateBucket;
    region = vars.awsRegion;
    key = "030_vaultwarden_hetzner/state.json";
  };

  dataSources = [ zone ];

  resources = [
    osImage
    primaryIp
    firewall
    volume
    server
    volumeAttachment
    aRecord
  ];

  outputs = {
    public_ip = primaryIp.refAttr "ip_address";
    data_volume_id = volume.refAttr "id";
    server_id = server.refAttr "id";
    url = "https://${servedName}";
  };

  inherit ledger;
}
