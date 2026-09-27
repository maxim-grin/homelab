# LAN Services — Design

Sub-project 1 of the [homelab roadmap](2026-09-26-homelab-roadmap-design.md).
Five small services for the whole LAN, each in its own unprivileged LXC in
`terraform/environments/shared`, installed natively by Ansible: Pi-hole
for DNS and ad blocking, Traefik as the edge proxy, Glance as the
dashboard, Gatus for uptime alerts, and LAN Orangutan for device discovery.

## Goal

Learn Traefik, and give the homelab a front door: every service reached by
a name with a valid certificate rather than an IP and port, one page that
shows Proxmox and every service, network-wide ad blocking, and an alert on
the phone when something is down.

Done means:

- `https://home.hl.mgryn.cc` shows Glance with every VM and LXC from
  Proxmox, Pi-hole's statistics, and Gatus's endpoint statuses
- every `*.hl.mgryn.cc` name serves a Let's Encrypt certificate for
  `*.hl.mgryn.cc`
- every device on the LAN resolves through Pi-hole, and ads are blocked
- stopping Pi-hole produces a Telegram alert, and starting it a recovery
- a sealed Vault produces a Telegram alert
- LAN Orangutan lists the devices on `10.0.0.0/24` with vendors

## Decisions

| Question | Decision |
| --- | --- |
| Names | `*.hl.mgryn.cc`, one DNS-only Cloudflare wildcard record → Traefik |
| Certificates | Let's Encrypt wildcard by DNS-01, obtained by Traefik |
| Pi-hole's role | The router's only DHCP-advertised DNS server; no public secondary |
| LXC resolvers | Router and `1.1.1.1`, never Pi-hole |
| Secrets | `ansible/secret.yaml`; Traefik gets its own Cloudflare token |
| Traefik routes | The four other services and the Proxmox UI; cluster apps wait for sub-project 3 |
| Vault UI | Stays direct at `vault.mgryn.cc:8200` |
| Uptime monitor | Gatus |
| Alerts | Telegram bot |
| Dashboard | Glance |
| Ansible structure | One role per service, one `lan_services.yaml` playbook |

### Why no Pi-hole for the LXCs themselves

Gatus sends alerts through Telegram, which needs DNS; Traefik renews its
certificate through Cloudflare, which needs DNS. If they resolved through
Pi-hole, a dead Pi-hole would silence the alert about itself.

## Network

The router leased every address from `.2` to `.253` until 2026-09-27,
when its pool was reduced to `.2`–`.99`. Every static address now sits
outside it.

| Range | Use |
| --- | --- |
| `.2`–`.99` | DHCP |
| `.101`, `.201`–`.202` | dev cluster |
| `.110`–`.119` | reserved for prod Talos (sub-project 2) |
| `.130`–`.133` | `claude-code`, `nfs-01`, retired, `vault-02` |
| `.140`–`.144` | the five LAN services |

The Proxmox host reaches the router through a Wi-Fi extender. Measured
from `claude-code` on 2026-09-27: 1–3 ms to the router with no loss, and
devices on the far side keep their own MAC addresses, so the extender
does not hide vendors from LAN Orangutan.

## Terraform

