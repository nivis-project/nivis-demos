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
| `stack/020_vaultwarden_ec2/`| Vaultwarden on EC2, built from a NixOS image                |
| `stack/030_vaultwarden_hetzner/` | the same workload on Hetzner compute                  |
| `nixos/vaultwarden/`        | the workload module — cloud-agnostic, reused by both demos  |
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
chicken-and-egg problem nivis solves in three commands (requires **nivis >= 0.6.1**; see nivis's `docs/REMOTE-STATE.md`):

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

## Vaultwarden on EC2

The first real workload: a password manager built from a NixOS image, behind
TLS, with its vault on a volume that survives the machine.

**This one costs money.** An instance, an EBS volume, an Elastic IP and a hosted
zone all bill by the hour or month. `destroy` when you are done.

It also needs a domain you can delegate (see [DNS](#dns-the-hosted-zone)) and an
x86_64 build path for the image — on another architecture you need binfmt
emulation or a remote builder, as `infra` does for its aarch64 image.

### The order that works

```sh
# 1. the zone, and delegation at your registrar (once) — see the DNS section
./stackctl demo 010_dns apply
./stackctl demo 010_dns output          # -> name_servers

# 2. put the admin token where the instance can read it. The VALUE never goes
#    through nivis: no IR, no plan, no state file. Read the name it expects:
./stackctl demo 020_vaultwarden_ec2 output    # -> ssm_parameter_name
aws ssm put-parameter \
  --name /nivis-demos/demo/vaultwarden/admin-token \
  --type SecureString --value "$(openssl rand -base64 48)"

# 3. build the image, upload it, register the AMI, launch, and bind DNS — one apply
./stackctl demo 020_vaultwarden_ec2 apply

# 4. when you are done
./stackctl demo 020_vaultwarden_ec2 destroy
```

Step 3 creates the Elastic IP and the A record **in the same apply**: the address
EC2 allocates re-enters Nix to produce the record. Nobody copies an IP by hand.

### Waiting for the certificate

Caddy requests a certificate at boot. Until your registrar's name servers point
at the hosted zone, the name does not resolve and issuance fails — that is
expected, and **no further apply is needed**: Caddy retries on its own schedule
and the certificate arrives once delegation propagates. Propagation time is not
under anyone's control here.

Without the SSM parameter, Vaultwarden does not start at all, by design: a
missing admin token disables the feature rather than serving an unauthenticated
admin page.

### What survives a change

Changing the NixOS configuration builds a new image and **replaces the
instance**. The data volume, the Elastic IP and the A record are separate
resources and are not replaced, so the vault and the address survive. That is
the lesson worth taking from this demo: the machine is disposable, the data is
not.

## Vaultwarden on Hetzner

The same workload, on a second cloud. `nixos/vaultwarden` is imported
**unchanged**; only the domain differs. That is the demo: the workload is
portable, the infrastructure is not.

It is also mixed-cloud in a single apply — the server, its volume and its
address are Hetzner, while the DNS record is AWS Route 53, fed by the address
Hetzner allocates.

Needs `HCLOUD_TOKEN` for the project you want to deploy into. A Hetzner API
token is scoped to one project by construction, so unlike AWS there is no
account to pin: whichever token you export *is* the guard.

### The two-step secret enrolment

Unlike EC2, there is no SSM. The admin token is delivered by **agenix** — but a
server generates its ssh host key at first boot, so it cannot be a recipient
when the secret is encrypted. Enrolment therefore takes two passes, and
**Vaultwarden does not start until the second one completes**. That is
deliberate: a missing token disables the admin interface rather than serving it
unauthenticated.

```sh
# 1. first apply — builds the image, uploads it, snapshots it, boots the server
./stackctl demo 030_vaultwarden_hetzner apply

# 2. read the server's ssh host public key, straight off the wire
ssh-keyscan -t ed25519 "$(./stackctl demo 030_vaultwarden_hetzner output | \
  grep public_ip | cut -d= -f2 | tr -d ' \"')"

# 3. add that key as a recipient in secrets/secrets.nix, and re-encrypt
agenix -r

# 4. apply again — a new image carries the re-keyed secret, the server is
#    replaced, and Vaultwarden starts
./stackctl demo 030_vaultwarden_hetzner apply
```

Step 2 needs no login, and there is none to be had: root is locked, no keys are
installed and no other user exists. `ssh-keyscan` reads the *public* host key
out of the ssh protocol banner before authentication happens, which is why the
domain opens 22 alongside 80 and 443. Nothing can log in over it.

The volume and the primary IP survive the replacement in step 4, so the vault
and the address are unaffected.

### Costs

A server, a volume and a primary IP bill by the hour.
`./stackctl demo 030_vaultwarden_hetzner destroy` when you are done. The image
is x86 (`cx23`) so it builds natively on any x86_64 machine; no emulation and no
remote builder needed.

## A machine you can deploy to without being able to reach it

`040_tunnel_target` is the demo the other two set up. Where they show a workload
on two clouds, this one makes a narrower and more consequential claim: a machine
can be deployed to while admitting nothing.

Nothing in the domain opens a port. There is no elastic IP, no DNS record and no
security group rule. The agent baked into the boot image dials **out** to a
relay, the operator dials the same relay, and the two are spliced together.
`nivis-tunnel connect <stream id>` is the only way in.

### The split, which is the actual point

There are two NixOS configurations, not one.

| | what it holds | what changing it costs |
|-------------|-------------------------------------|----------------------------|
| boot image | boot, network, sshd, the agent | build, upload, snapshot import, new AMI, **machine replaced** |
| live system | everything else, here nginx | a closure push and `switch-to-configuration` |

The image carries only what a closure push cannot replace. On NixOS the kernel,
initrd and bootloader all live in the closure, so what genuinely forces an image
rebuild is the partition layout, the filesystem, the boot mode, and the agent.
Everything else belongs in the live system.

Measured on this demo, against one running machine:

```
image route   2649 MiB   ~15 min   machine replaced
live-1          17 MiB       51s   same machine
live-2         343 KiB        4s   same machine
```

The live system is built **on** the image's configuration rather than beside it.
That is load-bearing: `switch-to-configuration` activates a complete description
of the machine, so a unit the new generation does not declare gets stopped. A
live system assembled independently would eventually stop the agent, severing
the connection the activation itself arrived over, on a machine with no second
route in.

### Running it

```sh
# once: a relay the machine and you can both reach, and an orchestrator key
nivis-tunnel keygen > ~/.config/nivis-tunnel/orchestrator.key

# the public half, the relay address, your ssh key and the key file path go in
# the untracked vars file (see the configuration section above)
./stackctl demo 040_tunnel_target apply

# the negative first. this must find nothing
nmap -Pn -p- "$(./stackctl demo 040_tunnel_target output | grep public_ip | cut -d= -f2 | tr -d ' "')"

# and then, anyway
ssh -o ProxyCommand='nivis-tunnel connect poc-target-aws-01 --relay <relay> --key ~/.config/nivis-tunnel/orchestrator.key' \
    root@poc-target-aws-01 'cat /etc/tunnel-target-generation'
```

Change `tunnelGeneration` in the vars file and apply again: the plan touches the
activation and nothing else. The machine does not reboot and keeps its instance
id, its snapshot and its AMI.

### When the tunnel cannot help you

This machine has no inbound port, so a deploy that breaks the agent leaves no
network route back. There is no magic rollback yet, which makes the fallback
worth knowing **before** you need it:

```sh
aws ec2 enable-serial-console-access          # once per account
ssh-keygen -t ed25519 -f /tmp/serial -N ""
aws ec2-instance-connect send-serial-console-ssh-public-key \
  --instance-id <id> --serial-port 0 --ssh-public-key file:///tmp/serial.pub
ssh -i /tmp/serial <id>.port0@serial-console.ec2-instance-connect.<region>.aws
```

The key is valid for 60 seconds, so connect straight away, and press Enter after
connecting. Leave with `~.` rather than closing the terminal: one session is
allowed per instance and a client that vanishes leaves it held.

The serial console works without an open port, which is the only kind of
fallback this machine can have. Try it once while nothing is wrong. A fallback
first used during a failure is a guess.

If even that fails, the machine is replaceable: the image is unchanged, so
recreating the instance costs an instance creation and not an image rebuild.

### Costs

One `t3.micro`, one 12 GiB volume, and an S3 bucket holding a 2.6 GB image.
`./stackctl demo 040_tunnel_target destroy` when you are done.

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
