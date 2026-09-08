# 020_vaultwarden_ec2 — Vaultwarden on EC2, built from a NixOS image.
#
# The machine is a derivation: the NixOS configuration in nixos/vaultwarden-ec2
# becomes an image, which is uploaded, imported as a snapshot, registered as an
# AMI, and launched. No manual image preparation, no AMI id in the repo.
#
# Persistence discipline (the instance is cattle, these are the pets):
#   - the data volume holds the vault and survives instance replacement
#   - the Elastic IP keeps the address stable across replacement
#   - the A record therefore keeps pointing at the right machine
#
# The admin token is NOT here. The domain grants the instance permission to read
# an SSM parameter by name; the value is put there out of band. Nothing about it
# reaches this IR, a plan, or the state file.
{
  nivis,
  env,
  # Builds the host image for a given served name. Absent in the checks, so no
  # image is ever built there; a real run supplies it and the image is produced
  # for the name this deployment actually serves.
  mkImage ? null,
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
    derived
    ;

  vars = mkVars env.vars (ledger.vars or { });

  name = "nivis-demos-vaultwarden-${vars.suffix}";

  # This deployment's own name. Demos never claim the apex.
  servedName = "vault-ec2.${vars.domain}";

  # The image is a Nix BUILD OUTPUT marked with `drv`: a __build leaf the
  # executor realises before uploading. Absent (a pure IR eval in the checks), a
  # placeholder stands in so the resource shapes still evaluate without a build.
  imageSource =
    if mkImage != null then
      drv (mkImage {
        domain = servedName;
      })
    else
      "/placeholder/nixos-amazon-image.vhd";

  # Who we are, so the SSM policy can be scoped to this account rather than "*".
  caller = mkData {
    provider = "aws";
    type = "aws_caller_identity";
    name = "current";
    config = { };
  };

  ssmParameterName = "/nivis-demos/${env.name}/vaultwarden/admin-token";

  # --- vmimport: lets EC2 turn our uploaded disk into a snapshot ------------
  vmimportTrust = builtins.toJSON {
    Version = "2012-10-17";
    Statement = [
      {
        Effect = "Allow";
        Principal.Service = "vmie.amazonaws.com";
        Action = "sts:AssumeRole";
        Condition.StringEquals."sts:Externalid" = "vmimport";
      }
    ];
  };

  vmimportPolicyDoc = builtins.toJSON {
    Version = "2012-10-17";
    Statement = [
      {
        Effect = "Allow";
        Action = [
          "s3:GetBucketLocation"
          "s3:GetObject"
          "s3:ListBucket"
        ];
        Resource = [
          "arn:aws:s3:::${name}"
          "arn:aws:s3:::${name}/*"
        ];
      }
      {
        Effect = "Allow";
        Action = [
          "ec2:ModifySnapshotAttribute"
          "ec2:CopySnapshot"
          "ec2:RegisterImage"
          "ec2:Describe*"
        ];
        Resource = "*";
      }
    ];
  };

  vmimportRole = mkResource {
    provider = "aws";
    type = "aws_iam_role";
    name = "vmimport";
    config = {
      name = "${name}-vmimport";
      assume_role_policy = vmimportTrust;
      tags = env.tags;
    };
  };

  vmimportPolicy = mkResource {
    provider = "aws";
    type = "aws_iam_policy";
    name = "vmimport";
    config = {
      name = "${name}-vmimport";
      policy = vmimportPolicyDoc;
    };
  };

  vmimportAttach = mkResource {
    provider = "aws";
    type = "aws_iam_role_policy_attachment";
    name = "vmimport";
    config = {
      role = vmimportRole.refAttr "name";
      policy_arn = vmimportPolicy.refAttr "arn";
    };
  };

  # --- the image: build output -> S3 -> snapshot -> AMI --------------------
  imageBucket = mkResource {
    provider = "aws";
    type = "aws_s3_bucket";
    name = "image";
    config = {
      bucket = name;
      force_destroy = true;
      tags = env.tags;
    };
  };

  imageObject = mkResource {
    provider = "aws";
    type = "aws_s3_object";
    name = "image";
    config = {
      bucket = imageBucket.refAttr "id";
      key = "nixos.vhd";
      source = imageSource;
    };
  };

  snapshot = mkResource {
    provider = "aws";
    type = "aws_ebs_snapshot_import";
    name = "nixos";
    config = {
      role_name = vmimportRole.refAttr "name";
      # disk_container and user_bucket are LIST-nested blocks in the AWS
      # provider: a bare attrset is rejected at apply.
      disk_container = [
        {
          format = "VHD";
          user_bucket = [
            {
              s3_bucket = imageBucket.refAttr "id";
              s3_key = "nixos.vhd";
            }
          ];
        }
      ];
      tags = env.tags;
    };
  };

  ami = mkResource {
    provider = "aws";
    type = "aws_ami";
    name = "nixos";
    config = {
      name = name;
      virtualization_type = "hvm";
      root_device_name = "/dev/xvda";
      ena_support = true;
      ebs_block_device = [
        {
          device_name = "/dev/xvda";
          snapshot_id = snapshot.refAttr "id";
        }
      ];
      tags = env.tags;
    };
  };

  # --- the instance's own permissions: read ONE parameter -------------------
  instanceTrust = builtins.toJSON {
    Version = "2012-10-17";
    Statement = [
      {
        Effect = "Allow";
        Principal.Service = "ec2.amazonaws.com";
        Action = "sts:AssumeRole";
      }
    ];
  };

  instanceRole = mkResource {
    provider = "aws";
    type = "aws_iam_role";
    name = "instance";
    config = {
      name = "${name}-instance";
      assume_role_policy = instanceTrust;
      tags = env.tags;
    };
  };

  # Scoped to exactly one parameter. The secret's VALUE is never here — only the
  # permission to read it and the name it lives under.
  ssmPolicy = mkResource {
    provider = "aws";
    type = "aws_iam_policy";
    name = "ssm_read";
    config = {
      name = "${name}-ssm-read";
      # `derived` because the account id is only known after the data source is
      # read: the policy document is COMPUTED from a resolved value, and nivis
      # re-evaluates it in-apply once that value exists.
      policy = derived {
        inputs = [ (caller.refAttr "account_id") ];
        render =
          resolved:
          builtins.toJSON {
            Version = "2012-10-17";
            Statement = [
              {
                Effect = "Allow";
                Action = [ "ssm:GetParameter" ];
                Resource = "arn:aws:ssm:${vars.awsRegion}:${toString (builtins.head resolved)}:parameter${ssmParameterName}";
              }
            ];
          };
      };
    };
  };

  ssmAttach = mkResource {
    provider = "aws";
    type = "aws_iam_role_policy_attachment";
    name = "ssm_read";
    config = {
      role = instanceRole.refAttr "name";
      policy_arn = ssmPolicy.refAttr "arn";
    };
  };

  instanceProfile = mkResource {
    provider = "aws";
    type = "aws_iam_instance_profile";
    name = "instance";
    config = {
      name = "${name}-instance";
      role = instanceRole.refAttr "name";
    };
  };

  # --- network -------------------------------------------------------------
  # 443 serves the application; 80 exists only for the ACME challenge and the
  # redirect to HTTPS. Nothing else is open to the world — ssh included.
  securityGroup = mkResource {
    provider = "aws";
    type = "aws_security_group";
    name = "vaultwarden";
    config = {
      name = name;
      description = "Vaultwarden: HTTPS, plus HTTP for ACME and redirect only";
      ingress = [
        {
          from_port = 443;
          to_port = 443;
          protocol = "tcp";
          cidr_blocks = [ "0.0.0.0/0" ];
          description = "HTTPS";
        }
        {
          from_port = 80;
          to_port = 80;
          protocol = "tcp";
          cidr_blocks = [ "0.0.0.0/0" ];
          description = "ACME challenge and redirect to HTTPS";
        }
      ];
      egress = [
        {
          from_port = 0;
          to_port = 0;
          protocol = "-1";
          cidr_blocks = [ "0.0.0.0/0" ];
          description = "outbound: ACME, SSM, updates";
        }
      ];
      tags = env.tags;
    };
  };

  # --- the machine and its pets --------------------------------------------
  instance = mkResource {
    provider = "aws";
    type = "aws_instance";
    name = "vaultwarden";
    config = {
      ami = ami.refAttr "id";
      instance_type = vars.instanceType;
      vpc_security_group_ids = [ (securityGroup.refAttr "id") ];
      iam_instance_profile = instanceProfile.refAttr "name";
      tags = env.tags // {
        Name = name;
      };
    };
  };

  dataVolume = mkResource {
    provider = "aws";
    type = "aws_ebs_volume";
    name = "data";
    config = {
      availability_zone = instance.refAttr "availability_zone";
      size = vars.dataVolumeSizeGb;
      type = "gp3";
      encrypted = true;
      tags = env.tags // {
        Name = "${name}-data";
      };
    };
  };

  dataAttachment = mkResource {
    provider = "aws";
    type = "aws_volume_attachment";
    name = "data";
    config = {
      # The host mounts by-id, not by this name: Nitro renames block devices.
      device_name = "/dev/sdf";
      volume_id = dataVolume.refAttr "id";
      instance_id = instance.refAttr "id";
    };
  };

  eip = mkResource {
    provider = "aws";
    type = "aws_eip";
    name = "vaultwarden";
    config = {
      domain = "vpc";
      tags = env.tags // {
        Name = name;
      };
    };
  };

  eipAssociation = mkResource {
    provider = "aws";
    type = "aws_eip_association";
    name = "vaultwarden";
    config = {
      allocation_id = eip.refAttr "id";
      instance_id = instance.refAttr "id";
    };
  };

  # --- DNS: the zone 010_dns created, found by data source -----------------
  # A DATA SOURCE, not a remote-state read: this domain stays independent of how
  # 010_dns stores its state.
  zone = mkData {
    provider = "aws";
    type = "aws_route53_zone";
    name = "primary";
    config = {
      name = "${vars.domain}.";
      private_zone = false;
    };
  };

  # The round trip: the address EC2 allocates re-enters Nix to produce the
  # record, inside this same apply. Nobody copies an IP by hand.
  aRecord = mkResource {
    provider = "aws";
    type = "aws_route53_record";
    name = "vaultwarden";
    config = {
      zone_id = zone.refAttr "zone_id";
      name = servedName;
      type = "A";
      ttl = 60;
      records = [ (eip.refAttr "public_ip") ];
    };
  };
in
toIR {
  providers.aws = mkProvider {
    source = "registry.opentofu.org/hashicorp/aws";
    config = {
      region = vars.awsRegion;
      # Refuse to act on any account but the intended one. A wrong-account run
      # fails at plan time, before anything is created.
      allowed_account_ids = [ vars.awsAccountId ];
    };
  };

  backend = env.backend // {
    bucket = vars.stateBucket;
    # Same resolved value as the provider: state cannot end up in another region.
    region = vars.awsRegion;
    key = "020_vaultwarden_ec2/state.json";
  };

  dataSources = [
    caller
    zone
  ];

  resources = [
    vmimportRole
    vmimportPolicy
    vmimportAttach
    imageBucket
    imageObject
    snapshot
    ami
    instanceRole
    ssmPolicy
    ssmAttach
    instanceProfile
    securityGroup
    instance
    dataVolume
    dataAttachment
    eip
    eipAssociation
    aRecord
  ];

  outputs = {
    public_ip = eip.refAttr "public_ip";
    data_volume_id = dataVolume.refAttr "id";
    ssm_parameter_name = ssmParameterName;
    url = "https://${servedName}";
  };

  inherit ledger;
}
