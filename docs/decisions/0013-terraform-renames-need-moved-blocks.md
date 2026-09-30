# 0013. Every Terraform rename carries a `moved` block

**Status:** Accepted (2026-09-27)

## Context

[#47](https://github.com/maxim-grin/homelab/pull/47) renamed
`module "ubunut-k8s-1"` to `"dev-cluster"` with no `moved` block. Terraform
tracks resources by address, so the new name read as "delete the old,
create the new," and the apply destroyed and recreated all three dev VMs
from the blank template — cluster and all. CI runs `terraform validate`,
never `plan`, so nothing caught the missing block before the apply.

## Decision

Every rename of a Terraform module or resource must carry a `moved` block
in the same commit:

```hcl
moved {
  from = module.ubunut-k8s-1
  to   = module.dev-cluster
}
```

Read the plan summary before every apply; an unintended `destroy` is a
stop, not a warning to note and proceed past.

## Consequences

This is a documentation-only fix — a load-bearing bullet in CLAUDE.md, not
a CI gate, because CI still only validates. It relies on whoever runs
`terraform apply` actually reading the plan output. The incident itself
cost a full dev rebuild and a database restore from nfs-01, and surfaced
real bugs on the way back (an `ansible-playbook` guard that was always
true because `.get()` returns `None` and `None` is defined, and a
playbook ordering issue), fixed alongside the rebuild.

## Related

[#47](https://github.com/maxim-grin/homelab/pull/47) "ops: rename dev
cluster"; [#49](https://github.com/maxim-grin/homelab/pull/49) "docs:
require moved blocks on rename"; [#50](https://github.com/maxim-grin/homelab/pull/50)
"fix: dev rebuild path"; CLAUDE.md "Renaming a module or resource destroys
what it manages".
