// Homelab overview: one glance at whether the prod cluster is healthy.
// Expressions reuse the matchers in argocd/apps/alerts/prod/rules.yaml
// where they overlap, so a red tile here means the matching alert agrees.
local g = import 'grafonnet-v11.4.0/main.libsonnet';
local h = import 'homelab.libsonnet';

local jobs = 'nginx_ingress_controller_requests{host="jobs.mgryn.cc"}';

// The chart's own dashboards have fixed uids (their JSON in
// kube-prometheus-stack's templates/grafana/dashboards-1.14).
local links = [
  g.dashboard.link.link.new('Proxmox', '/d/proxmox'),
  g.dashboard.link.link.new('Kubernetes / Compute Resources / Cluster', '/d/efa86fd1d0c121a26444b636a3f509a8'),
  g.dashboard.link.link.new('Node Exporter / Nodes', '/d/7d57716318ee0dddbac5a7f451fb7753'),
];

h.dashboard('Homelab overview', 'homelab-overview', ['overview'])
+ g.dashboard.withLinks(links)
+ h.withPanels([
  h.stat(
    'Nodes up',
    'sum(up{job="node-exporter"} == 1)',
    'short',
    [[0, h.colors.red], [3, h.colors.green]],
  ),
  h.stat(
    'Pods not ready',
    'sum(kube_pod_status_ready{condition="false"})',
    'short',
    [[0, h.colors.green], [1, h.colors.amber], [5, h.colors.red]],
  ),
  h.stat(
    'Firing alerts',
    'count(ALERTS{alertstate="firing", alertname!="Watchdog"}) or vector(0)',
    'short',
    [[0, h.colors.green], [1, h.colors.red]],
  ),
  h.stat(
    'Certificates expiring within 14 days',
    'count((certmanager_certificate_expiration_timestamp_seconds > 0) - time() < 14 * 86400) or vector(0)',
    'short',
    [[0, h.colors.green], [1, h.colors.red]],
  ),
  h.stat(
    'Proxmox thin pool use',
    'max(pve_disk_usage_bytes{id=~"storage/.+/local-lvm"} / pve_disk_size_bytes{id=~"storage/.+/local-lvm"})',
    'percentunit',
    [[0, h.colors.green], [0.7, h.colors.amber], [0.8, h.colors.red]],
  ),
  h.stat(
    'jobs.mgryn.cc requests per second',
    'sum(rate(' + jobs + '[5m]))',
    'reqps',
  ),
  h.stat(
    'jobs.mgryn.cc 5xx ratio',
    'sum(rate(nginx_ingress_controller_requests{host="jobs.mgryn.cc", status=~"5.."}[5m])) / sum(rate(' + jobs + '[5m])) or vector(0)',
    'percentunit',
    [[0, h.colors.green], [0.01, h.colors.amber], [0.05, h.colors.red]],
  ),
  h.table(
    'Firing alerts',
    'ALERTS{alertstate="firing", alertname!="Watchdog"}',
  ),
])
