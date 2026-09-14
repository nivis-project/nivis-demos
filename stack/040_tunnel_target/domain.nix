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

  # Builds the live system: everything the image deliberately left out. Also
  # REQUIRED, and for a sharper version of the same reason. A missing image
  # fails loudly at upload; a missing live system would apply cleanly and leave
  # the machine on its bootstrap generation, which is the failure this whole
  # domain exists to make impossible.
  mkLiveSystem,

  # The activation provider as a filesystem path. nivis execs it directly, so
  # there is no registry round-trip and no published version to pin.
  tunnelProviderBin,

  # The tunnel CLIENT as a derivation, so `drv` makes it a `__build` leaf that
  # nivis realises before apply. The provider runs it as ssh's ProxyCommand,
  # under nivis rather than in the operator's shell.
  tunnelCli,
}:
ledger:
let
  inherit (nivis)
    mkResource
    mkProvider
    toIR
    mkVars
    drv
    derived
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

  liveSystem = mkLiveSystem {
    orchestratorPublicKey = vars.tunnelOrchestratorKey;
    streamId = vars.tunnelStreamId;
    relay = vars.tunnelRelay;
    sshPublicKey = vars.tunnelSshKey;
    generation = vars.tunnelGeneration;
  };

  # The S3 key carries the image's store hash, and that is load-bearing rather
  # than tidy.
  #
  # With a constant key, the snapshot import depends on a bucket and a name that
  # never change, so a new image uploads a new file and nothing downstream
  # moves: no new snapshot, no new AMI, no new machine. The apply reports
  # success and the change never reaches the target. That happened here, and it
  # is silent, which is the worst property a deploy step can have.
  #
  # Naming the object after the image makes the image part of the snapshot's
  # identity, so the whole chain re-runs exactly when the image differs and
  # never when it does not.
  imageKey = if image != null then "${baseNameOf image.outPath}.vhd" else "placeholder.vhd";

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
      key = imageKey;
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
              s3_key = imageKey;
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
      # What the image says about itself: amazon-image builds a legacy+gpt disk
      # on x86 and writes boot_mode = "legacy-bios" into its own image-info.json.
      # Left empty, EC2 falls back to the instance type's default, which happens
      # to agree today and is one more thing that could quietly stop agreeing.
      boot_mode = "legacy-bios";
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
  # --- the point of the whole exercise --------------------------------------
  # Everything above this line builds a machine. This one line changes it.
  #
  # `closure` is a `__build` leaf: nivis realises it before apply and hands the
  # provider a store path that already exists. So a changed configuration IS a
  # changed store path, and nothing computes a hash, sets a trigger or compares
  # configurations to notice. A trigger can agree while the closure differs, and
  # differ while the closure agrees; a store path cannot do either.
  #
  # The instance id goes in even though nothing sends it anywhere. A reference
  # is how ordering is expressed here, and a closure pushed to a machine that is
  # still booting is a failed apply.
  activation = mkResource {
    provider = "nivis-tunnel";
    type = "nixos_activation";
    name = "live";
    config = {
      closure = if liveSystem != null then drv liveSystem else "/placeholder/nixos-system";
      # The stream id, wired through the instance so that the instance has to
      # exist first. Nivis expresses ordering only through references in a
      # config, and a closure pushed to a machine that is still booting is a
      # failed apply.
      #
      # The rendered value deliberately ignores its input. The id the agent
      # announces was baked into the image, which is built before any instance
      # exists, so it cannot be the instance id. And it must stay a stable
      # string: `stream_id` is ForceNew in the provider, so a value that were
      # unknown at plan time would replace this resource on every run.
      #
      # It does not become unknown, because phases resolve references against
      # the ledger before the provider is called. That is the same property the
      # `num` bridge in 030 relies on.
      stream_id = derived {
        inputs = [ (instance.refAttr "id") ];
        render = _: vars.tunnelStreamId;
      };
      relay = vars.tunnelRelay;
      # A path on the operator's machine, never a value. The private key is the
      # only secret in this system and it does not belong in a repo that is
      # public by design.
      key_file = vars.tunnelKeyFile;

      # Both of these have schema defaults in the provider, and both are set
      # here anyway. That is not belt and braces, it is a workaround for a real
      # defect: nivis sends unset optional-computed attributes as UNKNOWN in the
      # config, where Terraform sends null, and terraform-plugin-framework
      # applies a Default only for null. So the defaults never fire and the
      # provider receives empty strings.
      #
      # It cost an apply to find. The ProxyCommand came out as " connect
      # <id> ..." with its first word missing, and the shell reported
      # `Unknown command: connect`. The profile would have been empty too,
      # which would have been worse and less obvious. See nixform2-1mk0.
      #
      # The client is an absolute store path rather than a name, which is what
      # the provider's own schema recommends for exactly this situation: it runs
      # under nivis, not in the operator's shell, so being on PATH is a hope.
      tunnel_command = if tunnelCli != null then drv tunnelCli else "/placeholder/nivis-tunnel";
      profile = "/nix/var/nix/profiles/system";
    };
  };
in
toIR {
  providers = {
    # A filesystem path: nivis uses the binary directly, no registry. Same
    # shape as hcloudimage in 030, and the same trap — nothing realises this
    # string, so the package has to be in the dev shell.
    nivis-tunnel = mkProvider {
      source = tunnelProviderBin;
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
    activation
  ];

  outputs = {
    # What you need to reach it, and what you need to prove you cannot.
    stream_id = vars.tunnelStreamId;
    relay = vars.tunnelRelay;
    # For the port scan. Reaching this address is supposed to fail.
    public_ip = instance.refAttr "public_ip";
    instance_id = instance.refAttr "id";
    ami_id = ami.refAttr "id";
    # What the machine is actually running, read from it rather than remembered.
    # A manual nixos-rebuild on the target shows up here as drift.
    current_system = activation.refAttr "current_system";
  };

  inherit ledger;
}
