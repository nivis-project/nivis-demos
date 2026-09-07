# nivis-demos

Self-contained demo stacks for [nivis](https://github.com/nivis-project/nivis),
the Nix-native deployment orchestrator, laid out catstack-style. Where the
private `infra` repo dogfoods nivis on real production infrastructure, this repo
exists to *show it off*: small, readable, disposable domains that read as
examples.

**This repo is public, and every account-specific value in it is deliberately
fake.** That is the design, not an unfinished TODO — see
[Before you apply anything](#before-you-apply-anything).

## Layout

| Path                        | What it is                                                |
| --------------------------- | --------------------------------------------------------- |
| `environments/demo.nix`     | the `demo` environment: region, S3 backend, tags           |
| `stack/000_backend/`        | the state bucket, self-managed (bootstrap first)           |
| `stack/010_dns/`            | the Route 53 hosted zone for your domain                    |
| `secrets/`                  | age-encrypted secrets + `secrets.nix` recipient rules       |
| `nixos/demo-host/`          | a host that proves the agenix wiring; evaluated, never deployed |
| `stackctl`                  | entrypoint: `./stackctl <env> <domain> <verb> [args...]`   |
| `tests/*.nix`               | evaluation tests over a domain's IR (no credentials)       |
| `tests/*.sh`                | script tests (e.g. `stackctl` argument handling)           |
| `scripts/coverage-gate.sh`  | the coverage half of `nix flake check`                     |

Each domain is one flake attribute (`nivis.<env>."<domain>"`) and one state key
(`<domain>/state.json`), so applying one domain can never write another's state.
Directory names carry a three-digit prefix reflecting bootstrap order.

## Requirements

- Nix with flakes enabled. `nix develop` gives you nivis, `awscli2`, `hcloud`,
  `age`, and the linters.
- For anything that actually applies: AWS credentials for your own account, via
  the standard chain (`AWS_PROFILE` / `AWS_ACCESS_KEY_ID` / ...). Credentials
  never live in this repo.

`nix flake check` needs no credentials and no cloud access — a fresh clone can
run the whole gate offline of AWS.

## Before you apply anything

`environments/demo.nix` declares the state bucket with a default **S3 cannot
accept**:

```nix
vars.stateBucket.default = "REPLACE_ME-nivis-demos-state";
```

`_` and uppercase are outside S3's bucket-naming grammar, so AWS rejects it
immediately rather than creating something under a name you did not choose. A
plausible-looking placeholder would be worse: it is squattable, and every clone's
first apply would fail with a confusing `BucketAlreadyExists` from a bucket
nobody here controls.

Supply your own globally-unique name before step 1 below — you do **not** edit
`environments/demo.nix` to do it (see [Configuration variables](#configuration-variables)):

```sh
echo '{ "stateBucket": "my-nivis-demos-state" }' > environments/demo.vars.json
```

## Bootstrap: the state bucket

`stack/000_backend` creates the very bucket it declares as its own backend — a
chicken-and-egg problem nivis solves in three commands (requires **nivis
>= 0.5.0**; see nivis's `docs/REMOTE-STATE.md`):

```sh
# 1. Apply with local state, creating the bucket. The declared backend is
#    ignored for this run only; the configuration is not modified.
./stackctl demo 000_backend apply --backend=local

# 2. Move the state document into the bucket that now exists.
./stackctl demo 000_backend state migrate --to-remote

# 3. From here on, ordinary runs use the declared backend.
./stackctl demo 000_backend apply     # reports no changes
```

That is one-time, per environment. Every other domain simply uses the bucket —
apply `000_backend` first, or the run fails with an error naming the missing
bucket and this recipe.

Local state from step 1 lands in `state/<env>/<domain>.state.json`, which is
gitignored. After step 2 it is gone: `state migrate` removes the source only
after reading the destination back and verifying it.

## DNS: the hosted zone

`stack/010_dns` manages the Route 53 hosted zone for your domain. It is a
separate domain on purpose — a zone outlives every machine that answers to it, so
destroying a demo must not take your name servers with it.

The domain name is a **required variable with no default**. The repo never learns
it, and it must never be committed:

```sh
# 1. supply your domain (gitignored; or use --var / NIVIS_VAR_domain)
echo '{ "domain": "demo.example.com" }' > environments/demo.vars.json

# 2. create the zone
./stackctl demo 010_dns apply

# 3. read the name servers
./stackctl demo 010_dns output      # -> name_servers, zone_id
```

**Then delegate, once per environment**: set those name servers as the `NS`
records for that name at your registrar. This is manual and cannot be automated
from here.

A **delegated subdomain** (`demo.example.com`) is usually the right choice: you
add NS records for just that label and your apex stays where it is. Delegating a
whole domain works too, but moves its DNS into Route 53 entirely.

Nothing that needs a certificate can work until delegation has propagated, and
propagation time is not under anyone's control here.

Forgetting the variable fails immediately, by name:

```
error: nivis.mkVars: required variable 'domain' is not set (declare a default or pass --var domain=...)
```

A hosted zone costs about $0.50/month whether or not anything uses it —
`./stackctl demo 010_dns destroy` when you are done.

> The checks use a fixture value, `demo.invalid` (RFC 2606 — a name that can
> never resolve), so `nix flake check` runs on a fresh clone with no domain. That
> fixture is checks-only and never reaches an apply.

## Configuration variables

Account-specific values are **declared** in `environments/<env>.nix` with a
deliberately fake default, and supplied at run time — you never edit a tracked
file to set one:

```sh
# a) an untracked vars file; ./stackctl passes it with --var-file when present
echo '{ "stateBucket": "my-nivis-demos-state" }' > environments/demo.vars.json

# b) the environment
NIVIS_VAR_stateBucket=my-nivis-demos-state ./stackctl demo 000_backend plan

# c) a one-off, highest precedence
./stackctl demo 000_backend plan --var stateBucket=my-nivis-demos-state
```

Precedence is nivis's own, lowest to highest: `NIVIS_VAR_*` < `--var-file` <
`--var`. `environments/*.vars.json` is gitignored, so real values cannot be
committed by accident.

`nix flake check` deliberately runs on the fake defaults — the checks never
depend on a file you have not committed. A variable declared without a default is
required, and evaluation fails naming it rather than proceeding with a
placeholder.

## Secrets

Secrets are age-encrypted at rest under `secrets/`, with `secrets/secrets.nix`
declaring which keys may decrypt which file. **Nothing here is real**: the
committed `.age` files hold deliberately fake values, exactly like the
environment's fake defaults. They are committed so the wiring can be read.

They are encrypted to the maintainer's key only, so **you cannot decrypt them** —
that is expected. To take ownership:

```sh
# 1. put your own public key in secrets/secrets.nix (replace `maintainer`)
# 2. delete the files you cannot read
rm secrets/*.age
# 3. create them again, with any fake value you like
agenix -e vaultwarden-admin-token.age
```

Step 2 is not optional. `agenix -r` (re-key) and `agenix -e` on an existing file
both **decrypt before they re-encrypt**, so they need an identity that can
already read the file. Since every value is fake, recreating is the whole job.

How a secret reaches a service — the pattern worth copying:

- `secrets/secrets.nix` lists recipients. A real host is added by its **ssh host
  public key**, so it can decrypt at activation.
- The host declares `age.secrets.<name>.file`, and agenix decrypts it at
  activation to `config.age.secrets.<name>.path`, owned by root.
- The service consumes that **path** (`EnvironmentFile`), never the value. So the
  secret never enters the Nix store, a unit file, or a process argument list.

`nixos/demo-host` exists only to make that wiring real: it is evaluated by
`nix flake check` and never deployed, so a secret missing from `secrets.nix`, or
a service that interpolates a value instead of a path, fails the gate.

**Secrets stop at the host boundary.** No catstack domain reads one, so no IR,
provider config, or state file ever carries secret material.

## Working on a domain

```sh
./stackctl demo 000_backend plan
./stackctl demo 000_backend apply
./stackctl demo 000_backend output      # e.g. state_bucket
```

Extra arguments are forwarded to nivis unchanged, so `--backend=local`,
`--force`, and friends work as documented upstream.

## The gate

```sh
nix flake check      # build + tests + coverage + fmt + shellcheck
nix fmt              # format
```

Coverage here means *domains exercised by a test*, not lines: every
`stack/<domain>/domain.nix` must be named by some file under `tests/`. The bar is
70% overall and 80% for the core domains listed in `flake.nix` (`coverage.coreDomains`).
See `tests/README.md`.

## Adding a domain

1. `stack/NNN_<name>/domain.nix` — a `{ nivis, env } -> ledger -> IR` function.
2. Register it in `flake.nix` under `domainsFor`.
3. Give it a state key of `<name>/state.json`, and declare any account-specific
   value as a variable in `environments/<env>.nix` rather than a literal.
4. Write `tests/<name>.nix` asserting on its IR — that is what the coverage gate
   counts. `stackctl` needs no edit.
