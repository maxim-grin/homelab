# Dashboard library

`homelab.libsonnet` is imported by every dashboard in `dashboards/src/`:

```jsonnet
local h = import 'homelab.libsonnet';
```

| Name                                      | What it is                                                                          |
| ----------------------------------------- | ----------------------------------------------------------------------------------- |
| `h.ds`                                    | The one datasource: `{type: 'prometheus', uid: 'prometheus'}`                       |
| `h.colors`                                | Threshold colours: `green`, `amber`, `red`                                          |
| `h.dashboard(title, uid, tags=[])`        | Dashboard shell; `uid` is the file name without extension, never random             |
| `h.withPanels(panels)`                    | Lays panels out in a grid, 8x6 each, three per row                                  |
| `h.stat(title, expr, unit, steps)`        | Single number; `steps` is `[[value, colour], ...]`, first entry is the base         |
| `h.timeseries(title, exprs, unit)`        | Line chart; `exprs` is an object of legend name to PromQL expression                |
| `h.table(title, expr)`                    | Instant query shown as a table                                                      |

Render with `scripts/check-dashboards.sh --write`.
