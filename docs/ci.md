# CI and branch protection

The four CI jobs are summarised in the [README](../README.md#ci). This
page is the one-time repository setup that makes them block a merge.

## Branch protection

CI only blocks a merge once the four checks are required. That is a
repository setting, not a file in git. Suggested rules
for `main`: pull request required with 0 approvals (you cannot approve your
own PR), the four checks required, "up to date" not required, force-push and
deletion blocked, no bypass. Enable it _after_ `main` is green, or it blocks
the PR that fixes it. A check name only appears in the picker once it has run
once. From the UI: Settings → Rules → Rulesets → New branch ruleset. Or, as a
repo admin:

```bash
gh api -X POST repos/maxim-grin/homelab/rulesets --input - <<'EOF'
{
  "name": "protect main",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": [],
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "pull_request", "parameters": {
        "required_approving_review_count": 0,
        "dismiss_stale_reviews_on_push": false,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": false } },
    { "type": "required_status_checks", "parameters": {
        "strict_required_status_checks_policy": false,
        "required_status_checks": [
          { "context": "pre-commit" }, { "context": "commits" },
          { "context": "terraform" }, { "context": "manifests" } ] } }
  ]
}
EOF
```

If `gh` returns 403, run `gh auth status`: a `GH_TOKEN` in the environment
overrides the logged-in account. To check it works, open a throwaway PR with
a trailing space in a file: `pre-commit` should go red and merge should be
blocked.
