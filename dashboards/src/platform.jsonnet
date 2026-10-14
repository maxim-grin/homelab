// Platform: ingress, certificates, NFS and ArgoCD.
//
// Metrics used (each checked against a real scrape unless noted):
//   ingress-nginx: nginx_ingress_controller_requests,
//     nginx_ingress_controller_request_duration_seconds_bucket
//   cert-manager: certmanager_certificate_expiration_timestamp_seconds,
//     certmanager_certificate_ready_status
//   kubelet: kubelet_volume_stats_used_bytes, kubelet_volume_stats_capacity_bytes
//   kube-state-metrics: kube_deployment_status_replicas_available
//   argocd: argocd_app_info
//
// Ingress panels are prod-only (cluster="prod"). ArgoCD panels are hub-wide:
// every argocd_app_info series carries the hub's cluster label, not the
// app's target, so they ignore the env variable. Each is wrapped in
// max by (name) so a second controller replica does not double count.
local g = import 'grafonnet-v11.4.0/main.libsonnet';
local h = import 'homelab.libsonnet';

local ing = 'cluster="prod", host!=""';
local req = 'nginx_ingress_controller_requests{' + ing;
local lat = 'nginx_ingress_controller_request_duration_seconds_bucket{' + ing + '}';

local expiry = '((certmanager_certificate_expiration_timestamp_seconds{' + h.cluster + '} > 0) - time()) / 86400';
local notReady = 'certmanager_certificate_ready_status{' + h.cluster + ', condition=~"False|Unknown"} == 1';

local nfsSel = h.cluster + ', namespace="nfs-system"';
local pvcUse = 'kubelet_volume_stats_used_bytes{' + h.cluster + '} / kubelet_volume_stats_capacity_bytes{' + h.cluster + '}';

local apps(matcher='') = 'max by (name) (argocd_app_info{' + matcher + '})';
local appCount(matcher) = 'count(' + apps(matcher) + ') or vector(0)';
local cols = 'name, project, dest_namespace, dest_server, sync_status, health_status';
local badApps =
  'max by (' + cols + ') (argocd_app_info{sync_status!="Synced"}) or max by (' + cols + ') (argocd_app_info{health_status!="Healthy"})';

// Rows are laid out by hand: g.util.grid.wrapPanels gives a row panel
// zero width and a stray x. Each section is a row plus panels, three per
// line, eight wide, six high.
local section(title, y, panels) =
  [g.panel.row.new(title) + g.panel.row.gridPos.withX(0) + g.panel.row.gridPos.withY(y) + g.panel.row.gridPos.withW(24) + g.panel.row.gridPos.withH(1)]
  + [
    panels[i] { gridPos: { x: (i % 3) * 8, y: y + 1 + std.floor(i / 3) * 6, w: 8, h: 6 } }
    for i in std.range(0, std.length(panels) - 1)
  ];

local certTable =
  h.table('Certificate expiry', expiry)
  + g.panel.table.queryOptions.withTransformations([
    { id: 'filterFieldsByName', options: { include: { names: ['name', 'namespace', 'Value'] } } },
    { id: 'organize', options: { renameByName: { Value: 'Days left' } } },
    { id: 'sortBy', options: { sort: [{ field: 'Days left', desc: false }] } },
  ])
  + g.panel.table.standardOptions.withOverrides([
    {
      matcher: { id: 'byName', options: 'Days left' },
      properties: [
        { id: 'unit', value: 'd' },
        { id: 'decimals', value: 1 },
        { id: 'custom.cellOptions', value: { type: 'color-background' } },
        {
          id: 'thresholds',
          value: {
            mode: 'absolute',
            steps: [
              { value: null, color: h.colors.red },
              { value: 14, color: h.colors.amber },
              { value: 21, color: h.colors.green },
            ],
          },
        },
      ],
    },
  ]);

local appTable =
  h.table('Apps not Synced or not Healthy', badApps)
  + g.panel.table.queryOptions.withTransformations([
    { id: 'filterFieldsByName', options: { include: { names: ['name', 'project', 'dest_namespace', 'dest_server', 'sync_status', 'health_status'] } } },
  ]);

h.dashboard('Platform', 'platform', ['platform'])
+ g.dashboard.withDescription('Ingress, certificates, NFS and ArgoCD. The ingress and ArgoCD rows are fixed scopes (prod ingress; hub-wide ArgoCD) and ignore the env variable; the certificate and NFS rows follow it. The nfs-provisioner panel reads kube_deployment_status_replicas_available in namespace nfs-system; the deployment label is unverified, and a wrong namespace or deployment label reads 0 (red), not No data.')
+ g.dashboard.withVariables([h.envVar()])
+ g.dashboard.withPanels(
  section('Ingress (prod)', 0, [
    h.timeseries('Requests per second by host (prod)', { '{{host}}': 'sum by (host) (rate(' + req + '}[5m]))' }, 'reqps'),
    h.timeseries('5xx ratio by host (prod)', { '{{host}}': 'sum by (host) (rate(' + req + ', status=~"5.."}[5m])) / clamp_min(sum by (host) (rate(' + req + '}[5m])), 1e-9)' }, 'percentunit'),
    h.timeseries('p95 latency by host (prod)', { '{{host}}': 'histogram_quantile(0.95, sum by (host, le) (rate(' + lat + '[5m])))' }, 's'),
  ])
  + section('Certificates', 7, [
    certTable,
    h.stat('Certificates not ready', 'count(' + notReady + ') or vector(0)', 'short', [[0, h.colors.green], [1, h.colors.red]]),
  ])
  + section('NFS', 14, [
    h.stat('NFS provisioner available replicas', 'sum(kube_deployment_status_replicas_available{' + nfsSel + '}) or vector(0)', 'short', [[0, h.colors.red], [1, h.colors.green]]),
    h.timeseries('PVC use by claim', { '{{namespace}}/{{persistentvolumeclaim}}': pvcUse }, 'percentunit'),
  ])
  + section('ArgoCD (hub-wide, all apps, ignores env)', 21, [
    h.stat('Apps total', appCount('')),
    h.stat('Apps not Synced', appCount('sync_status!="Synced"'), 'short', [[0, h.colors.green], [1, h.colors.amber]]),
    h.stat('Apps not Healthy', appCount('health_status!="Healthy"'), 'short', [[0, h.colors.green], [1, h.colors.red]]),
    h.stat('Apps without autosync', appCount('autosync_enabled!="true"'), 'short', [[0, h.colors.green], [1, h.colors.amber]]),
    appTable,
  ])
)
