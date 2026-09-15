---
# nivis-demos-ufps
title: ship-change.sh reinvents the store contract instead of using it
status: todo
type: bug
created_at: 2026-09-15T15:43:38Z
updated_at: 2026-09-15T15:43:38Z
---

Shipping a change into the `nivis` store stops halfway, every time:

```
==> [4/6] commit + push the OpenSpec store (/home/pim/gh.nivis-project/ospecs)
ship: the store at /home/pim/gh.nivis-project/ospecs is not on main
      (branch: "detached HEAD").
```

Two ships out of two. The archive has already happened at that point, so the
change is half shipped and the operator finishes it by hand.

## It is not OpenSpec, and not the store

The store's reflog names the cause:

```
5894bed  export from jj
312b092  commit: tunnel-target-activation: the gate holds the shape
3406ace  export from jj
```

`ospecs` is itself a jj-colocated repo, and jj detaches git HEAD on export. In
jj that is normal and harmless: `main` is a bookmark, and git HEAD is not where
the truth lives. The guard is right about the danger it names, a commit on a
detached HEAD reaching no branch, and wrong about how to detect it.

## The contract already exists

`ospecs/README.md`, "The hygiene contract for a client project":

> A project that archives changes into this store owes the store one guarantee:
> when a unit of work is finished, nothing about it exists only on that machine.
>
> 1. `openspec archive <change> --store nivis`
> 2. `scripts/store-commit.sh "Archive <change>"` — commits and pushes it
> 3. `scripts/store-hygiene.sh` — fails the ship if the store still has
>    uncommitted or unpushed work

The store ships all three: `store-commit.sh`, `store-hygiene.sh`,
`store-lib.sh`. `nivis/scripts/ship-change.sh` calls them (lines 128 and 142),
with a fallback when the checkout is too old to have them.

This repo's copy hand-rolls `git add`, `git commit`, `git push` and its own
branch check, and so rediscovers a problem the contract had already solved.

## What else that costs

The detached HEAD is the visible symptom. Two silent ones come with it:

- **No fetch and rebase.** `store-commit.sh` does both. A concurrent push from
  another nivis project would strand this one, and nothing would say so.
- **No post-condition.** `store-hygiene.sh` fails the ship when the store still
  holds unpushed work. Without it, a ship can report success while the archive
  exists only locally, which is precisely the guarantee the contract asks for.

## Drift

The two scripts have already forked: `nivis` is 153 lines and has gained a
`--bean` flag, this one is 119 and has not. Two copies of one script evolving
apart is the more expensive problem, and worth a thought beyond this fix: the
store already distributes scripts to its clients, so it is a plausible home for
the ship flow as well.

## Todo

- [ ] Replace step 4 with `store-commit.sh`, keeping a fallback for a checkout
      that lacks it
- [ ] Add `store-hygiene.sh` as a post-condition after the repo commit
- [ ] Drop the branch guard: it encodes an assumption about git that a
      jj-colocated store does not meet
- [ ] Decide whether ship-change.sh should be one script rather than two copies
