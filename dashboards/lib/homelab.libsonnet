// Shared helpers for the homelab Grafana dashboards. Every dashboard
// imports this file, so panel sizes, units and colours stay consistent.
// Names and meanings: lib/README.md.
local g = import 'grafonnet-v11.4.0/main.libsonnet';

local ds = { type: 'prometheus', uid: 'prometheus' };

// One threshold palette. Panels pick from it by name.
local colors = {
  green: 'green',
  amber: 'orange',
  red: 'red',
};

local panelHeight = 6;
local panelWidth = 8;

local query(expr, legend='') =
  g.query.prometheus.new(ds.uid, expr)
  + (if legend != '' then g.query.prometheus.withLegendFormat(legend) else {});

// steps: list of [value, color]; the first value is the base (null).
local thresholds(steps) =
  g.panel.stat.standardOptions.thresholds.withMode('absolute')
  + g.panel.stat.standardOptions.thresholds.withSteps([
    { value: if i == 0 then null else steps[i][0], color: steps[i][1] }
    for i in std.range(0, std.length(steps) - 1)
  ]);

{
  ds:: ds,
  colors:: colors,

  // Matcher for the env variable: interpolate into selectors.
  cluster:: 'cluster="$env"',

  // Environment picker: one value of the cluster label, default prod.
  envVar()::
    g.dashboard.variable.query.new('env', 'label_values(up, cluster)')
    + g.dashboard.variable.query.withDatasource(ds.type, ds.uid)
    + g.dashboard.variable.query.withSort(1)
    + g.dashboard.variable.query.refresh.onLoad()
    + g.dashboard.variable.query.selectionOptions.withMulti(false)
    + g.dashboard.variable.query.selectionOptions.withIncludeAll(false)
    + { current: { text: 'prod', value: 'prod' } },

  // uid is never random: pass the dashboard's file name without the
  // extension (src/foo.jsonnet -> 'foo').
  dashboard(title, uid, tags=[])::
    g.dashboard.new(title)
    + g.dashboard.withUid(uid)
    + g.dashboard.withTags(['homelab'] + tags)
    + g.dashboard.withEditable(false)
    + g.dashboard.withLinksMixin([
      g.dashboard.link.dashboards.new('Homelab dashboards', ['homelab'])
      + g.dashboard.link.dashboards.options.withAsDropdown(true)
      + g.dashboard.link.dashboards.options.withIncludeVars(true),
    ])
    + g.dashboard.withRefresh('1m')
    + g.dashboard.time.withFrom('now-6h')
    + g.dashboard.time.withTo('now'),

  // Lay panels out in a grid, three per row, left to right.
  withPanels(panels)::
    g.dashboard.withPanels(
      g.util.grid.wrapPanels(panels, panelWidth, panelHeight)
    ),

  // Single number. Optional steps, e.g. [[0, 'green'], [80, 'orange'], [90, 'red']].
  stat(title, expr, unit='short', steps=[[0, colors.green]])::
    g.panel.stat.new(title)
    + g.panel.stat.queryOptions.withDatasource(ds.type, ds.uid)
    + g.panel.stat.queryOptions.withTargets([query(expr)])
    + g.panel.stat.standardOptions.withUnit(unit)
    + thresholds(steps),

  // exprs: object of legend -> expression.
  timeseries(title, exprs, unit='short')::
    g.panel.timeSeries.new(title)
    + g.panel.timeSeries.queryOptions.withDatasource(ds.type, ds.uid)
    + g.panel.timeSeries.queryOptions.withTargets([
      query(exprs[legend], legend)
      for legend in std.objectFields(exprs)
    ])
    + g.panel.timeSeries.standardOptions.withUnit(unit)
    + g.panel.timeSeries.fieldConfig.defaults.custom.withFillOpacity(10),

  // Instant query rendered as a table.
  table(title, expr)::
    g.panel.table.new(title)
    + g.panel.table.queryOptions.withDatasource(ds.type, ds.uid)
    + g.panel.table.queryOptions.withTargets([
      query(expr) + g.query.prometheus.withInstant(true) + g.query.prometheus.withFormat('table'),
    ]),
}
