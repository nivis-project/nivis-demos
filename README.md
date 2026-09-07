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

`environments/demo.nix` ships a bucket name that **S3 cannot accept**:

```nix
bucket = "REPLACE_ME-nivis-demos-state";
```

`_` and uppercase are outside S3's bucket-naming grammar, so AWS rejects it
immediately rather than creating something under a name you did not choose. A
plausible-looking placeholder would be worse: it is squattable, and every clone's
first apply would fail with a confusing `BucketAlreadyExists` from a bucket
nobody here controls.

Replace it with your own globally-unique bucket name before step 1 below.

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
3. Give it a state key of `<name>/state.json`.
4. Write `tests/<name>.nix` asserting on its IR — that is what the coverage gate
   counts. `stackctl` needs no edit.
