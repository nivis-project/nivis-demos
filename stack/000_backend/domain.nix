# 000_backend — the state bucket itself, self-managed (chicken-and-egg by
# design, the same pattern as the private infra repo).
#
# Every other domain keeps its nivis state in this bucket under its own key.
# The one-time bootstrap (nivis >= 0.5.0) is in the repo README.
#
# NOTE: versioning keeps every state write forever and there is no lifecycle
# rule here. That is fine for a disposable demo; do not copy this domain into
# production and assume it is complete.
{ nivis, env }:
ledger:
let
  inherit (nivis)
    mkResource
    mkProvider
    toIR
    mkVars
    ;

  # Account-specific values arrive as configuration variables, resolved against
  # what the executor injected for this run (see environments/demo.nix). The
  # bucket resource and the backend below both read the SAME resolved value, so
  # they can never disagree about which bucket holds the state.
  vars = mkVars env.vars (ledger.vars or { });

  bucket = mkResource {
    provider = "aws";
    type = "aws_s3_bucket";
    name = "state";
    config = {
      bucket = vars.stateBucket;
      tags = env.tags;
    };
  };

  # Versioning is the only history of state writes: every write leaves its
  # predecessor recoverable.
  versioning = mkResource {
    provider = "aws";
    type = "aws_s3_bucket_versioning";
    name = "state";
    config = {
      bucket = bucket.refAttr "id";
      # A LIST-nested block in the AWS provider: a bare attrset is rejected at
      # apply time, exactly like disk_container/user_bucket in the EC2 domain.
      # Evaluation cannot catch this — nothing in the IR knows the provider's
      # schema — so the assertion in tests/000_backend.nix pins the shape.
      versioning_configuration = [
        {
          status = "Enabled";
        }
      ];
    };
  };

  # State is not public, ever.
  publicAccessBlock = mkResource {
    provider = "aws";
    type = "aws_s3_bucket_public_access_block";
    name = "state";
    config = {
      bucket = bucket.refAttr "id";
      block_public_acls = true;
      block_public_policy = true;
      ignore_public_acls = true;
      restrict_public_buckets = true;
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

  # This domain declares the very bucket it stores its own state in, so the
  # first apply in a fresh environment is the three-command bootstrap from
  # nivis's docs/REMOTE-STATE.md (see the repo README):
  #   ./stackctl demo 000_backend apply --backend=local
  #   ./stackctl demo 000_backend state migrate --to-remote
  #   ./stackctl demo 000_backend apply          # no changes
  # Every other domain just uses the bucket, under its own key.
  backend = env.backend // {
    bucket = vars.stateBucket;
    # Same resolved value as the provider: state cannot end up in another region.
    region = vars.awsRegion;
    key = "000_backend/state.json";
  };

  resources = [
    bucket
    versioning
    publicAccessBlock
  ];

  outputs = {
    state_bucket = bucket.refAttr "id";
  };

  inherit ledger;
}
