// Proxmox: the one host under everything, and the guests on it.
//
// Metrics used (pve-exporter; each checked against a real scrape):
//   pve_up, pve_uptime_seconds, pve_cpu_usage_ratio,
//   pve_memory_usage_bytes, pve_memory_size_bytes,
//   pve_disk_usage_bytes, pve_disk_size_bytes,
//   pve_network_receive_bytes_total, pve_network_transmit_bytes_total,
//   pve_disk_read_bytes_total, pve_disk_written_bytes_total,
//   pve_guest_info, pve_storage_info
// Not used: the deprecated gauges (pve_network_*_bytes, pve_disk_read_bytes,
// pve_disk_write_bytes); the exporter has no swap metric, so there is no
// swap panel.
//
// Series carry only `id`: node/pve, qemu/<vmid>, lxc/<vmid>,
// storage/pve/<name>. Names and types come from pve_guest_info and
// pve_storage_info, joined with `* on(id) group_left(...)`. Templates
// (template="1") are left out of every guest panel.
local g = import 'grafonnet-v11.4.0/main.libsonnet';
local h = import 'homelab.libsonnet';

local node = 'id="node/pve"';

// Joins a per-id series onto guest names, filtered by the $guest variable.
// Multiplying by an info series (value 1) also drops series with no match.
local guests = 'pve_guest_info{template="0", name=~"$guest"}';
local perGuest(metric) =
  metric + '{id=~"qemu/.+|lxc/.+"} * on(id) group_left(name) ' + guests;

// Counts running (1) or stopped (0) guests of a type; templates excluded.
local count(type, state) =
  'count((pve_up == ' + state + ') * on(id) group_left() pve_guest_info{template="0", type="' + type + '"}) or vector(0)';

local guestVar =
  g.dashboard.variable.query.new('guest', 'label_values(pve_guest_info{template="0"}, name)')
  + g.dashboard.variable.query.withDatasource(h.ds.type, h.ds.uid)
  + { current: { text: 'All', value: '$__all' } }
  + g.dashboard.variable.query.selectionOptions.withMulti()
  + g.dashboard.variable.query.selectionOptions.withIncludeAll()
  + g.dashboard.variable.query.refresh.onTime()
  + g.dashboard.variable.query.withSort(1);

local links = [
  g.dashboard.link.link.new('Homelab overview', '/d/homelab-overview'),
];

local thin = 'pve_disk_usage_bytes{id=~"storage/.+/local-lvm"} / pve_disk_size_bytes{id=~"storage/.+/local-lvm"}';

local storageUse = 'pve_disk_usage_bytes{id=~"storage/.+"} / pve_disk_size_bytes{id=~"storage/.+"} * on(id) group_left(storage) pve_storage_info';

local steps = [[0, h.colors.green], [0.7, h.colors.amber], [0.8, h.colors.red]];

// Storage table: instant query, one row per storage, Value coloured by the
// overview's thresholds.
local storageTable =
  h.table('Storage use', storageUse)
  + g.panel.table.queryOptions.withTransformations([
    { id: 'filterFieldsByName', options: { include: { names: ['storage', 'Value'] } } },
    { id: 'organize', options: { renameByName: { Value: 'Use' } } },
  ])
  + g.panel.table.standardOptions.withOverrides([
    {
      matcher: { id: 'byName', options: 'Use' },
      properties: [
        { id: 'unit', value: 'percentunit' },
        { id: 'custom.cellOptions', value: { type: 'color-background' } },
        {
          id: 'thresholds',
          value: {
            mode: 'absolute',
            steps: [
              { value: null, color: h.colors.green },
              { value: 0.7, color: h.colors.amber },
              { value: 0.8, color: h.colors.red },
            ],
          },
        },
      ],
    },
  ]);

// Guest status table: up/down per guest, coloured.
local guestTable =
  h.table('Guest status', perGuest('pve_up') + ' * on(id) group_left(type) ' + guests)
  + g.panel.table.queryOptions.withTransformations([
    { id: 'filterFieldsByName', options: { include: { names: ['name', 'type', 'Value'] } } },
    { id: 'organize', options: { renameByName: { Value: 'Up' } } },
  ])
  + g.panel.table.standardOptions.withOverrides([
    {
      matcher: { id: 'byName', options: 'Up' },
      properties: [
        { id: 'custom.cellOptions', value: { type: 'color-background' } },
        {
          id: 'mappings',
          value: [{ type: 'value', options: { '0': { text: 'down' }, '1': { text: 'up' } } }],
        },
        {
          id: 'thresholds',
          value: {
            mode: 'absolute',
            steps: [{ value: null, color: h.colors.red }, { value: 1, color: h.colors.green }],
          },
        },
      ],
    },
  ]);

h.dashboard('Proxmox', 'proxmox', ['proxmox'])
+ g.dashboard.withLinks(links)
+ g.dashboard.withVariables([guestVar])
+ h.withPanels([
  // Health.
  h.stat('Exporter scraping', 'clamp_max(count(pve_up), 1) or vector(0)', 'short', [[0, h.colors.red], [1, h.colors.green]]),
  h.stat('Host up', 'pve_up{' + node + '}', 'short', [[0, h.colors.red], [1, h.colors.green]]),
  h.stat('Host uptime', 'pve_uptime_seconds{' + node + '}', 's'),
  h.stat('VMs running', count('qemu', 1), 'short', [[0, h.colors.red], [1, h.colors.green]]),
  h.stat('VMs stopped', count('qemu', 0), 'short', [[0, h.colors.green], [1, h.colors.amber]]),
  h.stat('LXCs running', count('lxc', 1), 'short', [[0, h.colors.red], [1, h.colors.green]]),
  h.stat('LXCs stopped', count('lxc', 0), 'short', [[0, h.colors.green], [1, h.colors.amber]]),
  // Host.
  h.timeseries('Host CPU', { cpu: 'pve_cpu_usage_ratio{' + node + '}' }, 'percentunit'),
  h.timeseries('Host memory', {
    used: 'pve_memory_usage_bytes{' + node + '}',
    size: 'pve_memory_size_bytes{' + node + '}',
  }, 'bytes'),
  // Storage.
  h.stat('Thin pool use (local-lvm)', 'max(' + thin + ')', 'percentunit', steps),
  storageTable,
  // Guests.
  h.timeseries('Guest CPU', { '{{name}}': perGuest('pve_cpu_usage_ratio') }, 'percentunit'),
  h.timeseries('Guest memory', { '{{name}}': perGuest('pve_memory_usage_bytes') }, 'bytes'),
  h.timeseries('Guest disk read', { '{{name}}': 'rate(pve_disk_read_bytes_total{id=~"qemu/.+|lxc/.+"}[5m]) * on(id) group_left(name) ' + guests }, 'Bps'),
  h.timeseries('Guest disk write', { '{{name}}': 'rate(pve_disk_written_bytes_total{id=~"qemu/.+|lxc/.+"}[5m]) * on(id) group_left(name) ' + guests }, 'Bps'),
  h.timeseries('Guest network in', { '{{name}}': 'rate(pve_network_receive_bytes_total{id=~"qemu/.+|lxc/.+"}[5m]) * on(id) group_left(name) ' + guests }, 'Bps'),
  h.timeseries('Guest network out', { '{{name}}': 'rate(pve_network_transmit_bytes_total{id=~"qemu/.+|lxc/.+"}[5m]) * on(id) group_left(name) ' + guests }, 'Bps'),
  guestTable,
])
