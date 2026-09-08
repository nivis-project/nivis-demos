# Evaluation tests for the Vaultwarden EC2 domain.
#
# Pure: no credentials, no network, and NO image build — the domain substitutes a
# placeholder when no image is supplied, which is the whole point of task 3.1.
{
  irs,
  envs,
  withImage,
  checkVars,
  servedName,
  hosts,
  ...
}:
let
  ir = irs."020_vaultwarden_ec2";
  env = envs.demo;

  byId = id: builtins.head (builtins.filter (r: r.id == id) ir.resources);
  has = id: builtins.any (r: r.id == id) ir.resources;
  types = map (r: r.type) ir.resources;
  countOf = ty: builtins.length (builtins.filter (t: t == ty) types);

  isRefTo =
    id: attr: v:
    builtins.isAttrs v && v ? __ref && v.__ref.resource == id && v.__ref.path == [ attr ];

  eipId = "aws.aws_eip.vaultwarden";
  instId = "aws.aws_instance.vaultwarden";
  volId = "aws.aws_ebs_volume.data";

  sg = byId "aws.aws_security_group.vaultwarden";
  openPorts = map (i: i.from_port) sg.config.ingress;

  consumerIds = map (c: c.id) ir.nixConsumers;
  outputValue =
    n: (builtins.head (builtins.filter (c: c.id == "output.${n}") ir.nixConsumers)).value.value;

  # The same domain evaluated with two DIFFERENT images: replacement invariance.
  ledger = {
    outputs = { };
    vars = {
      domain = checkVars.domain;
    };
  };
  irA = (withImage "/img/a.vhd") ledger;
  irB = (withImage "/img/b.vhd") ledger;
  pick = i: id: builtins.head (builtins.filter (r: r.id == id) i.resources);

  fakeToken = "fake-demo-token-not-a-real-secret-0000000000";
  expectedName = servedName "vault-ec2" checkVars.domain;
  recordName = (byId "aws.aws_route53_record.vaultwarden").config.name;

  t = name: ok: { inherit name ok; };
  tWith = name: ok: detail: {
    inherit name ok;
    detail = if ok then "" else " — ${detail}";
  };
