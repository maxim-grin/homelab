# 0025. Runbooks own the operator commands; rebuild.md owns the order

**Status:** Accepted (2026-10-05)

## Context

The commands an operator runs lived in several places: `docs/rebuild.md`,
`ansible/README.md`, `docs/operations.md` and the checklists of pull
requests. Each copy drifted: a playbook gained a flag, one file was
updated, and the others kept the old command. Finding "how do I run
`lan_services` for Gatus only" or "is Vault sealed" meant reading three
documents and trusting none.

## Decision

`docs/runbooks/` owns "how do I run or check X now": one entry per task,
each with when to run it, one complete copy-paste block, what success
prints and where to look if it does not. An index
(`docs/runbooks/README.md`) maps questions to entries and states the
shared conventions once.

`docs/rebuild.md` owns "in what order, for a rebuild". It links to a
runbook entry for the command instead of restating it.

A pull request that adds or changes a playbook, a flag or an operator
step updates the runbook in the same pull request and links the entry
from its operator checklist. The rule is in CLAUDE.md.

**A drift guard.** `scripts/check-runbooks.sh` runs in pre-commit and in
the CI `scripts` job, as `check-talos-pins.sh` does. It fails when a
playbook in `ansible/playbooks/` is not named in
`playbooks-and-terraform.md`, when a command in the runbooks names a
playbook or an inventory that does not exist, or when a relative link
does not resolve. Its test proves each check can fail.

Rejected:

- **A `justfile` or other wrapper over the playbooks**: another layer to
  keep in step with `ansible-playbook`, for no gain while one operator
  runs a few dozen commands. Revisit if the runbooks outgrow reading.
- **Leaving the commands in `rebuild.md`**: it is ordered for a rebuild,
  not for lookup, and day-to-day tasks do not belong in its steps.

## Consequences

- `docs/rebuild.md` and `ansible/README.md` still carry duplicate
  commands. Replacing them with links is a follow-up pull request.
- The guard checks names and links, not command flags or output: a
  reviewer still cross-checks a block against the playbook's header.
- A new playbook fails pre-commit and CI until the runbook names it.

## Related

`docs/superpowers/specs/2026-10-04-runbooks-design.md`; records
[0013](0013-terraform-renames-need-moved-blocks.md).
