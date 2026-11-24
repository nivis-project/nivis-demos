---
# nivis-demos-mukd
title: 'Ship script: the store step fails on a jj store'
status: completed
type: bug
priority: normal
tags:
    - discovered
created_at: 2026-11-24T22:06:54Z
updated_at: 2026-11-24T22:07:56Z
---

scripts/ship-change.sh commits the OpenSpec store with git and refuses when the store is not on a branch. The store (nivis-openspec-stores) is jj-colocated, so git always shows a detached HEAD and the step fails every time; the readme-header and readme-footer-tagline ships were finished by hand. Use the store's own scripts/store-commit.sh and scripts/store-hygiene.sh, as nivis's ship script does (see the store README, 'The hygiene contract for a client project').