One `module "lan_service"` with `for_each` over `local.lan_services`, addressing containers as `module.lan_service["pihole"]`, etc. Renaming the module or a map key destroys that container; use a `moved` block (see CLAUDE.md's resource-rename rule).

| Key | vmid | Address | Memory | Root disk | Startup |
| --- | --- | --- | --- | --- | --- |
| `pihole` | 140 | `10.0.0.140/24` | 256M | 8G | `order=1` |
| `traefik` | 141 | `10.0.0.141/24` | 256M | 4G | `order=2` |
| `glance` | 142 | `10.0.0.142/24` | 128M | 4G | `order=15` |
| `gatus` | 143 | `10.0.0.143/24` | 128M | 4G | `order=15` |
| `orangutan` | 144 | `10.0.0.144/24` | 256M | 4G | `order=15` |

Pi-hole starts before `vault-02` (`order=5`) and `nfs-01` (`order=10`):
after a host power loss every other machine's name lookups go through it.

All five: Debian 13 standard template, unprivileged, `nesting = true`
(systemd in Debian 13 needs it inside an unprivileged container), pool
`LXC`, `start_at_node_boot = true`, the existing SSH public key for
`root`, `nameserver = "10.0.0.1 1.1.1.1"`, tags `lxc,shared,<service>`.

No root password: `modules/lxc`'s `password` input becomes optional, and
these containers leave it null. Access is the injected SSH key alone, and
no password lands in tfvars or state.

`modules/lxc` gains `nameserver` and `searchdomain` inputs and an optional `password`,
all defaulting to `null`. The name inputs keep today's behaviour of inheriting the
host's resolver, and the optional password keeps one out of tfvars and state.

Addresses come from a new `lxc_ips` map in `shared.tfvars`, keyed by
service, alongside `nfs_vm_ip` and `vault_vm_ip`. `shared.tfvars.example`
documents it.

### Host prerequisites

Not in Terraform, and listed in `docs/rebuild.md`:

1. `pveam update && pveam download local debian-13-standard_<version>_amd64.tar.zst`,
   and the exact file name in `shared.tfvars`.
2. The `LXC` pool exists, and `terraform@pve` holds `TerraformProv` on
   `/pool/LXC`. The role carries no `Pool.*` privileges, so placement
   fails without the per-pool ACL.
3. A read-only API token for Glance: user `glance@pve`, role `PVEAuditor`
   on `/`, token without privilege separation.

## Ansible

`inventories/shared/hosts.yaml` gains a `lan_services` group with one
child group per service. Hosts connect as `root` with
`host_ips['<service>']` from `secret.yaml`, the same source every other
host uses.

`playbooks/lan_services.yaml` runs one play per service in dependency
order: Pi-hole, Traefik, Gatus, LAN Orangutan, Glance.

Every role:

- pins its version in `defaults/main.yaml` and verifies the release's
  SHA-256 before installing (Pi-hole excepted, below)
- runs its service as a dedicated system user under a systemd unit with
  `Restart=on-failure`
- keeps secrets in a `0600` `EnvironmentFile` or config file, never in a
  world-readable one

Gatus and Glance also install the homelab CA's public certificate,
`~/.homelab-ca/ca.crt` on the workstation, into the container's trust
store, as the `vault` role does on `vault-02`: both reach
`https://vault.mgryn.cc:8200`, which that private CA signs.

### pihole — `pihole.hl.mgryn.cc`

Pi-hole v6, installed by the official installer in unattended mode, then
configured idempotently with `pihole-FTL --config`: upstreams `1.1.1.1`
and `9.9.9.9`, listening for the whole LAN, conditional forwarding to
the router for client names, and the blocklists in
`pihole_adlists` (StevenBlack's unified list to start). The admin
password is `pihole_admin_password`; Glance uses a separate app password,
`pihole_app_password`.

The installer always installs the current release; the version cannot be
pinned. `pihole -up` upgrades by hand.

### traefik — edge proxy, `traefik.hl.mgryn.cc`

Traefik v3. Static configuration:

- entrypoint `web` on `:80`, redirecting to `websecure`
- entrypoint `websecure` on `:443`, TLS from resolver `letsencrypt` for
  `hl.mgryn.cc` with SAN `*.hl.mgryn.cc`
- resolvers `letsencrypt` and `letsencrypt-staging`, both ACME DNS-01
  through Cloudflare with `CF_DNS_API_TOKEN` from an `EnvironmentFile`
- the file provider, reading `/etc/traefik/dynamic/`
- Prometheus metrics on `:8082`, for sub-project 3
- the dashboard, behind basic auth (`traefik_dashboard_users`)

It binds `:443` as its own user through
`AmbientCapabilities=CAP_NET_BIND_SERVICE`.

Routes, templated from `traefik_routes` in role defaults:

| Name | Backend |
| --- | --- |
| `home.hl.mgryn.cc` | `http://10.0.0.142:8080` |
| `pihole.hl.mgryn.cc` | `http://10.0.0.140:80` |
| `status.hl.mgryn.cc` | `http://10.0.0.143:8080` |
| `lan.hl.mgryn.cc` | `http://10.0.0.144:291` |
| `proxmox.hl.mgryn.cc` | `https://{{ host_ips['pve'] }}:8006`, through a `serversTransport` that skips verification of Proxmox's self-signed certificate |
| `traefik.hl.mgryn.cc` | `api@internal` |

The Cloudflare token has the same two permissions as cert-manager's —
Zone → DNS → Edit and Zone → Zone → Read on `mgryn.cc` — and is a
different token, `traefik_cloudflare_api_token`, so each can be revoked
alone.

Debug a failed issuance against `letsencrypt-staging`: production allows
five failed validations per hostname per hour.

### gatus — `status.hl.mgryn.cc`

Endpoints, from `gatus_endpoints` in role defaults:

| Group | Endpoint | Condition |
| --- | --- | --- |
| infra | Proxmox UI, certificate verification off (self-signed) | `[STATUS] == 200` |
| infra | NFS, TCP `10.0.0.131:2049` | `[CONNECTED] == true` |
| infra | Vault `/v1/sys/health` | `[STATUS] == 200` — sealed answers 503 |
| dns | a query to `10.0.0.140` for `example.com` | `[DNS_RCODE] == NOERROR` |
| lan | each `*.hl.mgryn.cc` name | `[STATUS] < 400` and `[CERTIFICATE_EXPIRATION] > 336h` |
| dev | `https://jobs.mgryn.cc` | `[STATUS] < 400` |
| network | router `10.0.0.1`, ICMP | `[CONNECTED] == true` |

Traefik renews at 30 days remaining, so the 14-day certificate check is
two weeks of warning that renewal has stopped.

Alerts go to Telegram (`gatus_telegram_token`, `gatus_telegram_chat_id`)
on failure and on recovery. History is stored in SQLite under
`/var/lib/gatus`. `metrics: true` exposes `/metrics`.

### orangutan — `lan.hl.mgryn.cc`

LAN Orangutan and `nmap`, scanning `10.0.0.0/24` on an interval, web UI
on `:291`, data under `/var/lib/orangutan`. Its unit grants
`CAP_NET_RAW` and `CAP_NET_ADMIN` for nmap's ARP scan.

**Unverified:** that an unprivileged LXC can hold raw sockets for an ARP
scan. `ping` works in one, which needs the same capability, so it should.
The plan checks it before writing the role. If it fails, this one
container becomes privileged.

### glance — `home.hl.mgryn.cc`

One page:

- **Monitor** widget: every `*.hl` name, `jobs.mgryn.cc` and the Vault UI
- **DNS stats** widget: Pi-hole v6 through its app password
- **Proxmox** `custom-api` widget: every VM and container from
  `/api2/json/cluster/resources`, with status and memory, through the
  `glance@pve` token (`glance_proxmox_token_id`,
  `glance_proxmox_token_secret`)
- **Gatus** `custom-api` widget: `/api/v1/endpoints/statuses`
- **Bookmarks**: Vault UI, ArgoCD, Grafana, jobboard, the GitHub
  repository

**Unverified:** that Glance's DNS widget speaks the Pi-hole v6 API, and
that `custom-api` handles the Proxmox token header. The plan checks both
first; Homepage is the fallback.

## Secrets

New top-level variables in `ansible/secret.yaml`, each with a placeholder
in `secret.yaml.example`:

| Variable | Used by |
| --- | --- |
| `pihole_admin_password` | Pi-hole admin login |
| `pihole_app_password` | Glance's DNS widget |
| `traefik_cloudflare_api_token` | Traefik's DNS-01 challenge |
| `traefik_dashboard_users` | Traefik dashboard basic auth, htpasswd format |
| `gatus_telegram_token`, `gatus_telegram_chat_id` | Gatus alerts |
| `glance_proxmox_token_id`, `glance_proxmox_token_secret` | Glance's Proxmox widget |

Plus `host_ips` entries for the five hosts and for `pve`, the Proxmox
host, which Traefik and Gatus reach on `:8006`.

## Rollout

Each step is verified before the next.

1. **LXCs.** `terraform apply -var-file=shared.tfvars` in
   `environments/shared` adds five containers and changes nothing else.
   `ssh root@10.0.0.140` through `.144` works.
2. **Pi-hole, not yet in use.** From the workstation,
   `dig @10.0.0.140 example.com` answers and
   `dig @10.0.0.140 doubleclick.net` returns `0.0.0.0`.
3. **Traefik.** Create the DNS-only Cloudflare record
   `*.hl.mgryn.cc` → `10.0.0.141`. Issue from `letsencrypt-staging`
   first, then switch to `letsencrypt`. `curl -v https://pihole.hl.mgryn.cc`
   from the workstation shows a certificate for `*.hl.mgryn.cc` issued by
   Let's Encrypt.
4. **Gatus.** Every endpoint green. `pct stop 140` on the host sends a
   Telegram alert within two check intervals; `pct start 140` sends the
   recovery.
5. **LAN Orangutan.** Lists roughly the twenty devices a ping sweep finds.
6. **Glance.** The Proxmox panel lists every VM and container.
7. **Cutover.** Record the router's current DNS setting, then set its
   DHCP DNS server to `10.0.0.140`. A client that renews its lease shows
   up in Pi-hole's query log by name. Rollback is the recorded setting.

## Failure modes

| Failure | Effect | Detection and response |
| --- | --- | --- |
| Pi-hole down | The LAN has no DNS | Gatus alerts, resolving through the router. Restart it, or restore the router's recorded DNS |
| Host reboot | Services return in startup order | Pi-hole starts first and answers within seconds |
| Traefik down | No `*.hl` names; services still answer on IP and port | Gatus alerts |
| Certificate renewal stops | TLS errors once the certificate expires | Gatus alerts at 14 days remaining |
| Vault sealed | AVP renders nothing, Applications go `Unknown` | Gatus alerts — the first thing that does |
| Wi-Fi extender drops | The homelab is off the LAN | Nothing to do; Telegram cannot fire either |

## Memory and disk

About 1G of memory for all five, against the roadmap's 1.5G budget; the
roadmap is updated to match. 24G of root disk allocated, about 3–4G
written.

## Pull requests

One logical change each, each body carrying its playbook command and its
checks. Each also documents what it brings up: its rows in `README.md`'s
table and its boxes in the `README.md` diagram go from dashed (planned) to
solid, and its host prerequisites and playbook go into `docs/rebuild.md`.
Documentation lands with the change, not after the last one.

1. This design, the implementation plan, the planned-state `README.md`
   diagram, and the Terraform and inventory for the five LXCs (step 1)
2. Pi-hole role (step 2)
3. Traefik role (step 3)
4. Gatus role (step 4)
5. LAN Orangutan role, after the raw-socket check (step 5)
6. Glance role, and the cutover (step 7) with its `CLAUDE.md` entry

## Out of scope

- Routing cluster applications through Traefik — sub-project 3, with the
  prod hub
- Scraping Traefik's and Gatus's `/metrics` — sub-project 3
- A second Pi-hole for redundancy
- Backups of the containers — no state here is hard to recreate except
  Gatus's history, which is not worth keeping
