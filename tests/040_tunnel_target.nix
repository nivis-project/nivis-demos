# Evaluation tests for the tunnel target domain.
#
# This domain makes a claim that is almost entirely negative: the machine admits
# nothing, there is no address anyone needs, and the only way in is a tunnel.
# Negatives are exactly what a gate should hold, because they are the assertions
# that quietly stop being true.
#
# There is a worked example of that in this project's own history. A test host
# was declared with `allowedTCPPorts = [ ]` to admit nothing, and was reachable
# by ssh anyway — NixOS port lists merge rather than override, and a default
# elsewhere had already opened 22. Every other assertion passed while proving
# nothing.
{
  irs,
  envs,
  checkVars,
  hosts,
  tunnelWithLive,
  ...
}:
let
  ir = irs."040_tunnel_target";
  env = envs.demo;

  byType = ty: builtins.head (builtins.filter (r: r.type == ty) ir.resources);
  types = map (r: r.type) ir.resources;
  has = ty: builtins.elem ty types;

  # A reference OR a derived value carrying one. Nivis expresses ordering only
  # through references in a config, so an ordering-only edge shows up as a
  # derived whose rendered value deliberately ignores its input. See
  # nixform2-n7h6 for why that is a workaround rather than the intended shape.
  dependsOn =
    id: attr: v:
    let
      key = "${id}.${attr}";
    in
    builtins.isAttrs v
    && (
      (v ? __ref && v.__ref.resource == id && v.__ref.path == [ attr ])
      || (v ? __derived && builtins.elem key (v.__derived.inputs or [ ]))
    );

  isRefTo =
    id: attr: v:
    builtins.isAttrs v && v ? __ref && v.__ref.resource == id && v.__ref.path == [ attr ];

  sg = byType "aws_security_group";
  instance = byType "aws_instance";

  # Outputs reach the IR as nixConsumers named output.<name>, not as an
  # `outputs` attribute.
  consumerIds = map (c: c.id) ir.nixConsumers;
  outputs = name: builtins.elem "output.${name}" consumerIds;

  activation = byType "nixos_activation";

  boot = hosts."tunnel-target".config;
  live = hosts."tunnel-target-live".config;

  t = name: ok: { inherit name ok; };
  tWith = name: ok: detail: {
    inherit name ok;
    detail = if ok then "" else " — ${detail}";
  };