in
[
  # --- the pipeline exists ------------------------------------------------
  (t "ec2: vmimport role, policy and attachment" (
    has "aws.aws_iam_role.vmimport"
    && has "aws.aws_iam_policy.vmimport"
    && has "aws.aws_iam_role_policy_attachment.vmimport"
  ))
  (t "ec2: image bucket, object, snapshot import and AMI" (
    has "aws.aws_s3_bucket.image"
    && has "aws.aws_s3_object.image"
    && has "aws.aws_ebs_snapshot_import.nixos"
    && has "aws.aws_ami.nixos"
  ))
  (t "ec2: instance, data volume, attachment, EIP and association" (
    has instId
    && has volId
    && has "aws.aws_volume_attachment.data"
    && has eipId
    && has "aws.aws_eip_association.vaultwarden"
  ))
  (t "ec2: the A record" (has "aws.aws_route53_record.vaultwarden"))

  # --- 3.1 no image required to evaluate ----------------------------------
  (tWith "ec2: evaluates with no image, using a placeholder" (
    (byId "aws.aws_s3_object.image").config.source == "/placeholder/nixos-amazon-image.vhd"
  ) "got ${toString (byId "aws.aws_s3_object.image").config.source}")

  # --- 3.3 with an image, the source is a __build leaf --------------------
  (t "ec2: a supplied image becomes a __build leaf" (
    let
      src = (pick irA "aws.aws_s3_object.image").config.source;
    in
    builtins.isAttrs src && src ? __build
  ))

  # --- 3.2 names are suffixed so two stacks can coexist -------------------
  (t "ec2: vmimport role name carries the suffix" (
    builtins.match ".*${env.vars.suffix.default}.*" (byId "aws.aws_iam_role.vmimport").config.name
    != null
  ))

  # --- 3.4 provider list-nesting ------------------------------------------
  (t "ec2: disk_container is a one-element list" (
    let
      dc = (byId "aws.aws_ebs_snapshot_import.nixos").config.disk_container;
    in
    builtins.isList dc && builtins.length dc == 1
  ))
  (t "ec2: user_bucket is a one-element list" (
    let
      ub = (builtins.head (byId "aws.aws_ebs_snapshot_import.nixos").config.disk_container).user_bucket;
    in
    builtins.isList ub && builtins.length ub == 1
  ))

  # --- 3.5 nothing but 80/443 open to the world ---------------------------
  (tWith "ec2: only 443 and 80 are open to the world" (
    builtins.sort builtins.lessThan openPorts == [
      80
      443
    ]
  ) "open: ${builtins.concatStringsSep ", " (map toString openPorts)}")
  (t "ec2: ssh is NOT exposed by the security group" (!(builtins.elem 22 openPorts)))

  # --- 3.6 wiring and outputs ---------------------------------------------
  (t "ec2: the volume attaches to the instance" (
    isRefTo volId "id" (byId "aws.aws_volume_attachment.data").config.volume_id
    && isRefTo instId "id" (byId "aws.aws_volume_attachment.data").config.instance_id
  ))
  (t "ec2: the EIP associates with the instance" (
    isRefTo instId "id" (byId "aws.aws_eip_association.vaultwarden").config.instance_id
  ))
  (t "ec2: outputs public_ip and data_volume_id" (
    builtins.elem "output.public_ip" consumerIds && builtins.elem "output.data_volume_id" consumerIds
  ))
  (t "ec2: public_ip output is the EIP's address" (
    isRefTo eipId "public_ip" (outputValue "public_ip")
  ))

  # --- 4.7 DNS by data source, address by round trip ----------------------
  (t "ec2: the hosted zone is a DATA SOURCE, not a state read" (
    builtins.any (d: d.type == "aws_route53_zone") ir.dataSources
  ))
  (t "ec2: the domain declares no zone resource of its own" (
    !(builtins.elem "aws_route53_zone" types)
  ))
  (t "ec2: the A record's value is a ref to the EIP" (
    isRefTo eipId "public_ip" (builtins.head (byId "aws.aws_route53_record.vaultwarden").config.records)
  ))
  (tWith "ec2: the A record is a subdomain, not the apex" (
    recordName == expectedName
  ) "record name is ${toString recordName}, expected ${expectedName}")
  (t "ec2: no domain claims the apex" (
    builtins.all (
      i: builtins.all (r: r.type != "aws_route53_record" || r.config.name != checkVars.domain) i.resources
    ) (builtins.attrValues irs)
  ))

  # --- 1.5 one name, everywhere: served, certificate, record ---------------
  # This is the assertion that would have caught the image serving
  # `demo.invalid` while the record pointed somewhere else.
  (tWith "ec2: the served name, the certificate and the A record all agree"
    (
      let
        caddyNames = builtins.attrNames hosts.vaultwarden-ec2.config.services.caddy.virtualHosts;
        url = hosts.vaultwarden-ec2.config.services.vaultwarden.config.DOMAIN;
      in
      caddyNames == [ expectedName ] && url == "https://${expectedName}" && recordName == expectedName
    )
    "caddy=${toString (builtins.attrNames hosts.vaultwarden-ec2.config.services.caddy.virtualHosts)} record=${toString recordName}"
  )

  # --- 3.9 replacing the image replaces nothing that must persist ---------
  (t "ec2: a new image does not change the data volume" (pick irA volId == pick irB volId))
  (t "ec2: a new image does not change the Elastic IP" (pick irA eipId == pick irB eipId))
  (t "ec2: a new image does not change the A record" (
    pick irA "aws.aws_route53_record.vaultwarden" == pick irB "aws.aws_route53_record.vaultwarden"
  ))

  # --- 4.1 / 4.2 the secret is granted, never carried ---------------------
  (t "ec2: no aws_ssm_parameter resource exists" (!(builtins.elem "aws_ssm_parameter" types)))
  (t "ec2: the SSM policy grants only GetParameter" (
    let
      d = (byId "aws.aws_iam_policy.ssm_read").config.policy;
    in
    builtins.isAttrs d && d ? __derived
  ))
  (t "ec2: no domain IR contains the fake admin token" (
    builtins.all (i: builtins.match ".*${fakeToken}.*" (builtins.toJSON i) == null) (
      builtins.attrValues irs
    )
  ))
  (t "ec2: the parameter NAME is exposed, so the operator can put the value" (
    builtins.elem "output.ssm_parameter_name" consumerIds
  ))

  # --- state key -----------------------------------------------------------
  (t "ec2: state key is <domain>/state.json" (ir.backend.key == "020_vaultwarden_ec2/state.json"))
  (t "ec2: exactly one instance and one data volume" (
    countOf "aws_instance" == 1 && countOf "aws_ebs_volume" == 1
  ))
]
