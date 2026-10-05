# Playbooks

- `site.yaml`: everything.

```bash
ansible-playbook -i inventories/dev -i inventories/nope \
  playbooks/site.yaml \
  -e @secret.yaml
```

Prose mention of playbooks/gone.yaml is fine. See [target](../target.md#top),
[dir](../other/), [ext](https://example.com/x) and [mail](mailto:a@b.c).
