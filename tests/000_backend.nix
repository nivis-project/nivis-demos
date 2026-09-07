# Evaluation tests for the 000_backend domain.
#
# Pure: asserts on the domain's IR only — no credentials, no network, no
# provider process. Returns a list of { name, ok, detail? }; flake.nix forces
# every entry, so a failure fails `nix flake check` before anything is built.
{
  irs,
  envs,
  ...
}:
let
  ir = irs."000_backend";
  env = envs.demo;

  resourceById = id: builtins.head (builtins.filter (r: r.id == id) ir.resources);
  hasId = id: builtins.any (r: r.id == id) ir.resources;

  bucketId = "aws.aws_s3_bucket.state";
  versioningId = "aws.aws_s3_bucket_versioning.state";
  pabId = "aws.aws_s3_bucket_public_access_block.state";

  # A __ref leaf pointing at <id>'s <attr>.
  isRefTo =
    id: attr: v:
    builtins.isAttrs v && v ? __ref && v.__ref.resource == id && v.__ref.path == [ attr ];

  consumerIds = map (c: c.id) ir.nixConsumers;
  edgeExists = from: to: builtins.any (e: e.from == from && e.to == to) ir.edges;

  t = name: ok: { inherit name ok; };
  tWith = name: ok: detail: {
    inherit name ok;
    detail = if ok then "" else " — ${detail}";
  };

  bucket = resourceById bucketId;
  versioning = resourceById versioningId;
  pab = resourceById pabId;
in
[
  # --- shape -------------------------------------------------------------
  (t "000_backend: IR is schemaVersion 1" (ir.schemaVersion == 1))
  (tWith "000_backend: declares exactly three resources" (
    builtins.length ir.resources == 3
  ) "got ${toString (builtins.length ir.resources)}")
  (t "000_backend: aws provider source" (
    ir.providers.aws.source == "registry.opentofu.org/hashicorp/aws"
  ))
  (tWith "000_backend: provider region comes from the environment" (
    ir.providers.aws.config.region == env.aws.region
  ) "got ${toString ir.providers.aws.config.region}")

  # --- 3.1 the bucket ----------------------------------------------------
  (t "000_backend: declares the state bucket resource" (hasId bucketId))
  (tWith "000_backend: bucket name comes from the environment, not hardcoded" (
    bucket.config.bucket == env.vars.stateBucket.default
  ) "got ${toString bucket.config.bucket}")
  (t "000_backend: bucket carries the environment tags" (bucket.config.tags == env.tags))

  # --- 3.2 versioning ----------------------------------------------------
  (t "000_backend: declares bucket versioning" (hasId versioningId))
  (t "000_backend: versioning is Enabled" (
    versioning.config.versioning_configuration.status == "Enabled"
  ))
  (t "000_backend: versioning references the bucket id" (
    isRefTo bucketId "id" versioning.config.bucket
  ))
  (t "000_backend: versioning depends on the bucket" (edgeExists bucketId versioningId))

  # --- 3.3 public access block -------------------------------------------
  (t "000_backend: declares a public access block" (hasId pabId))
  (t "000_backend: blocks public ACLs" (pab.config.block_public_acls == true))
  (t "000_backend: blocks public bucket policies" (pab.config.block_public_policy == true))
  (t "000_backend: ignores public ACLs" (pab.config.ignore_public_acls == true))
  (t "000_backend: restricts public buckets" (pab.config.restrict_public_buckets == true))
  (t "000_backend: public access block references the bucket id" (
    isRefTo bucketId "id" pab.config.bucket
  ))
  (t "000_backend: public access block depends on the bucket" (edgeExists bucketId pabId))

  # --- outputs -----------------------------------------------------------
  (t "000_backend: exposes the state_bucket output" (builtins.elem "output.state_bucket" consumerIds))
  (t "000_backend: state_bucket output is the bucket id" (
    isRefTo bucketId "id"
      (builtins.head (builtins.filter (c: c.id == "output.state_bucket") ir.nixConsumers)).value.value
  ))

  # --- backend: this domain's own state key -------------------------------
  (t "000_backend: declares a state backend" (ir ? backend))
  (t "000_backend: backend type comes from the environment" (ir.backend.type == env.backend.type))
  (tWith "000_backend: backend bucket comes from the environment" (
    ir.backend.bucket == env.vars.stateBucket.default
  ) "got ${toString ir.backend.bucket}")
  (t "000_backend: backend region comes from the environment" (
    ir.backend.region == env.backend.region
  ))
  (tWith "000_backend: state key is <domain>/state.json" (
    ir.backend.key == "000_backend/state.json"
  ) "got ${toString ir.backend.key}")
  # The backend must be static: the executor has to know where state lives
  # before it evaluates anything, so no __ref/__derived may appear in it.
  (t "000_backend: backend carries no refs or derived values" (
    builtins.all (v: builtins.isString v) (builtins.attrValues ir.backend)
  ))

  # --- state keys are unique across domains -------------------------------
  (
    let
      keys = builtins.filter (k: k != null) (
        map (ir': if ir' ? backend then ir'.backend.key else null) (builtins.attrValues irs)
      );
      uniq = builtins.attrNames (
        builtins.listToAttrs (
          map (k: {
            name = k;
            value = true;
          }) keys
        )
      );
    in
    tWith "domains do not share a state key" (
      builtins.length keys == builtins.length uniq
    ) "state keys collide: ${builtins.concatStringsSep ", " keys}"
  )

  # --- public-repo safety (2.2) ------------------------------------------
  (tWith "demo env: bucket name is a deliberately invalid placeholder" (
    let
      b = env.vars.stateBucket.default;
      valid = builtins.match "[a-z0-9][a-z0-9.-]*[a-z0-9]" b != null;
    in
    !valid
  ) "bucket ${env.vars.stateBucket.default} looks like a real S3 name; it must be invalid on purpose")
]
