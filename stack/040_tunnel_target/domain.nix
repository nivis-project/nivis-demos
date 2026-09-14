# 040_tunnel_target — a machine you can reach that admits nothing.
#
# The other demos here show a workload on two clouds. This one shows something
# narrower and, for nivis, more consequential: that a machine can be deployed to
# without ever being reachable from outside.
#
# Nothing in this domain opens a port. There is no elastic IP, no DNS record and
# no address anyone needs to know — the agent in the image dials out to a relay,
# the orchestrator dials the same relay, and the two are spliced together.
# `nivis-tunnel connect <stream id>` is the only way in, and the security group
# below is what makes that a fact rather than a claim.
#
# The image is deliberately thin. On NixOS the kernel, initrd and bootloader all
# live in the closure, so almost everything can arrive later as a pushed
# closure; what must be baked in is the agent, because without it there is no
# way in at all. That division is the point of the whole exercise.
{
  nivis,
  env,
  # Builds the bootstrap image. REQUIRED, for the reason the other two domains
  # document: a default of null let a real apply ship a placeholder.
  mkImage,
}:
ledger:
let
  inherit (nivis)
    mkResource
    mkProvider
    toIR
    mkVars
    drv
    ;

  vars = mkVars env.vars (ledger.vars or { });

  name = "nivis-tunnel-target-${vars.suffix}";

  image = mkImage {
    orchestratorPublicKey = vars.tunnelOrchestratorKey;
    streamId = vars.tunnelStreamId;
    relay = vars.tunnelRelay;
    sshPublicKey = vars.tunnelSshKey;
  };

  imageSource = if image != null then drv image else "/placeholder/nixos-amazon-image.vhd";

  # --- vmimport: lets EC2 turn our uploaded disk into a snapshot -------------
  # EC2 will not import a disk on its own behalf; it assumes a role that must
  # trust the vmimport service and be allowed to read the bucket. Same shape as
  # 020, which is where this was first made to work.
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
          "arn:aws:s3:::${vars.stateBucket}-${vars.suffix}-tunnel-image"
          "arn:aws:s3:::${vars.stateBucket}-${vars.suffix}-tunnel-image/*"
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

  imageBucket = mkResource {
    provider = "aws";
    type = "aws_s3_bucket";
    name = "image";
    config = {
      bucket = "${vars.stateBucket}-${vars.suffix}-tunnel-image";
      force_destroy = true;
      tags = env.tags;
    };
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
    name = "bootstrap";
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
    name = "bootstrap";
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

  # --- the claim, expressed as a security group -----------------------------
  # No ingress rules at all. Not "ssh from my address", not "ssh from the relay"
  # — none. The relay does not connect to this machine either; the machine
  # connects to the relay. Egress is open because dialling out is the only thing
  # it ever does.
  securityGroup = mkResource {
    provider = "aws";
    type = "aws_security_group";
    name = "target";
    config = {
      name = name;
      description = "nivis-tunnel target: no ingress, by design";
      egress = [
        {
          from_port = 0;
          to_port = 0;
          protocol = "-1";
          cidr_blocks = [ "0.0.0.0/0" ];
          description = "outbound: the relay, and nix substituters";
        }
      ];
      tags = env.tags;
    };
  };

  instance = mkResource {
    provider = "aws";
    type = "aws_instance";
    name = "target";
    config = {
      ami = ami.refAttr "id";
      instance_type = vars.tunnelInstanceType;
      vpc_security_group_ids = [ (securityGroup.refAttr "id") ];
      # It still gets a public address. That is not a way in — the security
      # group admits nothing — but it gives the port scan something to scan,
      # and a negative you cannot check is not evidence.
      associate_public_ip_address = true;
      root_block_device = [
        {
          volume_size = 12;
          volume_type = "gp3";
        }
      ];
      tags = env.tags // {
        Name = name;
      };
    };
  };
in
toIR {
  providers = {
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
    key = "040_tunnel_target/state.json";
  };

  resources = [
    imageBucket
    vmimportRole
    vmimportPolicy
    vmimportAttach
    imageObject
    snapshot
    ami
    securityGroup
    instance
  ];

  outputs = {
    # What you need to reach it, and what you need to prove you cannot.
    stream_id = vars.tunnelStreamId;
    relay = vars.tunnelRelay;
    # For the port scan. Reaching this address is supposed to fail.
    public_ip = instance.refAttr "public_ip";
    instance_id = instance.refAttr "id";
    ami_id = ami.refAttr "id";
  };

  inherit ledger;
}
