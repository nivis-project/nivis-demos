# Every AWS domain must refuse to act on an account other than the intended one.
#
# AWS credentials carry no notion of "which account did you mean" — they are
# simply whatever identity is loaded — so without this guard an apply lands
# wherever the ambient credential chain points. Hetzner needs no equivalent:
# its API tokens are project-scoped by construction.
{
  irs,
  envs,
  checkVars,
  domains,
  ...
}:
let
  env = envs.demo;
  awsDomains = builtins.filter (n: (irs.${n}.providers or { }) ? aws) (builtins.attrNames irs);

  guardOf = n: irs.${n}.providers.aws.config.allowed_account_ids or null;
  unguarded = builtins.filter (n: guardOf n != [ checkVars.awsAccountId ]) awsDomains;

  bareEval =
    d:
    builtins.tryEval (
      builtins.deepSeq (domains.${d} {
        outputs = { };
        vars = {
          domain = "x.invalid";
          stateBucket = "b";
        };
      }) true
    );

  t = name: ok: { inherit name ok; };
  tWith = name: ok: detail: {
    inherit name ok;
    detail = if ok then "" else " — ${detail}";
  };
in
[
  (t "guard: there is at least one AWS domain to guard" (builtins.length awsDomains > 0))
  (tWith "guard: every AWS domain pins allowed_account_ids to the variable" (
    unguarded == [ ]
  ) "unguarded: ${builtins.concatStringsSep ", " unguarded}")
  (t "guard: awsAccountId is declared with no default, so it cannot be guessed" (
    (env.vars ? awsAccountId) && !(env.vars.awsAccountId ? default)
  ))
  (t "guard: a domain cannot be evaluated without an account id" (!(bareEval "010_dns").success))
  (t "guard: the fixture account id is not a real AWS account" (
    checkVars.awsAccountId == "000000000000"
  ))
  (t "guard: no account id is committed in the environment" (
    builtins.match ".*[0-9]{12}.*" (builtins.toJSON env) == null
  ))
]