in
[
  # --- the claim, as absences ----------------------------------------------
  (tWith "tunnel target: the security group has no ingress rules at all" (
    (sg.config.ingress or [ ]) == [ ]
  ) "ingress: ${builtins.toJSON (sg.config.ingress or [ ])}")

  (tWith "tunnel target: nothing in the domain exposes the machine" (
    !has "aws_eip"
    && !has "aws_eip_association"
    && !has "aws_route53_record"
    && !has "aws_lb"
    && !has "aws_lb_listener"
  ) "types: ${builtins.concatStringsSep ", " types}")

  (t "tunnel target: egress is open, because dialling out is all it does" (
    (builtins.head sg.config.egress).protocol == "-1"
  ))

  # --- but it still has an address, so the negative can be checked ----------
  # A port scan needs something to scan. "Nothing answers" is only evidence if
  # someone can go and look.
  (t "tunnel target: the instance has a public address to scan" (
    instance.config.associate_public_ip_address == true
  ))

  (t "tunnel target: the public address is an output, for that scan" (outputs "public_ip"))

  # --- how you actually reach it -------------------------------------------
  (t "tunnel target: the stream id and relay are outputs, since they are the address" (
    outputs "stream_id" && outputs "relay"
  ))

  # --- the image chain -----------------------------------------------------
  (t "tunnel target: the instance boots the AMI this repo registered" (
    isRefTo "aws.aws_ami.bootstrap" "id" instance.config.ami
  ))

  (t "tunnel target: the AMI comes from the snapshot imported from our upload" (
    isRefTo "aws.aws_ebs_snapshot_import.bootstrap" "id"
      (builtins.head (byType "aws_ami").config.ebs_block_device).snapshot_id
  ))

  # The image must be part of the snapshot's identity.
  #
  # This is here because it failed. With a constant key, a rebuilt image
  # uploaded a new file under the same name, the snapshot import saw no change
  # to its inputs, and the AMI and the machine stayed as they were. The apply
  # reported success and the new image never reached the target. Tying the two
  # keys together is what makes the upload and the import the same object, and
  # deriving that key from the image is what makes a different image a different
  # object.
  (tWith "tunnel target: the snapshot imports the exact object we uploaded"
    (
      (builtins.head (builtins.head (byType "aws_ebs_snapshot_import").config.disk_container).user_bucket)
      .s3_key == (byType "aws_s3_object").config.key
    )
    "object key ${(byType "aws_s3_object").config.key} vs import key ${(builtins.head (builtins.head (byType "aws_ebs_snapshot_import").config.disk_container).user_bucket).s3_key}"
  )

  # amazon-image writes boot_mode = "legacy-bios" into its own image-info.json
  # on x86. Saying it here means EC2 is told rather than left to infer.
  (t "tunnel target: the AMI declares the boot mode the image was built for" (
    (byType "aws_ami").config.boot_mode == "legacy-bios"
  ))

  (t "tunnel target: the snapshot is imported from the bucket this domain owns" (
    isRefTo "aws.aws_s3_bucket.image" "id"
      (builtins.head (builtins.head (byType "aws_ebs_snapshot_import").config.disk_container).user_bucket)
      .s3_bucket
  ))

  # --- the account guard, as everywhere else here --------------------------
  (t "tunnel target: the provider is pinned to one account" (
    ir.providers.aws.config.allowed_account_ids == [ checkVars.awsAccountId ]
  ))

  (t "tunnel target: state is its own key, so it cannot disturb the other domains" (
    ir.backend.key == "040_tunnel_target/state.json"
  ))

  (t "tunnel target: it carries the environment's tags" (
    instance.config.tags ? Name && env.tags != { }
  ))

  # --- the activation ------------------------------------------------------
  # What this domain is ultimately for: changing the machine instead of
  # replacing it.

  # The closure has to be a build leaf. A literal path would apply cleanly and
  # silently stop tracking the configuration: the store path would be frozen at
  # whatever it was when someone wrote it down, and every later change would
  # deploy the old system while reporting success.
  (tWith "tunnel target: the activation's closure is a build leaf, not a literal" (
    let
      ir2 = (tunnelWithLive "a") { };
      act = builtins.head (builtins.filter (r: r.type == "nixos_activation") ir2.resources);
    in
    builtins.isAttrs act.config.closure && act.config.closure ? __build
  ) "closure is not a __build leaf")

  (tWith "tunnel target: a different live system is a different closure" (
    let
      a = builtins.head (
        builtins.filter (r: r.type == "nixos_activation") ((tunnelWithLive "a") { }).resources
      );
      b = builtins.head (
        builtins.filter (r: r.type == "nixos_activation") ((tunnelWithLive "b") { }).resources
      );
    in
    a.config.closure.__build.path != b.config.closure.__build.path
  ) "two different live systems produced the same closure path")

  # Nivis derives ordering from references alone, so without one the activation
  # could be planned in the same phase as the machine it deploys to. A closure
  # pushed to a host that is still booting is a failed apply.
  (tWith "tunnel target: the activation runs after the instance exists" (dependsOn
    "aws.aws_instance.target"
    "id"
    activation.config.stream_id
  ) "stream_id: ${builtins.toJSON activation.config.stream_id}")

  # The private key is a path the operator holds, never a value. This repo is
  # public by design, and the orchestrator key is the only secret in the system.
  (t "tunnel target: the activation takes the operator key as a path" (
    builtins.isString activation.config.key_file && activation.config.key_file != ""
  ))

  (t "tunnel target: the activation goes through the tunnel's own provider" (
    activation.provider == "nivis-tunnel" && ir.providers ? "nivis-tunnel"
  ))

  # --- image versus live system --------------------------------------------

  # The load-bearing one, and the reason live.nix imports the image's
  # configuration rather than standing beside it. switch-to-configuration
  # activates a COMPLETE description of the machine, so a unit the new
  # generation does not declare gets stopped. A live system without the agent
  # would sever the connection the activation itself arrived over, on a machine
  # whose security group admits nothing.
  (tWith "tunnel target: the live system runs the same agent as the image" (
    (live.systemd.services.nivis-tunnel-agent.serviceConfig.ExecStart or "live-none")
    == (boot.systemd.services.nivis-tunnel-agent.serviceConfig.ExecStart or "boot-none")
  ) "live: ${live.systemd.services.nivis-tunnel-agent.serviceConfig.ExecStart or "none"}")

  # If these were the same system there would be nothing to prove and nothing
  # to observe when an activation lands.
  (t "tunnel target: the live system is not the image's system" (
    live.system.build.toplevel.outPath != boot.system.build.toplevel.outPath
  ))

  (tWith "tunnel target: the marker distinguishes the two, so an activation is observable" (
    live.environment.etc."tunnel-target-generation".text
    != boot.environment.etc."tunnel-target-generation".text
  ) "both read ${boot.environment.etc."tunnel-target-generation".text}")

  # The workload belongs to the live system alone. Putting it in the image would
  # mean every change to it costs a fleet-wide machine replacement.
  (t "tunnel target: the workload is in the live system and not in the image" (
    live.services.nginx.enable && !boot.services.nginx.enable
  ))

  # A service arriving must not open anything. NixOS port lists MERGE rather
  # than override, so a workload that later defaults to opening its own port
  # would do it quietly, and the domain's central claim would be false without
  # a line of this repo having changed.
  (tWith "tunnel target: the live system still admits nothing" (
    live.networking.firewall.allowedTCPPorts == [ ] && live.networking.firewall.allowedUDPPorts == [ ]
  ) "tcp: ${builtins.toJSON live.networking.firewall.allowedTCPPorts}")
]
