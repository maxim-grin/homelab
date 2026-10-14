// Jobboard: pods, storage, the crawl CronJob, ingress and container use.
//
// Metrics used (each checked against a real scrape unless noted):
//   kube-state-metrics: kube_pod_status_ready, kube_pod_container_status_restarts_total,
//     kube_cronjob_spec_suspend, kube_cronjob_status_active,
//     kube_cronjob_next_schedule_time
//   kubelet: kubelet_volume_stats_used_bytes, kubelet_volume_stats_capacity_bytes
//   cAdvisor: container_cpu_usage_seconds_total, container_memory_working_set_bytes
//   ingress-nginx: nginx_ingress_controller_requests,
//     nginx_ingress_controller_request_duration_seconds_bucket
//   Documented names, not yet scraped (the CronJob has not run):
//     kube_cronjob_status_last_successful_time, kube_job_status_start_time,
//     kube_job_status_completion_time
//
// Ingress panels are prod-only (cluster="prod"); dev has no CronJob manifest,
// so the CronJob panels read "No data" for env=dev.
local g = import 'grafonnet-v11.4.0/main.libsonnet';
local h = import 'homelab.libsonnet';

local ns = 'namespace="jobboard"';
local sel = h.cluster + ', ' + ns;
local cron = sel + ', cronjob="jobboard-crawl"';
local ing = 'cluster="prod", host="$host"';

local hostVar =
  g.dashboard.variable.query.new('host', 'label_values(nginx_ingress_controller_requests{cluster="prod", host!=""}, host)')
  + g.dashboard.variable.query.withDatasource(h.ds.type, h.ds.uid)
  + g.dashboard.variable.query.withSort(1)
  + g.dashboard.variable.query.refresh.onLoad()
  + g.dashboard.variable.query.selectionOptions.withMulti(false)
  + g.dashboard.variable.query.selectionOptions.withIncludeAll(false);

local pvc = 'kubelet_volume_stats_used_bytes{' + sel + ', persistentvolumeclaim="data-postgres-0"} / kubelet_volume_stats_capacity_bytes{' + sel + ', persistentvolumeclaim="data-postgres-0"}';

h.dashboard('Jobboard', 'jobboard', ['app'])
+ g.dashboard.withDescription('Jobboard pods, database volume, the jobboard-crawl CronJob, ingress and container use. Ingress panels are prod-only. Dev has no CronJob manifest, so the CronJob panels (suspend, active, next run, last success, duration) show No data for env=dev.')
+ g.dashboard.withVariables([h.envVar(), hostVar])
+ h.withPanels([
  // Pods.
  h.stat('Pods not ready', 'sum(kube_pod_status_ready{' + sel + ', condition="false"}) or vector(0)', 'short', [[0, h.colors.green], [1, h.colors.red]]),
  h.stat('Container restarts, 1h', 'sum(increase(kube_pod_container_status_restarts_total{' + sel + '}[1h])) or vector(0)', 'short', [[0, h.colors.green], [1, h.colors.amber]]),
  h.timeseries('Pod restarts by pod', { '{{pod}}': 'increase(kube_pod_container_status_restarts_total{' + sel + '}[5m])' }),
  // Storage.
  h.stat('Database volume use', 'max(' + pvc + ')', 'percentunit', [[0, h.colors.green], [0.7, h.colors.amber], [0.8, h.colors.red]]),
  h.timeseries('Volume use by claim', { '{{persistentvolumeclaim}}': 'kubelet_volume_stats_used_bytes{' + sel + '} / kubelet_volume_stats_capacity_bytes{' + sel + '}' }, 'percentunit'),
  // CronJob jobboard-crawl.
  h.stat('Crawl suspended', 'kube_cronjob_spec_suspend{' + cron + '}', 'short', [[0, h.colors.green], [1, h.colors.amber]]),
  h.stat('Crawl jobs active', 'kube_cronjob_status_active{' + cron + '}'),
  h.stat('Crawl next run in', 'kube_cronjob_next_schedule_time{' + cron + '} - time()', 's'),
  h.stat('Crawl last success age (after first run)', 'time() - kube_cronjob_status_last_successful_time{' + cron + '}', 's'),
  h.timeseries('Crawl duration (after first run)', { '{{job_name}}': 'kube_job_status_completion_time{' + sel + ', job_name=~"jobboard-crawl-.*"} - kube_job_status_start_time{' + sel + ', job_name=~"jobboard-crawl-.*"}' }, 's'),
  // Ingress.
  h.timeseries('Requests per second (prod)', { '{{status}}': 'sum by (status) (rate(nginx_ingress_controller_requests{' + ing + '}[5m]))' }, 'reqps'),
  h.timeseries('5xx ratio (prod)', { '5xx': 'sum(rate(nginx_ingress_controller_requests{' + ing + ', status=~"5.."}[5m])) / clamp_min(sum(rate(nginx_ingress_controller_requests{' + ing + '}[5m])), 1e-9)' }, 'percentunit'),
  h.timeseries('p95 latency (prod)', { p95: 'histogram_quantile(0.95, sum by (le) (rate(nginx_ingress_controller_request_duration_seconds_bucket{' + ing + '}[5m])))' }, 's'),
  // Containers.
  h.timeseries('Container CPU', { '{{container}}': 'sum by (container) (rate(container_cpu_usage_seconds_total{' + sel + ', container!=""}[5m]))' }, 'cores'),
  h.timeseries('Container memory', { '{{container}}': 'sum by (container) (container_memory_working_set_bytes{' + sel + ', container!=""})' }, 'bytes'),
])
