# 010_dns — the hosted zone for this environment's domain.
#
# Its own domain on purpose: a zone outlives every machine that answers to it.
# Folding it into a workload would mean `destroy` on that workload deletes the
# zone, and you would have to re-delegate at your registrar to bring the demo
# back. The zone is a pet; the machine is cattle.
#
# One-time, per environment, after the first apply:
#
#   ./stackctl demo 010_dns output      # prints name_servers
#   -> set those name servers at your registrar
#
# Nothing needing a certificate can work until that delegation propagates.
{ nivis, env }:
ledger:
let
  inherit (nivis)
    mkResource
    mkProvider
    toIR
    mkVars
    ;

  vars = mkVars env.vars (ledger.vars or { });

  zone = mkResource {
    provider = "aws";
    type = "aws_route53_zone";
    name = "primary";
    config = {
      name = vars.domain;
      comment = "nivis-demos ${env.name} — managed by nivis";
      tags = env.tags;
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
    key = "010_dns/state.json";
  };

  resources = [ zone ];

  outputs = {
    # Set these at your registrar. Read them with:
    #   ./stackctl demo 010_dns output
    name_servers = zone.refAttr "name_servers";
    zone_id = zone.refAttr "zone_id";
  };

  inherit ledger;
}
