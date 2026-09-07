# Evaluation tests for the 010_dns domain and for the required-variable
# mechanism it introduces.
#
# Pure: no credentials, no network, no real domain name. The checks evaluate
# against `checkVars` (demo.invalid); these tests also prove that fixture cannot
# reach a real run.
{
  irs,
  envs,
  domains,
  checkVars,
  ...
}:
let
  ir = irs."010_dns";
  env = envs.demo;

  zoneId = "aws.aws_route53_zone.primary";
  zone = builtins.head (builtins.filter (r: r.id == zoneId) ir.resources);

  consumerIds = map (c: c.id) ir.nixConsumers;
  outputValue =
    name: (builtins.head (builtins.filter (c: c.id == "output.${name}") ir.nixConsumers)).value.value;
  isRefTo =
    id: attr: v:
    builtins.isAttrs v && v ? __ref && v.__ref.resource == id && v.__ref.path == [ attr ];

  # Forcing a domain against a BARE ledger — what the executor supplies when no
  # value is given — must fail, because `domain` is required.
  bareEval = d: (builtins.tryEval (builtins.deepSeq (domains.${d} { outputs = { }; }) true));

  t = name: ok: { inherit name ok; };
  tWith = name: ok: detail: {
    inherit name ok;
    detail = if ok then "" else " — ${detail}";
  };
in
[
  # --- 2.1 the zone -------------------------------------------------------
  (t "010_dns: declares exactly one resource" (builtins.length ir.resources == 1))
  (t "010_dns: that resource is a route53 zone" (zone.type == "aws_route53_zone"))
  (tWith "010_dns: zone name is the resolved variable, not a literal" (
    zone.config.name == checkVars.domain
  ) "got ${toString zone.config.name}")
  (t "010_dns: zone carries the environment tags" (zone.config.tags == env.tags))

  # --- 2.2 outputs --------------------------------------------------------
  (t "010_dns: outputs name_servers" (builtins.elem "output.name_servers" consumerIds))
  (t "010_dns: outputs zone_id" (builtins.elem "output.zone_id" consumerIds))
  (t "010_dns: name_servers output references the zone" (
    isRefTo zoneId "name_servers" (outputValue "name_servers")
  ))
  (t "010_dns: zone_id output references the zone" (isRefTo zoneId "zone_id" (outputValue "zone_id")))

  # --- state key ----------------------------------------------------------
  (tWith "010_dns: state key is <domain>/state.json" (
    ir.backend.key == "010_dns/state.json"
  ) "got ${toString ir.backend.key}")
  (t "010_dns: state keys are unique across domains" (
    let
      keys = map (i: i.backend.key) (builtins.attrValues irs);
      uniq = builtins.attrNames (
        builtins.listToAttrs (
          map (k: {
            name = k;
            value = true;
          }) keys
        )
      );
    in
    builtins.length keys == builtins.length uniq
  ))

  # --- the zone owns nothing else (2.4 of the plan) ------------------------
  (t "010_dns: declares no workload resources" (
    builtins.all (r: r.type == "aws_route53_zone") ir.resources
  ))

  # --- 3.2 a required variable fails BY NAME -------------------------------
  (t "vars: 010_dns cannot be evaluated without a value for `domain`" (!(bareEval "010_dns").success))
  (t "vars: `domain` is declared with no default" (!(env.vars ? domain.default)))

  # --- 1.3 the fixture is checks-only --------------------------------------
  (t "checkVars: a bare ledger does NOT receive the fixture" (
    # If the fixture leaked into the domain function, this would succeed.
    !(bareEval "010_dns").success
  ))
  (t "checkVars: a domain not using `domain` still evaluates bare" (
    # 000_backend never reads vars.domain, so a missing required variable must
    # not poison it — variable resolution is per-variable and lazy.
    (bareEval "000_backend").success
  ))

  # --- 1.4 the fixture supplies ONLY required variables --------------------
  (tWith "checkVars: supplies only variables that are declared"
    (builtins.all (n: env.vars ? ${n}) (builtins.attrNames checkVars))
    "undeclared: ${
      builtins.concatStringsSep ", " (
        builtins.filter (n: !(env.vars ? ${n})) (builtins.attrNames checkVars)
      )
    }"
  )
  (tWith "checkVars: supplies only variables that have NO default"
    (builtins.all (n: !(env.vars.${n} ? default)) (builtins.attrNames checkVars))
    "these already have defaults: ${
      builtins.concatStringsSep ", " (
        builtins.filter (n: env.vars.${n} ? default) (builtins.attrNames checkVars)
      )
    }"
  )
  (t "checkVars: the fixture domain can never resolve (RFC 2606 .invalid)" (
    builtins.match ".*\\.invalid" checkVars.domain != null
  ))
]
