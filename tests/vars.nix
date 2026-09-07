# Evaluation tests for configuration variables.
#
# Pure: evaluates domains against injected ledgers. Proves both that a fresh
# clone gets the declared fake defaults, and that an override reaches BOTH the
# bucket resource and the backend declaration — the pair that must never
# disagree about which bucket holds the state.
{
  domains,
  envs,
  ...
}:
let
  env = envs.demo;
  domain = domains."000_backend";

  irWith = vars: domain ({ outputs = { }; } // (if vars == null then { } else { inherit vars; }));

  defaultIR = irWith null;
  overriddenIR = irWith { stateBucket = "a-real-looking-bucket-name"; };

  bucketOf =
    ir:
    (builtins.head (builtins.filter (r: r.id == "aws.aws_s3_bucket.state") ir.resources)).config.bucket;

  t = name: ok: { inherit name ok; };
  tWith = name: ok: detail: {
    inherit name ok;
    detail = if ok then "" else " — ${detail}";
  };
in
[
  # --- the declared default is what a fresh clone evaluates with -----------
  (tWith "vars: bucket resource uses the declared default when nothing overrides it" (
    bucketOf defaultIR == env.vars.stateBucket.default
  ) "got ${toString (bucketOf defaultIR)}")
  (tWith "vars: backend uses the declared default too" (
    defaultIR.backend.bucket == env.vars.stateBucket.default
  ) "got ${toString defaultIR.backend.bucket}")
  (t "vars: the declared default is the deliberately invalid placeholder" (
    let
      b = env.vars.stateBucket.default;
    in
    builtins.match "[a-z0-9][a-z0-9.-]*[a-z0-9]" b == null
  ))

  # --- an override reaches both halves ------------------------------------
  (tWith "vars: an injected override reaches the bucket resource" (
    bucketOf overriddenIR == "a-real-looking-bucket-name"
  ) "got ${toString (bucketOf overriddenIR)}")
  (tWith "vars: an injected override reaches the backend declaration" (
    overriddenIR.backend.bucket == "a-real-looking-bucket-name"
  ) "got ${toString overriddenIR.backend.bucket}")
  (t "vars: resource and backend never disagree about the bucket" (
    bucketOf overriddenIR == overriddenIR.backend.bucket
    && bucketOf defaultIR == defaultIR.backend.bucket
  ))

  # --- the environment declares, it does not hardcode ----------------------
  (t "vars: the environment declares stateBucket as a typed variable" (
    env.vars.stateBucket.type == "str" && env.vars ? stateBucket
  ))
  (t "vars: the environment carries no bare bucket attribute" (!(env.backend ? bucket)))

  # --- the backend stays static (IR contract) ------------------------------
  (t "vars: the resolved backend contains only plain strings" (
    builtins.all (v: builtins.isString v) (builtins.attrValues overriddenIR.backend)
  ))
]
