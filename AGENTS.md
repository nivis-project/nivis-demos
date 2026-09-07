# AGENTS.md — nivis-demos

## Overview

`nivis-demos` is a **public** collection of self-contained demo stacks for
[nivis](https://github.com/nivis-project/nivis), the Nix-native deployment
orchestrator, laid out catstack-style like the private `infra` repo. Where
`infra` dogfoods nivis on real production infrastructure, this repo exists to
*show it off*: small, readable, disposable domains that read as examples.

The target is deliberately **mixed-cloud**:

- a personal **AWS playground** account for the EC2 demos,
- a personal **Hetzner** project for Hetzner compute, via our own
  [terraform-provider-hcloudimage](https://github.com/nivis-project/terraform-provider-hcloudimage),
- **agenix** for secrets, with sample environments holding deliberately *fake*
  values so the repo stays public and clonable,
- **S3** for remote nivis state, one state key per domain.

Planned demos: Vaultwarden on EC2, the same workload on Hetzner compute, and a
Minecraft server via the hashicraft minecraft provider.

Because everything here is public, **no real secret, account id, or hostname
ever lands in this repo.** Sample environments are fake by design; that is a
feature of the demo, not a placeholder to be filled in later.

## Commands

```bash
# Beans (issue tracker) — source of truth for what to work on next
beans prime                  # read the workflow before touching beans
beans list --json --ready    # what is ready to start
beans show --json <id>       # full bean
beans roadmap                # milestones -> epics -> tasks
beans check                  # validate config and bean integrity

# OpenSpec — planning lives in the shared `nivis` store, NOT in ./openspec
openspec context             # show which root/store resolves here
openspec list                # active changes
openspec doctor              # store registration health
/opsx:propose "<idea>"       # new proposal (Claude Code)

# Ship one implemented change, gated
bash scripts/ship-change.sh <change-name> "<commit subject>"

# The stack — one nivis verb against one domain
./stackctl <env> <domain> <verb> [extra nivis args...]
./stackctl demo 000_backend plan
./stackctl demo 000_backend apply
./stackctl demo 000_backend output          # e.g. state_bucket
# Extra args are forwarded to nivis unchanged (e.g. --backend=local).
# First-time bucket bootstrap is in README.md.

# Configuration variables — account-specific values, never edited into a
# tracked file. Precedence: NIVIS_VAR_* < --var-file < --var
echo '{ "stateBucket": "..." }' > environments/demo.vars.json   # gitignored
./stackctl demo 000_backend plan --var stateBucket=...

# Secrets (agenix) — fake values, encrypted to the maintainer only.
agenix -e vaultwarden-admin-token.age    # from secrets/
# To take ownership: put your key in secrets/secrets.nix, `rm secrets/*.age`,
# then recreate. `agenix -r` cannot help — it decrypts before re-encrypting.

# Nix
nix develop                  # dev shell: nivis, awscli2, hcloud, age
nix flake check              # the gate: build + tests + coverage
nix fmt                      # format
```

## OpenSpec lives in a store

This repo declares `store: nivis` in `openspec/config.yaml`, so there is **no
local `openspec/specs` or `openspec/changes`** — proposals and specs live in
`/home/pim/gh.nivis-project/ospecs` (`git@github.com:nivis-project/ospecs.git`),
shared with the other nivis repos. Two consequences:

- `openspec archive` writes into the **store's** git repo, not this one, so
  `scripts/ship-change.sh` commits and pushes the store separately.
- Never re-create `openspec/specs` or `openspec/changes` here. If
  `openspec doctor` starts warning that the store declaration is ignored, it is
  because one of those directories came back — delete it.

## Beans

When I refer to issues like nivis-demos-rn3b checkout the task
in @.beans/nivis-demos-rn3b-*.md

In this project we will use these tasks as epics for making openspec proposals.

WHEN you create a proposal at a link to this task in the proposal.md.
WHEN a bean is used to create an proposal change the status to "in-progress"
WHEN a proposal is archived add the link to the archived proposal in the frontmatter of this task like this:

```
openspec-link: openspec/changes/archive/....
```

You are allowed to update these statuses in the task frontmatter:

- in-progress
- todo
- draft
- completed
- scrapped

When making changes you are allowed to update the date/time in `updated_at` in the task frontmatter

Besides updating status and openspec-link, you are NOT ALLOWED to modify the contents of the task file.
