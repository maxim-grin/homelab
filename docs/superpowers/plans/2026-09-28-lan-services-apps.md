# LAN Services Apps Implementation Plan (PRs 4-6)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Gatus watching the homelab and alerting on Telegram at `status.hl.mgryn.cc`, LAN Orangutan listing the LAN's devices with vendors at `lan.hl.mgryn.cc`, Glance at `home.hl.mgryn.cc` showing Proxmox, Pi-hole and Gatus on one page, and the router's DNS cut over to Pi-hole.

**Architecture:** Three Ansible roles in the pattern `roles/traefik` set: pinned release verified by SHA-256, dedicated system user, a systemd unit with `Restart=on-failure`, secrets in a root-only `0600` `EnvironmentFile`, `force_handlers` on the play. Each PR appends its route to `traefik_routes` and its endpoint to `gatus_endpoints`. PR 6 also teaches the merged `pihole` role an application password, and ends with the router cutover.

**Tech Stack:** Ansible core 2.21 (ansible-lint production profile), `ansible.builtin`; Gatus v5.37.0; LAN Orangutan v3.3.8 with Debian's `nmap`; Glance v0.8.6; Pi-hole v6 (FTL v6.7.1); Traefik v3.7.13; Debian 13 LXCs.

**Spec:** `docs/superpowers/specs/2026-09-27-lan-services-design.md` — sections "Goal", "Ansible", "gatus", "orangutan", "glance", "Secrets", "Rollout" steps 4-7, "Failure modes", "Pull requests" 4-6. Builds on `docs/superpowers/plans/2026-09-27-lan-services-foundation.md` (PRs 1-3, complete).

## Facts established while planning (2026-09-28)

These replace the spec's "Unverified" notes and shape the tasks below.

- **Gatus publishes no binaries**, only container images. The `linux/amd64` image of `ghcr.io/twin/gatus:v5.37.0` (manifest `sha256:9dc46f6692694a4219b5ac05ba1159a151a7b28ff030844d24dd041d4374b45a`) keeps the statically linked binary alone in layer `sha256:d20e87e818dd75483ecec9715e39c3d693b4b2b4113709780613d4bb410c0731` (26135833 bytes, a gzip tar holding one file, `gatus`). A registry blob's digest is the SHA-256 of its bytes, so `get_url` verifies it like a release checksum. The registry needs an anonymous bearer token from `https://ghcr.io/token?scope=repository:twin/gatus:pull`.
- **Glance and LAN Orangutan publish no checksums file**, but GitHub records a SHA-256 for every release asset. `glance-linux-amd64.tar.gz` v0.8.6 is `d27fb887eece24859f6ed3881ebb28c9d0a4fe6ae01acfa31bb39543fbf69784` (one file, `glance`). `lan-orangutan_3.3.8_amd64.deb` is `b727f9f9a33d074e41070737e2ea7750ff040b81a8c708b1d0233c900eb1f24c` (`Depends: nmap`; ships `/usr/local/bin/orangutan`, a `/lib/systemd/system/lan-orangutan.service` running as root, and a postinst that enables it). Both digests were checked against downloaded files.
- **Gatus ICMP** works unprivileged when Gatus is not root (v5.31.0+), so its unit needs no capabilities, but needs `net.ipv4.ping_group_range` to include its gid, which an unprivileged Proxmox LXC leaves disabled — the role sets it. Its Telegram provider takes `api-url`, which the rehearsal points at a local stub. Config accepts `${ENV}` substitution.
- **LAN Orangutan** reads `ORANGUTAN_PASSWORD_FILE`, `--config <ini>`, and `data_dir`. With no password set it serves a first-visit "create a password" page to whoever arrives first — so the role sets one. Upstream runs it as root because nmap reads MACs only when it believes it is root; `NMAP_PRIVILEGED=1` plus ambient `CAP_NET_RAW`/`CAP_NET_ADMIN` is nmap's documented way to get the same as a normal user. Port 291 also needs `CAP_NET_BIND_SERVICE`.
- **Glance** `dns-stats` supports `service: pihole-v6` with the admin _or_ an application password. `custom-api` sends arbitrary `headers`, so `Authorization: PVEAPIToken=...` works; `.JSON.Array ""` iterates a top-level array (Gatus's statuses API). Config accepts `${ENV}`, and Glance reloads its config file on change; environment changes need a restart. `glance -config <file> config:validate` exists.
- **Pi-hole v6 application passwords** cannot be hashed from the CLI (`pihole-FTL` has no hash command). The API creates one with its hash: `GET /api/auth/app` (authenticated) returns `{"app":{"password":…,"hash":…}}`. Setting `pihole-FTL --config webserver.api.app_pwhash '<hash>'` makes that password log in (`/api/auth` → `valid: true`), verified on a rehearsal Pi-hole. So the operator creates it once and keeps **both** in `secret.yaml`: the password for Glance, the hash for Pi-hole — which makes a rebuilt Pi-hole accept the same password.

## Global Constraints

- Branches: PR 4 on `lan-gatus` (exists; carries this plan). PR 5 on `lan-orangutan`, PR 6 on `lan-glance`, each cut from `main` only after the previous PR is merged **and** its operator task has passed. Never commit to `main`, never merge, never push to `main`. An agent's job ends at an open PR.
- Commits: Conventional Commits, subject ≤ 50 chars, imperative, lowercase, no trailing period, body wrapped at 72. Types: `feat fix refactor docs chore ops`.
- **No `Co-Authored-By` trailer and no "generated with" line** in commits or PR bodies. CLAUDE.md overrides any default attribution.
- Addresses: `pihole` `10.0.0.140`, `traefik` `10.0.0.141`, `glance` `10.0.0.142`, `gatus` `10.0.0.143`, `orangutan` `10.0.0.144`, router `10.0.0.1`, `nfs-01` `10.0.0.131`, `vault-02` `10.0.0.133`. Roles read them from `host_ips[...]`, never literals, except the router.
- Names: `status.hl.mgryn.cc` → Gatus `:8080`, `lan.hl.mgryn.cc` → LAN Orangutan `:291`, `home.hl.mgryn.cc` → Glance `:8080`.
- LXC resolvers are `1.1.1.1 10.0.0.1`, in that order, never Pi-hole — Gatus must keep resolving when Pi-hole is the thing that is down, and the router's rebind protection returns no address for `mgryn.cc` names pointing at private IPs, so it cannot come first (found in PR 4's operator run).
- Every role: version pinned in `defaults/main.yaml`, SHA-256 verified before install, dedicated system user, systemd unit with `Restart=on-failure`, `force_handlers: true` on its play. Secrets live only in a root `0600` `EnvironmentFile` read by systemd — or, where the service itself must open the file (LAN Orangutan's password file), `0400` owned by the service user — never group- or world-readable, with `no_log` on the task that writes it.
- Gatus and Glance trust the homelab CA (`~/.homelab-ca/ca.crt` on the controller) to reach `https://vault.mgryn.cc:8200`.
- Secrets are top-level variables in `ansible/secret.yaml` with a placeholder in `ansible/secret.yaml.example`: `gatus_telegram_token`, `gatus_telegram_chat_id`, `gatus_basic_user`, `gatus_basic_password`, `gatus_basic_password_bcrypt` (PR 4); `orangutan_password` (PR 5); `pihole_app_password`, `pihole_app_pwhash`, `glance_proxmox_token_id`, `glance_proxmox_token_secret` (PR 6).
- Memory: every LAN service LXC has 256M, no swap (Gatus and Glance raised from 128M in PR 4). Each role is rehearsed once under that cap.
- Documentation lands with the change that makes it true: each PR updates `README.md`'s table row, diagram (dashed `:::planned` → solid) and planned sentence, and `docs/rebuild.md` step 15.
- Never run a playbook against a real host, never `terraform plan`/`apply`, never read or decrypt `ansible/secret.yaml`. Rehearsals run only against local Docker containers.
- Tools: `ansible-lint`, `pre-commit` on PATH; `ansible-playbook` at `B=/home/ubuntu/.local/share/uv/tools/ansible-lint/bin` (pipe through `| cat`). `SCRATCH=/tmp/claude-1000/-home-ubuntu-homelab/1c3ea487-3b2b-4aa8-aeab-f14553ab3f8e/scratchpad` — if the executing session has another scratchpad, use that one and recreate what it lacks. `$SCRATCH/collections` holds `community.docker`; `$SCRATCH/lan-container.sh <name>` starts a systemd Debian 13 container; `$SCRATCH/mp/p.mjs` parses the README's Mermaid. From the foundation plan's Task 5, `$SCRATCH` also holds the Pi-hole rehearsal: `run-pihole.sh`, `check-pihole.sh`, `rehearse-pihole.ini`, `pihole-secrets.yaml`. Scripts one task writes (`lan-container-256.sh`, `run-gatus.sh`, `rehearsal-ca.crt`, `pihole-app.yaml`, …) are reused by later tasks; if a later task finds one missing, recreate it from the step that wrote it — the foundation plan's Task 5 and 6 for the Pi-hole ones.
- Rehearsal inventories set `ansible_user=root` under `[lan_services:vars]` (`ansible/ansible.cfg` sets `remote_user = ubuntu`). Rehearsals needing a Traefik certificate use `-e traefik_cert_resolver=letsencrypt-staging`.
- Read narrowly: `grep -n`, `sed -n`, `head`/`tail`.

## Review Focus

- **Pi-hole stops** (`pct stop 140`): Gatus must send one Telegram alert within two check intervals and one recovery when it returns — Task 1 rehearses a backend stopping and starting against a Telegram stub and asserts both messages.
- **Telegram unreachable or the token wrong**: Gatus must keep checking and serving its UI; a failed send is a log line, not a crash — Task 1 stops the Telegram stub mid-rehearsal and asserts the UI and API still answer.
- **nmap without effective capabilities**: LAN Orangutan would silently list IPs with no MACs or vendors — Task 4 asserts a peer container's MAC appears in the device list, as the `orangutan` user.
- **One Glance backend down** (Gatus stopped, a wrong Proxmox token): the page must still render, with only that widget in error — Task 9 stops Gatus and asserts the page and the other widgets still render.
- **Pi-hole rebuilt**: the application password must work again without anyone opening the UI — Task 8 applies the hash to a fresh container and logs in with the password.

---

## PR 4 — Gatus (branch `lan-gatus`)

### Task 1: The gatus role

**Files:**

- Create: `ansible/roles/gatus/meta/main.yaml`
- Create: `ansible/roles/gatus/defaults/main.yaml`
- Create: `ansible/roles/gatus/tasks/main.yaml`
- Create: `ansible/roles/gatus/handlers/main.yaml`
- Create: `ansible/roles/gatus/templates/config.yaml.j2`
- Create: `ansible/roles/gatus/templates/gatus.env.j2`
- Create: `ansible/roles/gatus/templates/gatus.service.j2`
- Modify: `ansible/playbooks/lan_services.yaml` (append a play after Traefik's)
- Modify: `ansible/secret.yaml.example` (append two secrets)

**Interfaces:**

- Consumes: group `gatus` (inventory, PR 1); `host_ips['pve']`, `host_ips['nfs-01']`, `host_ips['pihole']`; `gatus_telegram_token`, `gatus_telegram_chat_id` from `secret.yaml`; the CA at `~/.homelab-ca/ca.crt` on the controller.
- Produces: Gatus on `http://<gatus>:8080` with `/api/v1/endpoints/statuses` and `/metrics`. `gatus_endpoints`, a list of `{name, group, url, conditions}` with optional `dns: {query_name, query_type}`, `insecure`, `interval`, which PRs 5 and 6 append to. `gatus_interval` (default `1m`).

- [x] **Step 1: Rehearsal fixtures, and see the checks fail**

```bash
export SCRATCH B=/home/ubuntu/.local/share/uv/tools/ansible-lint/bin
# A 256M container, the size of the real LXC. Bootstrapping systemd and
# dbus from a bare debian:trixie image needs more headroom than 256M gives
# it at container-creation time (OOM during that install is reproducible
# below that), so this boots unconstrained and only clamps memory once
# systemd is up -- the real LXC never pays that cost, since it clones a
# template with systemd already built in.
cat > $SCRATCH/lan-container-256.sh <<'FIXEOF'
#!/bin/sh
# usage: lan-container-256.sh <name> -- a 256M Debian 13 systemd container
"$(dirname "$0")/lan-container.sh" "$1" || exit 1
docker update --memory 256m --memory-swap 256m "$1" >/dev/null
FIXEOF
chmod +x $SCRATCH/lan-container-256.sh
$SCRATCH/lan-container-256.sh lan-gatus

# A throwaway CA standing in for ~/.homelab-ca/ca.crt.
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=rehearsal-ca" \
  -keyout $SCRATCH/rehearsal-ca.key -out $SCRATCH/rehearsal-ca.crt 2>/dev/null

# Inside the container: a backend Gatus watches, and a Telegram stub that
# records every sendMessage body.
docker exec lan-gatus sh -c 'apt-get install -y -qq python3 curl procps >/dev/null'
docker exec lan-gatus sh -c 'mkdir -p /srv/backend && echo ok > /srv/backend/index.html'
docker exec -i lan-gatus sh -c 'cat > /usr/local/bin/tg-stub.py' <<'EOF'
import http.server, json
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with open("/tmp/telegram.log", "ab") as f:
            f.write(body + b"\n")
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
        self.wfile.write(json.dumps({"ok": True, "result": {}}).encode())
http.server.HTTPServer(("127.0.0.1", 9002), H).serve_forever()
EOF
docker exec -d lan-gatus python3 /usr/local/bin/tg-stub.py
docker exec -d lan-gatus sh -c 'cd /srv/backend && python3 -m http.server 9001 --bind 127.0.0.1'

cat > $SCRATCH/rehearse-gatus.ini <<'EOF'
[gatus]
gatus ansible_connection=community.docker.docker ansible_host=lan-gatus
[lan_services:children]
gatus
[lan_services:vars]
ansible_become=false
ansible_user=root
EOF
cat > $SCRATCH/gatus-vars.yaml <<EOF
host_ips: {pve: 192.0.2.10, nfs-01: 192.0.2.11, pihole: 192.0.2.12}
gatus_telegram_token: "123456:rehearsal-token"
gatus_telegram_chat_id: "42"
gatus_telegram_api_url: "http://127.0.0.1:9002"
gatus_ca_cert_src: "$SCRATCH/rehearsal-ca.crt"
gatus_interval: 10s
gatus_endpoints:
  - {name: backend, group: rehearsal, url: "http://127.0.0.1:9001/", conditions: ["[STATUS] == 200"]}
  - {name: backend-tcp, group: rehearsal, url: "tcp://127.0.0.1:9001", conditions: ["[CONNECTED] == true"]}
  - {name: loopback-icmp, group: rehearsal, url: "icmp://127.0.0.1", conditions: ["[CONNECTED] == true"]}
EOF
cat > $SCRATCH/run-gatus.sh <<'EOF'
#!/bin/sh
cd /home/ubuntu/homelab/ansible
ANSIBLE_COLLECTIONS_PATH=$SCRATCH/collections:$HOME/.ansible/collections \
  $B/ansible-playbook -i $SCRATCH/rehearse-gatus.ini playbooks/lan_services.yaml \
  -e @$SCRATCH/gatus-vars.yaml --limit gatus "$@" 2>&1 | cat
EOF
chmod +x $SCRATCH/run-gatus.sh

cat > $SCRATCH/check-gatus.sh <<'EOF'
#!/bin/sh
C=lan-gatus; fail=0
ok() { echo "ok $1"; }; bad() { echo "FAIL $1"; fail=1; }
s=$(docker exec $C curl -s http://127.0.0.1:8080/api/v1/endpoints/statuses)
for n in backend backend-tcp loopback-icmp; do
  echo "$s" | python3 -c "import sys,json; d={e['name']:e for e in json.load(sys.stdin)}; r=d['$n']['results']; sys.exit(0 if r and r[-1]['success'] else 1)" 2>/dev/null \
    && ok "$n up" || bad "$n up"
done
docker exec $C curl -s http://127.0.0.1:8080/metrics | grep -q '^gatus_results_total' && ok metrics || bad metrics
docker exec $C stat -c '%a %U' /etc/gatus/gatus.env | grep -q '^600 root$' && ok "env 0600 root" || bad "env mode"
docker exec $C sh -c 'stat -c %U /proc/$(systemctl show -p MainPID --value gatus)' | grep -q '^gatus$' && ok "runs as gatus" || bad user
docker exec $C systemctl is-enabled gatus >/dev/null && ok enabled || bad enabled
# update-ca-certificates links each added CA as /etc/ssl/certs/<name>.pem.
docker exec $C sh -c 'openssl x509 -noout -subject -in /etc/ssl/certs/homelab-ca.pem' 2>/dev/null | grep -q rehearsal-ca \
  && ok "CA trusted" || bad "CA trusted"
docker exec $C test -s /var/lib/gatus/data.db && ok "sqlite history" || bad "sqlite history"
exit $fail
EOF
chmod +x $SCRATCH/check-gatus.sh
$SCRATCH/check-gatus.sh; echo "exit=$?"
```

Expected: `FAIL` lines, `exit=1`.

- [x] **Step 2: Metadata and defaults**

`ansible/roles/gatus/meta/main.yaml`:

```yaml
---
galaxy_info:
  author: homelab
  description: Gatus uptime checks with Telegram alerts
  license: MIT
  min_ansible_version: "2.17"
  platforms:
    - name: Debian
      versions:
        - trixie
dependencies: []
```

`ansible/roles/gatus/defaults/main.yaml`:

```yaml
---
gatus_version: "5.37.0"

# Gatus publishes container images, not binaries. The linux/amd64 image
# keeps the statically linked binary alone in one layer, fetched here by
# digest; a blob's digest is the SHA-256 of its bytes, so get_url checks
# it like a release checksum. For a new version, read the new digest:
#   T=$(curl -s 'https://ghcr.io/token?scope=repository:twin/gatus:pull' | jq -r .token)
#   M=$(curl -s -H "Authorization: Bearer $T" \
#     -H 'Accept: application/vnd.oci.image.index.v1+json' \
#     https://ghcr.io/v2/twin/gatus/manifests/v<version> \
#     | jq -r '.manifests[] | select(.platform.architecture=="amd64" and .platform.os=="linux") | .digest')
#   curl -s -H "Authorization: Bearer $T" \
#     -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
#     https://ghcr.io/v2/twin/gatus/manifests/$M | jq -r '.layers | max_by(.size) | .digest'
gatus_image: twin/gatus
gatus_layer_digest: "sha256:d20e87e818dd75483ecec9715e39c3d693b4b2b4113709780613d4bb410c0731"

gatus_port: 8080

# The homelab CA that signs vault.mgryn.cc, on the machine running Ansible.
gatus_ca_cert_src: "~/.homelab-ca/ca.crt"

# The rehearsal points this at a local stub.
gatus_telegram_api_url: https://api.telegram.org

# With failure-threshold 2, an outage alerts within two intervals.
gatus_interval: 1m

gatus_router: 10.0.0.1

# Every check. PRs 5 and 6 append their service's name. Traefik renews at
# 30 days remaining, so the 14-day (336h) certificate check is two weeks'
# warning that renewal has stopped.
gatus_endpoints:
  - name: Proxmox UI
    group: infra
    url: "https://{{ host_ips['pve'] }}:8006"
    insecure: true
    conditions: ["[CONNECTED] == true", "[STATUS] == 200"]
  - name: NFS
    group: infra
    url: "tcp://{{ host_ips['nfs-01'] }}:2049"
    conditions: ["[CONNECTED] == true"]
  # A sealed Vault answers 503: this is the first thing that notices.
  - name: Vault
    group: infra
    url: https://vault.mgryn.cc:8200/v1/sys/health
    conditions: ["[CONNECTED] == true", "[STATUS] == 200"]
  - name: Pi-hole DNS
    group: dns
    url: "{{ host_ips['pihole'] }}"
    dns:
      query_name: example.com
      query_type: A
    conditions: ["[DNS_RCODE] == NOERROR"]
  - name: pihole.hl.mgryn.cc
    group: lan
    url: https://pihole.hl.mgryn.cc/admin/
    conditions:
      [
        "[CONNECTED] == true",
        "[STATUS] < 400",
        "[CERTIFICATE_EXPIRATION] > 336h",
      ]
  - name: proxmox.hl.mgryn.cc
    group: lan
    url: https://proxmox.hl.mgryn.cc/
    conditions:
      [
        "[CONNECTED] == true",
        "[STATUS] < 400",
        "[CERTIFICATE_EXPIRATION] > 336h",
      ]
  # The dashboard sits behind basic auth: 401 proves Traefik and its auth
  # both answer.
  - name: traefik.hl.mgryn.cc
    group: lan
    url: https://traefik.hl.mgryn.cc/dashboard/
    conditions:
      [
        "[CONNECTED] == true",
        "[STATUS] == 401",
        "[CERTIFICATE_EXPIRATION] > 336h",
      ]
  - name: status.hl.mgryn.cc
    group: lan
    url: https://status.hl.mgryn.cc/
    conditions:
      [
        "[CONNECTED] == true",
        "[STATUS] < 400",
        "[CERTIFICATE_EXPIRATION] > 336h",
      ]
  - name: jobs.mgryn.cc
    group: dev
    url: https://jobs.mgryn.cc/
    conditions: ["[CONNECTED] == true", "[STATUS] < 400"]
  - name: Router
    group: network
    url: "icmp://{{ gatus_router }}"
    conditions: ["[CONNECTED] == true"]
```

- [x] **Step 3: Templates**

`ansible/roles/gatus/templates/config.yaml.j2`:

```jinja
# Managed by Ansible (roles/gatus). ${...} values come from
# /etc/gatus/gatus.env, never from this file.
metrics: true
web:
  port: {{ gatus_port }}
storage:
  type: sqlite
  path: /var/lib/gatus/data.db
alerting:
  telegram:
    token: "${GATUS_TELEGRAM_TOKEN}"
    id: "${GATUS_TELEGRAM_CHAT_ID}"
    api-url: "{{ gatus_telegram_api_url }}"
    default-alert:
      enabled: true
      send-on-resolved: true
      failure-threshold: 2
      success-threshold: 2
endpoints:
{% for e in gatus_endpoints %}
  - name: "{{ e.name }}"
    group: "{{ e.group }}"
    url: "{{ e.url }}"
    interval: {{ e.interval | default(gatus_interval) }}
{% if e.dns is defined %}
    dns:
      query-name: "{{ e.dns.query_name }}"
      query-type: "{{ e.dns.query_type }}"
{% endif %}
{% if e.insecure | default(false) %}
    client:
      insecure: true
{% endif %}
    conditions:
{% for c in e.conditions %}
      - "{{ c }}"
{% endfor %}
    alerts:
      - type: telegram
{% endfor %}
```

`ansible/roles/gatus/templates/gatus.env.j2`:

```jinja
# Managed by Ansible. Read by systemd as root; mode 0600.
GATUS_TELEGRAM_TOKEN={{ gatus_telegram_token }}
GATUS_TELEGRAM_CHAT_ID={{ gatus_telegram_chat_id }}
```

`ansible/roles/gatus/templates/gatus.service.j2`:

```jinja
# Managed by Ansible (roles/gatus).
[Unit]
Description=Gatus uptime monitor
After=network-online.target
Wants=network-online.target

[Service]
User=gatus
Group=gatus
EnvironmentFile=/etc/gatus/gatus.env
Environment=GATUS_CONFIG_PATH=/etc/gatus/config.yaml
WorkingDirectory=/var/lib/gatus
ExecStart=/usr/local/bin/gatus
NoNewPrivileges=true
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

- [x] **Step 4: Tasks and handlers**

`ansible/roles/gatus/tasks/main.yaml`:

```yaml
---
- name: Require Gatus's secrets and addresses
  ansible.builtin.assert:
    that:
      - gatus_telegram_token is defined
      - gatus_telegram_token | length > 0
      - gatus_telegram_chat_id is defined
      - gatus_telegram_chat_id | string | length > 0
      - host_ips['pve'] is defined
      - host_ips['nfs-01'] is defined
      - host_ips['pihole'] is defined
    fail_msg: >-
      gatus_telegram_token, gatus_telegram_chat_id and host_ips for pve,
      nfs-01 and pihole must be set in ansible/secret.yaml.
    quiet: true

- name: Create the gatus system user
  ansible.builtin.user:
    name: gatus
    system: true
    shell: /usr/sbin/nologin
    home: /var/lib/gatus
    create_home: false

- name: Create Gatus's directories
  ansible.builtin.file:
    path: "{{ item.path }}"
    state: directory
    owner: "{{ item.owner }}"
    group: gatus
    mode: "{{ item.mode }}"
  loop:
    - { path: /etc/gatus, owner: root, mode: "0750" }
    - { path: /var/lib/gatus, owner: gatus, mode: "0700" }
    - { path: "/opt/gatus/{{ gatus_version }}", owner: root, mode: "0755" }

- name: Install ca-certificates
  ansible.builtin.apt:
    name: ca-certificates
    state: present
    update_cache: true
    cache_valid_time: 3600

# vault.mgryn.cc is signed by the homelab's private CA.
- name: Trust the homelab CA
  ansible.builtin.copy:
    content: "{{ lookup('ansible.builtin.file', gatus_ca_cert_src) }}\n"
    dest: /usr/local/share/ca-certificates/homelab-ca.crt
    owner: root
    group: root
    mode: "0644"
  notify:
    - Update the CA trust store
    - Restart gatus

- name: Check for this version's binary
  ansible.builtin.stat:
    path: "/opt/gatus/{{ gatus_version }}/gatus"
  register: gatus_binary

# Only when the binary is missing, so a run with ghcr.io unreachable
# still succeeds once Gatus is installed.
- name: Fetch the Gatus binary layer
  when: not gatus_binary.stat.exists
  block:
    - name: Get an anonymous ghcr.io pull token
      ansible.builtin.uri:
        url: "https://ghcr.io/token?scope=repository:{{ gatus_image }}:pull"
        return_content: true
      register: gatus_registry_token
      no_log: true

    - name: Download the layer, checked against its digest
      ansible.builtin.get_url:
        url: "https://ghcr.io/v2/{{ gatus_image }}/blobs/{{ gatus_layer_digest }}"
        dest: "/opt/gatus/gatus-{{ gatus_version }}-layer.tar.gz"
        checksum: "{{ gatus_layer_digest }}"
        headers:
          Authorization: "Bearer {{ gatus_registry_token.json.token }}"
        mode: "0644"
      no_log: true

    - name: Unpack the binary
      ansible.builtin.unarchive:
        src: "/opt/gatus/gatus-{{ gatus_version }}-layer.tar.gz"
        dest: "/opt/gatus/{{ gatus_version }}"
        remote_src: true
        include: [gatus]
        creates: "/opt/gatus/{{ gatus_version }}/gatus"

- name: Point /usr/local/bin/gatus at this version
  ansible.builtin.file:
    src: "/opt/gatus/{{ gatus_version }}/gatus"
    dest: /usr/local/bin/gatus
    state: link
  notify: Restart gatus

- name: Write the configuration
  ansible.builtin.template:
    src: config.yaml.j2
    dest: /etc/gatus/config.yaml
    owner: root
    group: gatus
    mode: "0640"
  notify: Restart gatus

- name: Write the Telegram secrets
  ansible.builtin.template:
    src: gatus.env.j2
    dest: /etc/gatus/gatus.env
    owner: root
    group: root
    mode: "0600"
  no_log: true
  notify: Restart gatus

- name: Install the systemd unit
  ansible.builtin.template:
    src: gatus.service.j2
    dest: /etc/systemd/system/gatus.service
    mode: "0644"
  notify: Restart gatus

- name: Start Gatus at boot
  ansible.builtin.systemd_service:
    name: gatus
    state: started
    enabled: true
    daemon_reload: true
```

`ansible/roles/gatus/handlers/main.yaml` (defined in this order, so the trust store is updated before Gatus restarts):

```yaml
---
- name: Update the CA trust store
  ansible.builtin.command: update-ca-certificates
  changed_when: true

- name: Restart gatus
  ansible.builtin.systemd_service:
    name: gatus
    state: restarted
    daemon_reload: true
```

- [x] **Step 5: The play and the example secrets**

Append to `ansible/playbooks/lan_services.yaml`:

```yaml
- name: Gatus
  hosts: gatus
  # A later task failing on a run that already rewrote the config, env
  # file or unit must not leave the old process running -- the restart
  # handler has to fire regardless.
  force_handlers: true
  roles:
    - gatus
```

Append to `ansible/secret.yaml.example`:

```yaml
# Gatus alerts through a Telegram bot: @BotFather -> /newbot gives the
# token. Send the bot a message, then
#   curl -s https://api.telegram.org/bot<token>/getUpdates
# shows the chat id (message.chat.id).
gatus_telegram_token: "<bot token>"
gatus_telegram_chat_id: "<chat id>"
```

- [x] **Step 6: Rehearse — first run, checks, idempotence**

```bash
$SCRATCH/run-gatus.sh | grep -E 'changed=|failed=|FAILED|fatal'
sleep 25; $SCRATCH/check-gatus.sh; echo "exit=$?"
$SCRATCH/run-gatus.sh | grep -E 'changed=|failed='
docker stats --no-stream --format '{{.MemUsage}}' lan-gatus
```

Expected: first run `failed=0`; checks all `ok`, `exit=0`; second run `changed=0 ... failed=0`; memory well under 256MiB. If `loopback-icmp` fails, read `journalctl -u gatus` and `sysctl net.ipv4.ping_group_range` in the container before changing anything: Gatus pings unprivileged as a non-root user, which needs the group range to include `gatus`'s gid — fix the role (a `sysctl` drop-in), not the check.

- [x] **Step 7: Rehearse — an outage alerts once, a recovery resolves once, and a dead Telegram changes nothing**

```bash
docker exec lan-gatus sh -c ': > /tmp/telegram.log'
docker exec lan-gatus pkill -f 'http.server 9001'
sleep 40
docker exec lan-gatus sh -c 'grep -c backend /tmp/telegram.log'
docker exec -d lan-gatus sh -c 'cd /srv/backend && python3 -m http.server 9001 --bind 127.0.0.1'
sleep 40
docker exec lan-gatus cat /tmp/telegram.log | python3 -c "import sys; t=sys.stdin.read(); print('triggered', t.count('TRIGGERED') or t.lower().count('trigger')); print('resolved', t.count('RESOLVED') or t.lower().count('resolved'))"
# Telegram gone: Gatus must keep running and answering.
docker exec lan-gatus pkill -f tg-stub.py
docker exec lan-gatus pkill -f 'http.server 9001'
sleep 40
docker exec lan-gatus systemctl is-active gatus
docker exec lan-gatus curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/api/v1/endpoints/statuses
docker rm -f lan-gatus
```

Expected: the log mentions `backend` after the outage; one triggered and one resolved message (read the log if the counts differ — the wording of Gatus's Telegram text decides the grep, the point is exactly one of each); with Telegram gone, `active` and `200`.

- [x] **Step 8: Lint and commit**

```bash
cd /home/ubuntu/homelab/ansible && ansible-lint roles/gatus playbooks/lan_services.yaml
cd .. && git add ansible/roles/gatus ansible/playbooks/lan_services.yaml ansible/secret.yaml.example
git commit -m "feat: add the gatus role" -m "Gatus from its image's binary layer, fetched by digest so the download
is checked like a release checksum, running as its own user. Checks the
Proxmox UI, NFS, Vault, Pi-hole DNS, every *.hl name with its
certificate, jobs.mgryn.cc and the router, alerting on Telegram on
failure and recovery. Trusts the homelab CA for vault.mgryn.cc."
```

### Task 2: Route, spec and documentation for Gatus

**Files:**

- Modify: `ansible/roles/traefik/defaults/main.yaml` (append to `traefik_routes`)
- Modify: `ansible/roles/traefik/tasks/main.yaml` (the assert)
- Modify: `docs/superpowers/specs/2026-09-27-lan-services-design.md` (decisions from planning)
- Modify: `README.md` (table row, diagram, planned sentence, the `*.hl` sentence)
- Modify: `docs/rebuild.md` (step 15)

**Interfaces:**

- Consumes: `traefik_routes` entries `{name, host, url, insecure}` (PR 3); Gatus on `:8080` (Task 1).
- Produces: `status.hl.mgryn.cc`.

- [x] **Step 1: See the route missing**

```bash
cat > $SCRATCH/render-routes.yaml <<'EOF'
- hosts: localhost
  gather_facts: false
  vars_files: [/home/ubuntu/homelab/ansible/roles/traefik/defaults/main.yaml]
  vars:
    host_ips: {pve: 192.0.2.10, pihole: 192.0.2.12, gatus: 192.0.2.13, orangutan: 192.0.2.14, glance: 192.0.2.15}
    traefik_dashboard_users: ["admin:x"]
  tasks:
    - ansible.builtin.template:
        src: /home/ubuntu/homelab/ansible/roles/traefik/templates/routes.yaml.j2
        dest: "{{ lookup('env', 'SCRATCH') }}/routes.rendered.yaml"
        mode: "0644"
EOF
$B/ansible-playbook $SCRATCH/render-routes.yaml 2>&1 | grep -E 'failed=' | cat
python3 -c "import yaml,os; d=yaml.safe_load(open(os.environ['SCRATCH']+'/routes.rendered.yaml')); print(sorted(d['http']['routers']))"
```

Expected: routers `dashboard`, `pihole`, `proxmox` — no `status`.

- [x] **Step 2: Add the route**

Append to `traefik_routes` in `ansible/roles/traefik/defaults/main.yaml`:

```yaml
- name: status
  host: "status.{{ traefik_domain }}"
  url: "http://{{ host_ips['gatus'] }}:8080"
  insecure: false
```

In `ansible/roles/traefik/tasks/main.yaml`, add `- host_ips['gatus'] is defined` to the first assert's `that:` list and name `host_ips['gatus']` in its `fail_msg`.

Re-run Step 1's commands. Expected: routers include `status`, and `yaml.safe_load` succeeds.

- [x] **Step 3: Record the planning decisions in the spec**

In `docs/superpowers/specs/2026-09-27-lan-services-design.md`:

- In "## Ansible", replace the bullet "pins its version in `defaults/main.yaml` and verifies the release's SHA-256 before installing (Pi-hole excepted, below)" with:

  ```markdown
  - pins its version in `defaults/main.yaml` and verifies a SHA-256 before
    installing (Pi-hole excepted, below): Traefik's published checksums
    file; GitHub's per-asset digest for Glance and LAN Orangutan, which
    publish none; and, for Gatus, which publishes only container images,
    the digest of the image layer holding its binary
  ```

- In "### orangutan", replace the paragraph beginning "**Unverified:** that an unprivileged LXC can hold raw sockets" with:

  ```markdown
  It runs as its own user, not root as upstream's unit does: nmap sends
  raw ARP and reads MACs as a normal user given `CAP_NET_RAW` and
  `CAP_NET_ADMIN` and `NMAP_PRIVILEGED=1`, and `CAP_NET_BIND_SERVICE`
  covers port 291. Its dashboard password is `orangutan_password`;
  without one, the first visitor would be asked to create it. The
  raw-socket check in an unprivileged LXC runs before the role is
  written; if it fails, this one container becomes privileged.
  ```

- In "### glance", replace the paragraph beginning "**Unverified:** that Glance's DNS widget" with:

  ```markdown
  Checked while planning: `dns-stats` supports `pihole-v6` with an
  application password, and `custom-api` sends arbitrary headers, so
  the Proxmox token header works. Pi-hole cannot hash an application
  password it did not generate, so the operator creates one once through
  its API and keeps both halves in `secret.yaml`: `pihole_app_password`
  for Glance, `pihole_app_pwhash` for the `pihole` role to apply, which
  keeps it valid across a rebuilt Pi-hole.
  ```

- In "## Secrets", replace the row `| `pihole_app_password` | Glance's DNS widget |` with two rows, and add one after the Traefik rows:

  ```markdown
  | `pihole_app_password` | Glance's DNS widget |
  | `pihole_app_pwhash` | Pi-hole, the hash of that password |
  ```

  ```markdown
  | `orangutan_password` | LAN Orangutan's dashboard |
  ```

- [x] **Step 4: README**

- The LXCs row: description becomes "`pihole` (DNS, ad blocking) at `.140`, `traefik` (`*.hl.mgryn.cc`) at `.141`, `gatus` (uptime, Telegram alerts) at `.143`; the rest empty until their roles land"; append `, `ansible/roles/gatus`` to its "where defined" cell.
- The planned sentence: remove Gatus — "**Planned, not yet running:** Glance and LAN Orangutan,".
- The `*.hl` sentence: "`pihole.hl.mgryn.cc`, `proxmox.hl.mgryn.cc` and `traefik.hl.mgryn.cc`" becomes "`pihole.hl.mgryn.cc`, `proxmox.hl.mgryn.cc`, `traefik.hl.mgryn.cc` and `status.hl.mgryn.cc`". Re-wrap to ~80 columns.
- Diagram: `gatus["Gatus .143<br/>uptime"]:::planned` → `gatus["Gatus .143<br/>uptime"]`; `telegram["Telegram"]:::planned` → `telegram["Telegram"]`; `traefik -.-> gatus` → `traefik --> gatus`; `gatus -. "alerts" .-> telegram` → `gatus -- "alerts" --> telegram`.

- [x] **Step 5: rebuild.md step 15**

Append to step 15, after the Traefik paragraph, at its indentation:

```markdown
    **Gatus** needs `gatus_telegram_token` and `gatus_telegram_chat_id`
    in `secret.yaml` (the comments in `secret.yaml.example` say where
    each comes from) and `~/.homelab-ca/ca.crt` on the workstation, which
    `playbooks/vault.yaml` created. Re-run the Traefik play too, for the
    `status.hl.mgryn.cc` route. Check: `https://status.hl.mgryn.cc` shows
    every endpoint green, and `pct stop 140` on the host sends a Telegram
    alert within two minutes, `pct start 140` a recovery.
```

- [x] **Step 6: Check and commit**

```bash
cd /home/ubuntu/homelab
node $SCRATCH/mp/p.mjs
cd ansible && ansible-lint roles/traefik && cd ..
pre-commit run --all-files 2>&1 | grep -iv 'passed\|skipped'
git add ansible/roles/traefik README.md docs/rebuild.md docs/superpowers/specs/2026-09-27-lan-services-design.md
git commit -m "docs: document gatus" -m "Gatus and Telegram go solid in the README diagram, status.hl.mgryn.cc
gets its Traefik route, rebuild.md covers the bot and the alert test,
and the spec records the checksum sources, LAN Orangutan's user and
password, and Pi-hole's application password found while planning."
```

Expected: `PARSE OK`; ansible-lint passes; no pre-commit failures.

### Task 3: Operator — Gatus (owner, not an agent)

- [x] `terraform plan -var-file=shared.tfvars` in `terraform/environments/shared`: **0 to add, 2 to change, 0 to destroy** — memory 128 → 256 on `module.lan_service["gatus"]` and `["glance"]`, nothing else. Any `-/+` (replace) or change outside `memory` is a stop. Then `terraform apply -var-file=shared.tfvars`. The containers keep running; Proxmox raises an LXC's memory live.
- [x] `terraform plan -var-file=shared.tfvars` again after the resolver change: **0 to add, 5 to change, 0 to destroy** — `nameserver` on all five `module.lan_service[...]`, nothing else; apply. Proxmox rewrites a container's `resolv.conf` only when it starts, so `pct reboot 143` (and 140-142, 144 when convenient); then `pct exec 143 -- cat /etc/resolv.conf` shows `nameserver 1.1.1.1` first. `pct exec 143 -- getent hosts vault.mgryn.cc` prints `10.0.0.133`.
- [x] Telegram: create a bot with @BotFather (`/newbot`), send it a message, read the chat id from `https://api.telegram.org/bot<token>/getUpdates`.
- [x] On the `lan-gatus` checkout: `ansible-vault edit ansible/secret.yaml` — add `gatus_telegram_token`, `gatus_telegram_chat_id`, `gatus_basic_user`, `gatus_basic_password` and `gatus_basic_password_bcrypt` (`htpasswd -nbB <user> '<password>' | cut -d: -f2` makes the hash); commit (`ops: add gatus secrets`) and push to the branch.
- [x] `ansible-playbook -i inventories/shared playbooks/lan_services.yaml -e @secret.yaml --ask-vault-pass --limit traefik,gatus`: `failed=0`; a second run `changed=0`.
- [x] On the host: `pct exec 143 -- cat /sys/fs/cgroup/memory.peak` (record it in the PR; well under 256M) and `pct exec 143 -- cat /proc/sys/net/ipv4/ping_group_range` shows `0 65535`.
- [x] `https://status.hl.mgryn.cc` asks for the Gatus login; after it, a valid certificate and every endpoint green within about two minutes (two check intervals).
- [x] `pct stop 140` on the host: a Telegram alert for "Pi-hole DNS" (and `pihole.hl.mgryn.cc`) within about two minutes (two check intervals). `pct start 140`: a recovery message.
- [x] **LAN Orangutan's raw-socket check, before PR 5 is written** (the spec requires it). On the host: `pct exec 144 -- sh -c 'apt-get update -qq && apt-get install -y -qq nmap >/dev/null && nmap -sn -PR 10.0.0.0/24 | grep -c "MAC Address"'` prints a number close to the device count, and, as a normal user with capabilities: `pct exec 144 -- setpriv --reuid=nobody --regid=nogroup --clear-groups --inh-caps=+net_raw,+net_admin --ambient-caps=+net_raw,+net_admin env NMAP_PRIVILEGED=1 nmap -sn -PR 10.0.0.0/24 | grep -c "MAC Address"` prints a similar number. Record both numbers in the PR. If either is `0`, stop: PR 5 needs `orangutan` privileged, which is a Terraform change and a new plan decision.
- [x] `gh pr ready <N>`; the owner merges.

---

## PR 5 — LAN Orangutan (branch `lan-orangutan`)

### Task 4: The orangutan role

**Files:**

- Create: `ansible/roles/orangutan/meta/main.yaml`
- Create: `ansible/roles/orangutan/defaults/main.yaml`
- Create: `ansible/roles/orangutan/tasks/main.yaml`
- Create: `ansible/roles/orangutan/handlers/main.yaml`
- Create: `ansible/roles/orangutan/templates/config.ini.j2`
- Create: `ansible/roles/orangutan/templates/lan-orangutan.service.j2`
- Modify: `ansible/playbooks/lan_services.yaml` (append a play after Gatus's)
- Modify: `ansible/secret.yaml.example` (append `orangutan_password`)

**Interfaces:**

- Consumes: group `orangutan` (PR 1); `orangutan_password` from `secret.yaml`; Task 3's raw-socket result (both counts non-zero).
- Produces: LAN Orangutan on `http://<orangutan>:291`, scanning `orangutan_networks` every `orangutan_scan_interval` seconds, data in `/var/lib/orangutan`.

- [x] **Step 1: Two containers on one network, and the checks failing**

```bash
docker network create lan-scan >/dev/null 2>&1 || true
# Boots unconstrained on lan-scan and only clamps memory once systemd is
# up, like lan-container-256.sh -- bootstrapping systemd needs more
# headroom than 256M gives it at container-creation time.
cat > $SCRATCH/lan-container-scan.sh <<'FIXEOF'
#!/bin/sh
# usage: lan-container-scan.sh <name> -- a 256M Debian 13 systemd
# container on the lan-scan network
docker rm -f "$1" >/dev/null 2>&1
docker run -d --name "$1" --network lan-scan --privileged --cgroupns=host \
  --tmpfs /run --tmpfs /run/lock -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  debian:trixie bash -c 'apt-get update -qq && apt-get install -y -qq systemd systemd-sysv dbus >/dev/null && exec /lib/systemd/systemd' >/dev/null
for i in $(seq 60); do
  s=$(docker exec "$1" systemctl is-system-running 2>/dev/null)
  case "$s" in running|degraded) echo "$1: $s"; break;; esac
  sleep 2
done
docker update --memory 256m --memory-swap 256m "$1" >/dev/null
FIXEOF
chmod +x $SCRATCH/lan-container-scan.sh
$SCRATCH/lan-container-scan.sh lan-orangutan
docker rm -f lan-peer >/dev/null 2>&1; docker run -d --name lan-peer --network lan-scan debian:trixie sleep infinity >/dev/null
docker exec lan-orangutan sh -c 'apt-get install -y -qq curl >/dev/null'
SUBNET=$(docker network inspect lan-scan -f '{{(index .IPAM.Config 0).Subnet}}')
PEER_IP=$(docker inspect lan-peer -f '{{.NetworkSettings.Networks.lan-scan.IPAddress}}')
PEER_MAC=$(docker inspect lan-peer -f '{{.NetworkSettings.Networks.lan-scan.MacAddress}}')
echo "$SUBNET $PEER_IP $PEER_MAC" > $SCRATCH/lan-scan.env
cat > $SCRATCH/rehearse-orangutan.ini <<'EOF'
[orangutan]
orangutan ansible_connection=community.docker.docker ansible_host=lan-orangutan
[lan_services:children]
orangutan
[lan_services:vars]
ansible_become=false
ansible_user=root
EOF
cat > $SCRATCH/orangutan-vars.yaml <<EOF
orangutan_password: "rehearsal-password-123"
orangutan_networks: ["$SUBNET"]
orangutan_scan_interval: 30
EOF
cat > $SCRATCH/run-orangutan.sh <<'EOF'
#!/bin/sh
cd /home/ubuntu/homelab/ansible
ANSIBLE_COLLECTIONS_PATH=$SCRATCH/collections:$HOME/.ansible/collections \
  $B/ansible-playbook -i $SCRATCH/rehearse-orangutan.ini playbooks/lan_services.yaml \
  -e @$SCRATCH/orangutan-vars.yaml --limit orangutan "$@" 2>&1 | cat
EOF
chmod +x $SCRATCH/run-orangutan.sh
cat > $SCRATCH/check-orangutan.sh <<'EOF'
#!/bin/sh
C=lan-orangutan; fail=0
read SUBNET PEER_IP PEER_MAC < $SCRATCH/lan-scan.env
ok() { echo "ok $1"; }; bad() { echo "FAIL $1"; fail=1; }
c=$(docker exec $C curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:291/)
[ "$c" = "200" ] || [ "$c" = "302" ] || [ "$c" = "303" ] && ok "ui answers $c" || bad "ui $c"
# The device list, read the way the service stores it, as the service's user.
l=$(docker exec $C runuser -u orangutan -- env ORANGUTAN_DATA_DIR=/var/lib/orangutan \
  /usr/local/bin/orangutan list --config /etc/orangutan/config.ini 2>&1)
echo "$l" | grep -q "$PEER_IP" && ok "peer listed" || bad "peer listed"
echo "$l" | grep -qi "$PEER_MAC" && ok "peer MAC $PEER_MAC" || bad "peer MAC (nmap without effective capabilities?)"
docker exec $C sh -c 'stat -c %U /proc/$(systemctl show -p MainPID --value lan-orangutan)' | grep -q '^orangutan$' && ok "runs as orangutan" || bad user
docker exec $C stat -c '%a %U' /etc/orangutan/password | grep -q '^400 orangutan$' && ok "password 0400" || bad "password mode"
docker exec $C systemctl is-enabled lan-orangutan >/dev/null && ok enabled || bad enabled
exit $fail
EOF
chmod +x $SCRATCH/check-orangutan.sh
$SCRATCH/check-orangutan.sh; echo "exit=$?"
```

Expected: `FAIL` lines, `exit=1`.

- [x] **Step 2: Metadata and defaults**

`ansible/roles/orangutan/meta/main.yaml`:

```yaml
---
galaxy_info:
  author: homelab
  description: LAN Orangutan device discovery
  license: MIT
  min_ansible_version: "2.17"
  platforms:
    - name: Debian
      versions:
        - trixie
dependencies: []
```

`ansible/roles/orangutan/defaults/main.yaml`:

```yaml
---
orangutan_version: "3.3.8"
orangutan_deb: "lan-orangutan_{{ orangutan_version }}_amd64.deb"
orangutan_deb_url: "https://github.com/291-Group/LAN-Orangutan/releases/download/v{{ orangutan_version }}/{{ orangutan_deb }}"
# No checksums file is published; GitHub records one per asset:
#   gh api repos/291-Group/LAN-Orangutan/releases/tags/v<version> \
#     --jq '.assets[] | select(.name=="<deb>") | .digest'
orangutan_deb_sha256: "b727f9f9a33d074e41070737e2ea7750ff040b81a8c708b1d0233c900eb1f24c"

orangutan_port: 291
orangutan_networks: ["10.0.0.0/24"]
orangutan_scan_interval: 300
```

- [x] **Step 3: Templates**

`ansible/roles/orangutan/templates/config.ini.j2`:

```jinja
# Managed by Ansible (roles/orangutan). The password is not here: it is
# read from ORANGUTAN_PASSWORD_FILE, set in the unit.
[server]
port = {{ orangutan_port }}
bind_address = 0.0.0.0
session_hours = 168
allow_insecure = false
enable_api = true

[scanning]
continuous_scan = true
scan_interval = {{ orangutan_scan_interval }}
min_scan_interval = 30
enable_port_scan = false
enable_service_detection = false
networks = {{ orangutan_networks | join(', ') }}
only_configured_networks = true

[storage]
data_dir = /var/lib/orangutan

[tailscale]
enable = false
auto_detect = false

[ui]
theme = auto
```

`ansible/roles/orangutan/templates/lan-orangutan.service.j2` — same name as the package's unit in `/lib/systemd/system`, so this one in `/etc/systemd/system` replaces it:

```jinja
# Managed by Ansible (roles/orangutan). Overrides the package's unit,
# which runs as root.
[Unit]
Description=LAN Orangutan network discovery
After=network-online.target
Wants=network-online.target

[Service]
User=orangutan
Group=orangutan
Environment=ORANGUTAN_PASSWORD_FILE=/etc/orangutan/password
Environment=ORANGUTAN_DATA_DIR=/var/lib/orangutan
# nmap sends raw ARP and reads MAC addresses only when it believes it is
# root; NMAP_PRIVILEGED tells it the capabilities below are enough.
Environment=NMAP_PRIVILEGED=1
ExecStart=/usr/local/bin/orangutan serve --config /etc/orangutan/config.ini
AmbientCapabilities=CAP_NET_RAW CAP_NET_ADMIN CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_RAW CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

- [x] **Step 4: Tasks and handlers**

`ansible/roles/orangutan/tasks/main.yaml`:

```yaml
---
- name: Require LAN Orangutan's password
  ansible.builtin.assert:
    that:
      - orangutan_password is defined
      - orangutan_password | length >= 12
    fail_msg: orangutan_password must be set in ansible/secret.yaml, 12 characters or more.
    quiet: true

- name: Create the orangutan system user
  ansible.builtin.user:
    name: orangutan
    system: true
    shell: /usr/sbin/nologin
    home: /var/lib/orangutan
    create_home: false

- name: Create LAN Orangutan's directories
  ansible.builtin.file:
    path: "{{ item.path }}"
    state: directory
    owner: "{{ item.owner }}"
    group: orangutan
    mode: "{{ item.mode }}"
  loop:
    - { path: /etc/orangutan, owner: root, mode: "0750" }
    - { path: /var/lib/orangutan, owner: orangutan, mode: "0700" }
    - { path: /opt/orangutan, owner: root, mode: "0755" }

- name: Install ca-certificates
  ansible.builtin.apt:
    name: ca-certificates
    state: present
    update_cache: true
    cache_valid_time: 3600

- name: Download the package, checked against its SHA-256
  ansible.builtin.get_url:
    url: "{{ orangutan_deb_url }}"
    dest: "/opt/orangutan/{{ orangutan_deb }}"
    checksum: "sha256:{{ orangutan_deb_sha256 }}"
    mode: "0644"

# The unit goes in first: the package's postinst enables
# lan-orangutan.service, and this file is what that name must mean.
- name: Install the systemd unit
  ansible.builtin.template:
    src: lan-orangutan.service.j2
    dest: /etc/systemd/system/lan-orangutan.service
    mode: "0644"
  notify: Restart lan-orangutan

# Pulls in nmap, the package's only dependency.
- name: Install the package
  ansible.builtin.apt:
    deb: "/opt/orangutan/{{ orangutan_deb }}"
  notify: Restart lan-orangutan

- name: Write the configuration
  ansible.builtin.template:
    src: config.ini.j2
    dest: /etc/orangutan/config.ini
    owner: root
    group: orangutan
    mode: "0640"
  notify: Restart lan-orangutan

- name: Write the dashboard password
  ansible.builtin.copy:
    content: "{{ orangutan_password }}"
    dest: /etc/orangutan/password
    owner: orangutan
    group: orangutan
    mode: "0400"
  no_log: true
  notify: Restart lan-orangutan

- name: Start LAN Orangutan at boot
  ansible.builtin.systemd_service:
    name: lan-orangutan
    state: started
    enabled: true
    daemon_reload: true
```

> **As built:** nmap is installed with ca-certificates in the plain apt
> task, not pulled in by `apt deb:` — with the deb task resolving nmap, apt
> was OOM-killed at 256M in rehearsal (rc 137).

`ansible/roles/orangutan/handlers/main.yaml`:

```yaml
---
- name: Restart lan-orangutan
  ansible.builtin.systemd_service:
    name: lan-orangutan
    state: restarted
    daemon_reload: true
```

- [x] **Step 5: The play and the example secret**

Append to `ansible/playbooks/lan_services.yaml`:

```yaml
- name: LAN Orangutan
  hosts: orangutan
  force_handlers: true
  roles:
    - orangutan
```

Append to `ansible/secret.yaml.example`:

```yaml
# LAN Orangutan's dashboard at https://lan.hl.mgryn.cc, 12+ characters.
# Without it the first visitor would be asked to create one.
orangutan_password: "<24 random chars>"
```

- [x] **Step 6: Rehearse — first run, MACs, idempotence, memory**

```bash
$SCRATCH/run-orangutan.sh | grep -E 'changed=|failed=|FAILED|fatal'
sleep 60; $SCRATCH/check-orangutan.sh; echo "exit=$?"
$SCRATCH/run-orangutan.sh | grep -E 'changed=|failed='
docker stats --no-stream --format '{{.MemUsage}}' lan-orangutan
docker exec lan-orangutan cat /sys/fs/cgroup/memory.peak
docker exec lan-orangutan journalctl -u lan-orangutan --no-pager | tail -5
docker rm -f lan-orangutan lan-peer; docker network rm lan-scan
```

Expected: first run `failed=0`; checks all `ok`, `exit=0` — **the MAC check is the one that matters**: if the peer is listed without its MAC, the capabilities are not reaching nmap; fix the unit, do not accept an IP-only list. Second run `changed=0`. Record `memory.peak` in the report — the apt install of nmap may be tight at 256M. If `orangutan list` does not read the service's data (different CLI, or it needs the API), find the right way from `orangutan list --help` and the dashboard's API, change `check-orangutan.sh`, and say so in the report.

- [x] **Step 7: Lint and commit**

```bash
cd /home/ubuntu/homelab/ansible && ansible-lint roles/orangutan playbooks/lan_services.yaml
cd .. && git add ansible/roles/orangutan ansible/playbooks/lan_services.yaml ansible/secret.yaml.example
git commit -m "feat: add the lan orangutan role" -m "LAN Orangutan from its release package, checked against GitHub's
digest, scanning 10.0.0.0/24 every five minutes as its own user. nmap
gets CAP_NET_RAW and CAP_NET_ADMIN and NMAP_PRIVILEGED instead of root,
and the dashboard password comes from secret.yaml."
```

### Task 5: Route, Gatus check and documentation for LAN Orangutan

**Files:**

- Modify: `ansible/roles/traefik/defaults/main.yaml`, `ansible/roles/traefik/tasks/main.yaml`
- Modify: `ansible/roles/gatus/defaults/main.yaml` (append an endpoint)
- Modify: `README.md`, `docs/rebuild.md`

**Interfaces:**

- Consumes: LAN Orangutan on `:291` (Task 4); `traefik_routes`, `gatus_endpoints`.
- Produces: `lan.hl.mgryn.cc`.

- [x] **Step 1: Route**

Append to `traefik_routes`:

```yaml
- name: lan
  host: "lan.{{ traefik_domain }}"
  url: "http://{{ host_ips['orangutan'] }}:291"
  insecure: false
```

Add `- host_ips['orangutan'] is defined` to the Traefik assert and its `fail_msg`. Run Task 2 Step 1's render commands. Expected: routers include `lan`.

- [x] **Step 2: Gatus check**

Append to `gatus_endpoints` in `ansible/roles/gatus/defaults/main.yaml`, after `status.hl.mgryn.cc`:

```yaml
- name: lan.hl.mgryn.cc
  group: lan
  url: https://lan.hl.mgryn.cc/
  conditions:
    ["[CONNECTED] == true", "[STATUS] < 400", "[CERTIFICATE_EXPIRATION] > 336h"]
```

- [x] **Step 3: README and rebuild.md**

- README LXCs row: add "`orangutan` (device discovery) at `.144`" before "; the rest…", which becomes "; `glance` empty until its role lands"; append `, `ansible/roles/orangutan`` to "where defined".
- Planned sentence: "**Planned, not yet running:** Glance, one LXC in `terraform/environments/shared`, reached as `home.hl.mgryn.cc` — see the …". Keep the link and the Talos sentence.
- The `*.hl` sentence gains `lan.hl.mgryn.cc`.
- Diagram: drop `:::planned` from `orangutan[...]`; `traefik -.-> orangutan` → `traefik --> orangutan`.
- rebuild.md step 15, after the Gatus paragraph:

```markdown
    **LAN Orangutan** needs `orangutan_password` in `secret.yaml`.
    Re-run the Traefik and Gatus plays too, for `lan.hl.mgryn.cc` and its
    check. Check: `https://lan.hl.mgryn.cc` asks for that password and,
    within five minutes, lists the LAN's devices with MAC addresses and
    vendors.
```

- [x] **Step 4: Check and commit**

```bash
node $SCRATCH/mp/p.mjs
cd ansible && ansible-lint roles/traefik roles/gatus && cd ..
pre-commit run --all-files 2>&1 | grep -iv 'passed\|skipped'
git add ansible/roles/traefik ansible/roles/gatus README.md docs/rebuild.md
git commit -m "docs: document lan orangutan" -m "LAN Orangutan goes solid in the README diagram, lan.hl.mgryn.cc gets
its Traefik route and Gatus check, and rebuild.md covers its password."
```

Expected: `PARSE OK`; lint passes; no pre-commit failures.

### Task 6: Operator — LAN Orangutan (owner, not an agent)

- [x] On the `lan-orangutan` checkout: add `orangutan_password` to `secret.yaml`; commit and push.
- [x] `ansible-playbook ... --limit traefik,gatus,orangutan`: `failed=0`; a second run `changed=0`.
- [x] `https://lan.hl.mgryn.cc` asks for the password; after it, within five minutes, the device list shows roughly the twenty devices Task 3's count found, with MACs and vendors.
- [x] `https://status.hl.mgryn.cc` shows `lan.hl.mgryn.cc` green.
- [x] `gh pr ready <N>`; the owner merges.

---

## PR 6 — Glance and the cutover (branch `lan-glance`)

### Task 7: Operator — Glance's prerequisites (owner, before Task 8 runs on real hosts; the agent tasks do not need it)

Listed first so the owner can do it while the code is written.

- [x] On `pve`: `pveum user add glance@pve --comment "Glance dashboard, read-only"`, `pveum acl modify / --users glance@pve --roles PVEAuditor`, `pveum user token add glance@pve glance --privsep 0` — record the token secret it prints once. The token id is `glance@pve!glance`.
- [x] Pi-hole application password, from the Mac:

  ```bash
  SID=$(curl -s -X POST https://pihole.hl.mgryn.cc/api/auth \
    -d '{"password":"<pihole_admin_password>"}' | jq -r .session.sid)
  curl -s -H "X-FTL-SID: $SID" https://pihole.hl.mgryn.cc/api/auth/app | jq .app
  curl -s -X DELETE -H "X-FTL-SID: $SID" https://pihole.hl.mgryn.cc/api/auth
  ```

  Keep both fields of `.app`: `password` → `pihole_app_password`, `hash` → `pihole_app_pwhash`. Nothing is applied yet — the `pihole` role applies the hash (Task 8).

### Task 8: Pi-hole applies the application password

**Files:**

- Modify: `ansible/roles/pihole/tasks/main.yaml` (the "Apply FTL settings" loop)
- Modify: `ansible/roles/pihole/tasks/ftl_setting.yaml` (`no_log` for secret values)
- Modify: `ansible/secret.yaml.example` (append two secrets)

**Interfaces:**

- Consumes: `pihole_app_pwhash`, `pihole_app_password` from `secret.yaml`; `tasks/ftl_setting.yaml`, which takes `pihole_setting: {key, value}`.
- Produces: Pi-hole accepting `pihole_app_password` at `/api/auth` — Glance's `dns-stats` widget (Task 9) logs in with it. Optional: without `pihole_app_pwhash` the role behaves as today.

- [x] **Step 1: A rehearsal hash, and the login failing**

```bash
$SCRATCH/lan-container.sh lan-pihole
$SCRATCH/run-pihole.sh | grep -E 'changed=|failed='
P=$(sed -n 's/^pihole_admin_password: "\(.*\)"/\1/p' $SCRATCH/pihole-secrets.yaml)
docker exec lan-pihole sh -c "curl -s -X POST http://127.0.0.1/api/auth -d '{\"password\":\"$P\"}'" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["session"]["sid"])' > $SCRATCH/sid
docker exec lan-pihole curl -s -H "X-FTL-SID: $(cat $SCRATCH/sid)" http://127.0.0.1/api/auth/app \
  | python3 -c 'import sys,json; a=json.load(sys.stdin)["app"]; print("pihole_app_password: \"%s\"\npihole_app_pwhash: \"%s\"" % (a["password"], a["hash"]))' \
  > $SCRATCH/pihole-app.yaml
cat > $SCRATCH/check-pihole-app.sh <<'EOF'
#!/bin/sh
AP=$(sed -n 's/^pihole_app_password: "\(.*\)"/\1/p' $SCRATCH/pihole-app.yaml)
docker exec lan-pihole sh -c "curl -s -X POST http://127.0.0.1/api/auth -d '{\"password\":\"$AP\"}'" \
  | python3 -c 'import sys,json; v=json.load(sys.stdin)["session"]["valid"]; print("app password valid:", v); sys.exit(0 if v else 1)'
EOF
chmod +x $SCRATCH/check-pihole-app.sh
$SCRATCH/check-pihole-app.sh; echo "exit=$?"
```

Expected: `app password valid: False`, `exit=1` — the hash was generated but never applied.

- [x] **Step 2: Apply it through `ftl_setting`**

In `ansible/roles/pihole/tasks/main.yaml`, change the "Apply FTL settings" task's `loop:` to append the application password when it is defined:

```yaml
- name: Apply FTL settings
  ansible.builtin.include_tasks: ftl_setting.yaml
  loop: >-
    {{
      [
        {'key': 'dns.upstreams', 'value': pihole_upstreams | to_json},
        {'key': 'dns.listeningMode', 'value': pihole_listening_mode},
        {'key': 'dns.revServers', 'value': [pihole_rev_server] | to_json}
      ]
      + ([{'key': 'webserver.api.app_pwhash', 'value': pihole_app_pwhash, 'secret': true}]
         if pihole_app_pwhash is defined else [])
    }}
  loop_control:
    loop_var: pihole_setting
    label: "{{ pihole_setting.key }}"
```

Keep every other key of that task as it is today (read it first; if it carries `notify` or other keys, keep them).

In `ansible/roles/pihole/tasks/ftl_setting.yaml`, add to each of its three tasks:

```yaml
no_log: "{{ pihole_setting.secret | default(false) }}"
```

Append to `ansible/secret.yaml.example`:

```yaml
# Pi-hole application password for Glance's DNS widget, created once
# through Pi-hole's API (docs/rebuild.md step 15): the password for
# Glance, its hash for Pi-hole. Keeping the hash here lets a rebuilt
# Pi-hole accept the same password.
pihole_app_password: "<44 chars from /api/auth/app .app.password>"
pihole_app_pwhash: "$BALLOON-SHA256$v=1$s=1024,t=32$<salt>$<hash>"
```

- [x] **Step 3: Rehearse — applied, idempotent, survives a rebuilt container**

```bash
$SCRATCH/run-pihole.sh -e @$SCRATCH/pihole-app.yaml | grep -E 'changed=|failed=|app_pwhash'
$SCRATCH/check-pihole-app.sh; echo "exit=$?"
$SCRATCH/run-pihole.sh -e @$SCRATCH/pihole-app.yaml | grep -E 'changed=|failed='
$SCRATCH/run-pihole.sh -e @$SCRATCH/pihole-app.yaml -v | grep -c 'BALLOON' || true
# Rebuilt Pi-hole: a fresh container, the same secret.yaml values.
$SCRATCH/lan-container.sh lan-pihole
$SCRATCH/run-pihole.sh -e @$SCRATCH/pihole-app.yaml | grep -E 'changed=|failed='
$SCRATCH/check-pihole-app.sh; echo "exit=$?"
$SCRATCH/check-pihole.sh; echo "exit=$?"
```

Expected: first run `failed=0`; `valid: True`, `exit=0`; second run `changed=0`; the `-v` run prints `0` (the hash never appears in output); the fresh container `failed=0`, `valid: True`, and the existing Pi-hole checks still `exit=0`. Leave `lan-pihole` running for Task 9.

- [x] **Step 4: Lint and commit**

```bash
cd /home/ubuntu/homelab/ansible && ansible-lint roles/pihole
cd .. && git add ansible/roles/pihole ansible/secret.yaml.example
git commit -m "feat: apply the pihole application password" -m "The pihole role sets webserver.api.app_pwhash from secret.yaml when it
is there, so Glance's password keeps working on a rebuilt Pi-hole.
Pi-hole cannot hash a password it did not generate, so the password
and its hash are created once through its API and both kept."
```

### Task 9: The glance role

**Files:**

- Create: `ansible/roles/glance/meta/main.yaml`
- Create: `ansible/roles/glance/defaults/main.yaml`
- Create: `ansible/roles/glance/tasks/main.yaml`
- Create: `ansible/roles/glance/handlers/main.yaml`
- Create: `ansible/roles/glance/templates/glance.yml.j2`
- Create: `ansible/roles/glance/templates/glance.env.j2`
- Create: `ansible/roles/glance/templates/glance.service.j2`
- Modify: `ansible/playbooks/lan_services.yaml` (append a play, last)
- Modify: `ansible/secret.yaml.example` (append two secrets)

**Interfaces:**

- Consumes: group `glance` (PR 1); `host_ips['pve']`, `host_ips['pihole']`, `host_ips['gatus']`; `pihole_app_password` (Task 8); `glance_proxmox_token_id`, `glance_proxmox_token_secret` (Task 7); Gatus's `/api/v1/endpoints/statuses` (PR 4); the homelab CA.
- Produces: Glance on `http://<glance>:8080`.

- [x] **Step 1: Backends, a Proxmox stub, and the checks failing**

```bash
# Gatus, for its statuses API: re-use Task 1's rehearsal (it only needs to answer).
$SCRATCH/lan-container-256.sh lan-gatus
docker exec lan-gatus sh -c 'apt-get install -y -qq python3 curl >/dev/null'
docker exec -d lan-gatus sh -c 'mkdir -p /srv/backend && cd /srv/backend && echo ok > index.html && python3 -m http.server 9001 --bind 127.0.0.1'
$SCRATCH/run-gatus.sh | grep -E 'changed=|failed='
$SCRATCH/lan-container-256.sh lan-glance
docker exec lan-glance sh -c 'apt-get install -y -qq python3 curl procps >/dev/null'
# A Proxmox stub answering /api2/json/cluster/resources, and recording the
# Authorization header it receives.
docker exec -i lan-glance sh -c 'cat > /usr/local/bin/pve-stub.py' <<'EOF'
import http.server, json
DATA = {"data": [
  {"vmid": 101, "name": "rehearsal-vm", "type": "qemu", "status": "running", "mem": 1073741824, "maxmem": 4294967296},
  {"vmid": 140, "name": "rehearsal-ct", "type": "lxc", "status": "stopped", "mem": 0, "maxmem": 268435456},
  {"id": "storage/pve/local", "type": "storage", "status": "available"}]}
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with open("/tmp/pve-auth.log", "a") as f: f.write(self.headers.get("Authorization", "") + "\n")
        ok = self.headers.get("Authorization", "").startswith("PVEAPIToken=glance@pve!glance=")
        self.send_response(200 if ok else 401); self.send_header("Content-Type", "application/json"); self.end_headers()
        self.wfile.write(json.dumps(DATA if ok else {"data": None}).encode())
http.server.HTTPServer(("127.0.0.1", 18006), H).serve_forever()
EOF
docker exec -d lan-glance python3 /usr/local/bin/pve-stub.py
PIHOLE_IP=$(docker inspect lan-pihole -f '{{.NetworkSettings.IPAddress}}')
GATUS_IP=$(docker inspect lan-gatus -f '{{.NetworkSettings.IPAddress}}')
cat > $SCRATCH/rehearse-glance.ini <<'EOF'
[glance]
glance ansible_connection=community.docker.docker ansible_host=lan-glance
[lan_services:children]
glance
[lan_services:vars]
ansible_become=false
ansible_user=root
EOF
{ cat $SCRATCH/pihole-app.yaml; cat <<EOF
host_ips: {pve: 192.0.2.10, pihole: $PIHOLE_IP, gatus: $GATUS_IP}
glance_proxmox_url: "http://127.0.0.1:18006"
glance_proxmox_token_id: "glance@pve!glance"
glance_proxmox_token_secret: "00000000-rehearsal"
glance_ca_cert_src: "$SCRATCH/rehearsal-ca.crt"
# Matching the Gatus rehearsal's own basic-auth values (Task 1).
gatus_basic_user: "rehearsal"
gatus_basic_password: "rehearsal-pass-123"
EOF
} > $SCRATCH/glance-vars.yaml
cat > $SCRATCH/run-glance.sh <<'EOF'
#!/bin/sh
cd /home/ubuntu/homelab/ansible
ANSIBLE_COLLECTIONS_PATH=$SCRATCH/collections:$HOME/.ansible/collections \
  $B/ansible-playbook -i $SCRATCH/rehearse-glance.ini playbooks/lan_services.yaml \
  -e @$SCRATCH/glance-vars.yaml --limit glance "$@" 2>&1 | cat
EOF
chmod +x $SCRATCH/run-glance.sh
cat > $SCRATCH/check-glance.sh <<'EOF'
#!/bin/sh
# Glance renders a page's widgets at /api/pages/<slug>/content/.
C=lan-glance; fail=0
ok() { echo "ok $1"; }; bad() { echo "FAIL $1"; fail=1; }
[ "$(docker exec $C curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/)" = "200" ] && ok "page 200" || bad "page"
h=$(docker exec $C curl -s http://127.0.0.1:8080/api/pages/home/content/)
echo "$h" | grep -q 'rehearsal-vm' && ok "proxmox widget lists VMs" || bad "proxmox widget"
echo "$h" | grep -q 'storage/pve/local' && bad "proxmox widget shows storage" || ok "proxmox widget skips storage"
echo "$h" | grep -q 'backend' && ok "gatus widget lists endpoints" || bad "gatus widget"
echo "$h" | grep -qi 'queries' && ok "dns-stats widget renders" || bad "dns-stats widget"
docker exec $C stat -c '%a %U' /etc/glance/glance.env | grep -q '^600 root$' && ok "env 0600 root" || bad "env mode"
docker exec $C sh -c 'stat -c %U /proc/$(systemctl show -p MainPID --value glance)' | grep -q '^glance$' && ok "runs as glance" || bad user
docker exec $C systemctl is-enabled glance >/dev/null && ok enabled || bad enabled
exit $fail
EOF
chmod +x $SCRATCH/check-glance.sh
$SCRATCH/check-glance.sh; echo "exit=$?"
```

Expected: `FAIL` lines, `exit=1`. (If `/api/pages/home/content/` is not where v0.8.6 renders widgets, find the path from the page's HTML — it fetches its content after load — fix the check, and say so in the report.)

- [x] **Step 2: Metadata and defaults**

`ansible/roles/glance/meta/main.yaml`:

```yaml
---
galaxy_info:
  author: homelab
  description: Glance dashboard for the homelab
  license: MIT
  min_ansible_version: "2.17"
  platforms:
    - name: Debian
      versions:
        - trixie
dependencies: []
```

`ansible/roles/glance/defaults/main.yaml`:

```yaml
---
glance_version: "0.8.6"
glance_archive_url: "https://github.com/glanceapp/glance/releases/download/v{{ glance_version }}/glance-linux-amd64.tar.gz"
# No checksums file is published; GitHub records one per asset:
#   gh api repos/glanceapp/glance/releases/tags/v<version> \
#     --jq '.assets[] | select(.name=="glance-linux-amd64.tar.gz") | .digest'
glance_archive_sha256: "d27fb887eece24859f6ed3881ebb28c9d0a4fe6ae01acfa31bb39543fbf69784"

glance_port: 8080
glance_ca_cert_src: "~/.homelab-ca/ca.crt"

glance_proxmox_url: "https://{{ host_ips['pve'] }}:8006"
glance_pihole_url: "http://{{ host_ips['pihole'] }}"
glance_gatus_url: "http://{{ host_ips['gatus'] }}:8080"

# The monitor widget. alt_status_codes: codes that still count as up.
glance_sites:
  - { title: Pi-hole, url: "https://pihole.hl.mgryn.cc/admin/" }
  - { title: Proxmox, url: "https://proxmox.hl.mgryn.cc/" }
  - {
      title: Traefik,
      url: "https://traefik.hl.mgryn.cc/dashboard/",
      alt_status_codes: [401],
    }
  - { title: Gatus, url: "https://status.hl.mgryn.cc/" }
  - { title: LAN Orangutan, url: "https://lan.hl.mgryn.cc/" }
  - { title: Glance, url: "https://home.hl.mgryn.cc/" }
  - { title: jobboard, url: "https://jobs.mgryn.cc/" }
  - { title: Vault, url: "https://vault.mgryn.cc:8200/ui/" }

glance_bookmarks:
  - { title: Vault UI, url: "https://vault.mgryn.cc:8200/ui/" }
  - { title: ArgoCD, url: "https://argocd.mgryn.cc/" }
  - { title: Grafana, url: "https://grafana.mgryn.cc/" }
  - { title: jobboard, url: "https://jobs.mgryn.cc/" }
  - { title: GitHub, url: "https://github.com/maxim-grin/homelab" }
```

- [x] **Step 3: Templates**

`ansible/roles/glance/templates/glance.yml.j2` — the widget templates are Go templates, so they sit inside `{% raw %}`:

```jinja
# Managed by Ansible (roles/glance). Glance reloads this file on change.
# ${...} values come from /etc/glance/glance.env.
server:
  host: 0.0.0.0
  port: {{ glance_port }}

pages:
  - name: Home
    slug: home
    columns:
      - size: small
        widgets:
          - type: dns-stats
            service: pihole-v6
            url: {{ glance_pihole_url }}
            password: ${GLANCE_PIHOLE_PASSWORD}
          - type: bookmarks
            groups:
              - title: Homelab
                links:
{% for b in glance_bookmarks %}
                  - title: {{ b.title }}
                    url: {{ b.url }}
{% endfor %}
      - size: full
        widgets:
          - type: monitor
            title: Services
            cache: 1m
            sites:
{% for s in glance_sites %}
              - title: {{ s.title }}
                url: {{ s.url }}
{% if s.alt_status_codes is defined %}
                alt-status-codes: {{ s.alt_status_codes | to_json }}
{% endif %}
{% endfor %}
          - type: custom-api
            title: Proxmox
            cache: 1m
            url: {{ glance_proxmox_url }}/api2/json/cluster/resources
            # Proxmox's certificate is self-signed.
            allow-insecure: true
            headers:
              Authorization: PVEAPIToken=${GLANCE_PROXMOX_TOKEN}
            template: |
{% raw %}
              <ul class="list list-gap-8">
              {{ range sortByInt "vmid" "asc" (.JSON.Array "data") }}
                {{ if or (eq (.String "type") "qemu") (eq (.String "type") "lxc") }}
                <li class="flex justify-between">
                  <span class="color-highlight">{{ .Int "vmid" }} {{ .String "name" }}</span>
                  <span class="{{ if eq (.String "status") "running" }}color-positive{{ else }}color-negative{{ end }}">
                    {{ .String "status" }} · {{ div (.Int "mem" | toFloat) 1048576 | toInt }}/{{ div (.Int "maxmem" | toFloat) 1048576 | toInt }} MiB
                  </span>
                </li>
                {{ end }}
              {{ end }}
              </ul>
{% endraw %}
          - type: custom-api
            title: Gatus
            cache: 1m
            # pageSize=1: each endpoint's results carry only its latest check.
            url: {{ glance_gatus_url }}/api/v1/endpoints/statuses?page=1&pageSize=1
            basic-auth:
              username: ${GLANCE_GATUS_USER}
              password: ${GLANCE_GATUS_PASSWORD}
            template: |
{% raw %}
              <ul class="list list-gap-8">
              {{ range .JSON.Array "" }}
                <li class="flex justify-between">
                  <span>{{ .String "group" }} · {{ .String "name" }}</span>
                  {{ if .Bool "results.0.success" }}<span class="color-positive">up</span>{{ else }}<span class="color-negative">down</span>{{ end }}
                </li>
              {{ end }}
              </ul>
{% endraw %}
```

`ansible/roles/glance/templates/glance.env.j2`:

```jinja
# Managed by Ansible. Read by systemd as root; mode 0600.
GLANCE_PIHOLE_PASSWORD={{ pihole_app_password }}
GLANCE_PROXMOX_TOKEN={{ glance_proxmox_token_id }}={{ glance_proxmox_token_secret }}
GLANCE_GATUS_USER={{ gatus_basic_user }}
GLANCE_GATUS_PASSWORD={{ gatus_basic_password }}
```

`ansible/roles/glance/templates/glance.service.j2`:

```jinja
# Managed by Ansible (roles/glance).
[Unit]
Description=Glance dashboard
After=network-online.target
Wants=network-online.target

[Service]
User=glance
Group=glance
EnvironmentFile=/etc/glance/glance.env
WorkingDirectory=/var/lib/glance
ExecStart=/usr/local/bin/glance -config /etc/glance/glance.yml
NoNewPrivileges=true
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

- [x] **Step 4: Tasks and handlers**

`ansible/roles/glance/tasks/main.yaml`:

```yaml
---
- name: Require Glance's secrets and addresses
  ansible.builtin.assert:
    that:
      - pihole_app_password is defined
      - pihole_app_password | length > 0
      - glance_proxmox_token_id is defined
      - "'!' in glance_proxmox_token_id"
      - glance_proxmox_token_secret is defined
      - glance_proxmox_token_secret | length > 0
      - gatus_basic_user is defined
      - gatus_basic_user | length > 0
      - gatus_basic_password is defined
      - gatus_basic_password | length > 0
      - host_ips['pve'] is defined
      - host_ips['pihole'] is defined
      - host_ips['gatus'] is defined
    fail_msg: >-
      pihole_app_password, glance_proxmox_token_id (user@realm!name),
      glance_proxmox_token_secret, gatus_basic_user, gatus_basic_password
      and host_ips for pve, pihole and gatus must be set in
      ansible/secret.yaml.
    quiet: true

- name: Create the glance system user
  ansible.builtin.user:
    name: glance
    system: true
    shell: /usr/sbin/nologin
    home: /var/lib/glance
    create_home: false

- name: Create Glance's directories
  ansible.builtin.file:
    path: "{{ item.path }}"
    state: directory
    owner: "{{ item.owner }}"
    group: glance
    mode: "{{ item.mode }}"
  loop:
    - { path: /etc/glance, owner: root, mode: "0750" }
    - { path: /var/lib/glance, owner: glance, mode: "0700" }
    - { path: "/opt/glance/{{ glance_version }}", owner: root, mode: "0755" }

- name: Install ca-certificates
  ansible.builtin.apt:
    name: ca-certificates
    state: present
    update_cache: true
    cache_valid_time: 3600

# The monitor widget checks the Vault UI, signed by the homelab's CA.
- name: Trust the homelab CA
  ansible.builtin.copy:
    content: "{{ lookup('ansible.builtin.file', glance_ca_cert_src) }}\n"
    dest: /usr/local/share/ca-certificates/homelab-ca.crt
    owner: root
    group: root
    mode: "0644"
  notify:
    - Update the CA trust store
    - Restart glance

- name: Download Glance, checked against its SHA-256
  ansible.builtin.get_url:
    url: "{{ glance_archive_url }}"
    dest: "/opt/glance/glance-{{ glance_version }}-linux-amd64.tar.gz"
    checksum: "sha256:{{ glance_archive_sha256 }}"
    mode: "0644"

- name: Unpack Glance
  ansible.builtin.unarchive:
    src: "/opt/glance/glance-{{ glance_version }}-linux-amd64.tar.gz"
    dest: "/opt/glance/{{ glance_version }}"
    remote_src: true
    include: [glance]
    creates: "/opt/glance/{{ glance_version }}/glance"

- name: Point /usr/local/bin/glance at this version
  ansible.builtin.file:
    src: "/opt/glance/{{ glance_version }}/glance"
    dest: /usr/local/bin/glance
    state: link
  notify: Restart glance

# No restart: Glance reloads its config file on change.
- name: Write the configuration
  ansible.builtin.template:
    src: glance.yml.j2
    dest: /etc/glance/glance.yml
    owner: root
    group: glance
    mode: "0640"

- name: Write the secrets
  ansible.builtin.template:
    src: glance.env.j2
    dest: /etc/glance/glance.env
    owner: root
    group: root
    mode: "0600"
  no_log: true
  notify: Restart glance

- name: Install the systemd unit
  ansible.builtin.template:
    src: glance.service.j2
    dest: /etc/systemd/system/glance.service
    mode: "0644"
  notify: Restart glance

- name: Start Glance at boot
  ansible.builtin.systemd_service:
    name: glance
    state: started
    enabled: true
    daemon_reload: true
```

`ansible/roles/glance/handlers/main.yaml`:

```yaml
---
- name: Update the CA trust store
  ansible.builtin.command: update-ca-certificates
  changed_when: true

- name: Restart glance
  ansible.builtin.systemd_service:
    name: glance
    state: restarted
    daemon_reload: true
```

- [x] **Step 5: The play and the example secrets**

Append to `ansible/playbooks/lan_services.yaml`:

```yaml
- name: Glance
  hosts: glance
  force_handlers: true
  roles:
    - glance
```

Append to `ansible/secret.yaml.example`:

```yaml
# Glance's Proxmox widget: a read-only token, user glance@pve with
# PVEAuditor on /, no privilege separation (docs/rebuild.md step 15).
glance_proxmox_token_id: "glance@pve!glance"
glance_proxmox_token_secret: "<uuid printed once by pveum user token add>"
```

- [x] **Step 6: Rehearse — first run, widgets, idempotence**

```bash
$SCRATCH/run-glance.sh | grep -E 'changed=|failed=|FAILED|fatal'
sleep 5; $SCRATCH/check-glance.sh; echo "exit=$?"
$SCRATCH/run-glance.sh | grep -E 'changed=|failed='
docker exec lan-glance tail -1 /tmp/pve-auth.log | cut -c1-32
docker stats --no-stream --format '{{.MemUsage}}' lan-glance
```

Expected: first run `failed=0`; checks all `ok`, `exit=0` — the dns-stats line proves the application password logs in to a real Pi-hole v6; second run `changed=0`; the stub saw `PVEAPIToken=glance@pve!glance=` (the header reached Proxmox's shape); memory well under 256MiB.

- [x] **Step 7: Rehearse — one backend down leaves the page up**

```bash
docker stop lan-gatus >/dev/null
docker exec lan-glance pkill -f pve-stub.py
sleep 70
docker exec lan-glance curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/
docker exec lan-glance curl -s http://127.0.0.1:8080/api/pages/home/content/ | grep -ci 'queries'
docker exec lan-glance systemctl is-active glance
docker rm -f lan-glance lan-gatus lan-pihole
```

Expected: `200`; a non-zero count (dns-stats still renders); `active`. The Gatus and Proxmox widgets show their own error, not a blank page.

- [x] **Step 8: Lint and commit**

```bash
cd /home/ubuntu/homelab/ansible && ansible-lint roles/glance playbooks/lan_services.yaml
cd .. && git add ansible/roles/glance ansible/playbooks/lan_services.yaml ansible/secret.yaml.example
git commit -m "feat: add the glance role" -m "Glance from its release archive, checked against GitHub's digest, as
its own user: Pi-hole's statistics through its application password,
every VM and container from Proxmox through a read-only token, Gatus's
latest results, a monitor of every service, and bookmarks."
```

### Task 10: Route, Gatus check, cutover and documentation for Glance

**Files:**

- Modify: `ansible/roles/traefik/defaults/main.yaml`, `ansible/roles/traefik/tasks/main.yaml`
- Modify: `ansible/roles/gatus/defaults/main.yaml`
- Modify: `README.md`, `docs/rebuild.md`, `CLAUDE.md`

**Interfaces:**

- Consumes: Glance on `:8080` (Task 9).
- Produces: `home.hl.mgryn.cc`; the documented cutover.

- [x] **Step 1: Route and check**

Append to `traefik_routes`:

```yaml
- name: home
  host: "home.{{ traefik_domain }}"
  url: "http://{{ host_ips['glance'] }}:8080"
  insecure: false
```

Add `- host_ips['glance'] is defined` to the Traefik assert and its `fail_msg`. Run Task 2 Step 1's render commands; expected routers include `home`.

Append to `gatus_endpoints`, after `lan.hl.mgryn.cc`:

```yaml
- name: home.hl.mgryn.cc
  group: lan
  url: https://home.hl.mgryn.cc/
  conditions:
    ["[CONNECTED] == true", "[STATUS] < 400", "[CERTIFICATE_EXPIRATION] > 336h"]
```

- [x] **Step 2: README**

- LXCs row: every service now runs — description "`pihole` (DNS, ad blocking) `.140`, `traefik` (`*.hl.mgryn.cc`) `.141`, `glance` (dashboard) `.142`, `gatus` (uptime, Telegram alerts) `.143`, `orangutan` (device discovery) `.144`"; append `, `ansible/roles/glance`` to "where defined".
- Replace the "**Planned, not yet running:** Glance, …" sentence with "**Planned, not yet running:** a Talos prod cluster that runs ArgoCD and monitoring for both clusters — see the [roadmap](docs/superpowers/specs/2026-09-26-homelab-roadmap-design.md)." (Drop the now-duplicate Talos sentence after it.)
- The `*.hl` sentence gains `home.hl.mgryn.cc`.
- Replace the sentence beginning "Most hostnames resolve through `/etc/hosts` on the workstation" with: "Every LAN device resolves through Pi-hole (`10.0.0.140`), which the router's DHCP hands out. The cluster names `argocd.`, `grafana.` and `prometheus.mgryn.cc` still resolve through `/etc/hosts` on the workstation, pointing at a node IP since ingress-nginx answers on every node."
- Diagram: drop `:::planned` from `glance[...]`; `traefik -.-> glance` → `traefik --> glance`; `lan -. "DNS" .-> pihole` → `lan -- "DNS" --> pihole`.

- [x] **Step 3: rebuild.md**

Append to step 15, after the LAN Orangutan paragraph:

```markdown
    **Glance** needs, before its play:

    - a read-only Proxmox token: on the host, `pveum user add glance@pve`,
      `pveum acl modify / --users glance@pve --roles PVEAuditor`,
      `pveum user token add glance@pve glance --privsep 0`; the id
      `glance@pve!glance` and the secret it prints once go into
      `secret.yaml` as `glance_proxmox_token_id` and
      `glance_proxmox_token_secret`;
    - Pi-hole's application password, kept from before the rebuild — both
      `pihole_app_password` and `pihole_app_pwhash` are in `secret.yaml`,
      and the Pi-hole play applies the hash. Only if they were lost:
      log in to Pi-hole's API with the admin password, `GET /api/auth/app`,
      keep `.app.password` and `.app.hash`, and re-run the Pi-hole play.

    Re-run the Pi-hole, Traefik and Gatus plays too. Check:
    `https://home.hl.mgryn.cc` shows every VM and container, Pi-hole's
    statistics and Gatus's endpoints.

    **Cutover** — last, once Gatus is watching Pi-hole: note the router's
    current DHCP DNS setting, then set it to `10.0.0.140` alone. Rollback
    is the noted setting.
```

In "## Rebuild order", step 2 (Prepare the host) gains: "and the `glance@pve` read-only token (step 15)".

- [x] **Step 4: CLAUDE.md**

In the "**ingress-nginx is a DaemonSet on host ports 80/443**" bullet, replace "There is no DNS server here, so most hostnames resolve via `/etc/hosts` on the workstation." with "LAN clients resolve through Pi-hole; the cluster's own names (`argocd.`, `grafana.`, `prometheus.mgryn.cc`) still resolve via `/etc/hosts` on the workstation."

Add a new bullet after that one:

```markdown
- **Pi-hole is the LAN's only DNS server.** The router's DHCP hands out
  `10.0.0.140` and nothing else, so a stopped Pi-hole takes name
  resolution away from every device on the LAN — phones, TV, laptop.
  Gatus alerts on it within about two minutes, resolving through
  `1.1.1.1` and the router, as every LAN service container does, never
  Pi-hole. Restart it, or, to roll back, set the router's DHCP DNS to
  the setting recorded in the Glance PR's body.
```

- [x] **Step 5: Check and commit**

```bash
node $SCRATCH/mp/p.mjs
cd ansible && ansible-lint roles/traefik roles/gatus && cd ..
pre-commit run --all-files 2>&1 | grep -iv 'passed\|skipped'
git add ansible/roles/traefik ansible/roles/gatus README.md docs/rebuild.md CLAUDE.md
git commit -m "docs: document glance and the dns cutover" -m "Glance goes solid in the README diagram with the LAN's DNS edge, gets
home.hl.mgryn.cc and its Gatus check, rebuild.md covers the Proxmox
token, Pi-hole's application password and the cutover, and CLAUDE.md
says Pi-hole is now the LAN's only DNS server."
```

Expected: `PARSE OK`; lint passes; no pre-commit failures.

### Task 11: Operator — Glance and the cutover (owner, not an agent)

- [x] Task 7 done: `glance_proxmox_token_id`, `glance_proxmox_token_secret`, `pihole_app_password`, `pihole_app_pwhash` in `secret.yaml` on the `lan-glance` checkout; commit and push.
- [x] `ansible-playbook ... --limit pihole,glance`, then `--limit traefik,gatus` (Glance first, so Gatus never checks a missing backend): `failed=0` each; a second run of both `changed=0`.
- [ ] `https://home.hl.mgryn.cc`: every VM and LXC with status and memory, Pi-hole's query and block counts, Gatus's endpoints, the monitor all green except anything genuinely down, bookmarks.
- [ ] `https://status.hl.mgryn.cc` shows `home.hl.mgryn.cc` green.
- [ ] **Cutover.** Record the router's current DHCP DNS setting in `docs/operations.md` ("DNS cutover rollback"), commit and push it to this branch. Set it to `10.0.0.140` only. Renew a phone's lease (toggle Wi-Fi): it appears by name in Pi-hole's query log, and an ad-heavy site shows blocked queries.
- [ ] `pct stop 140`: Telegram alert within about two minutes (two check intervals); `pct start 140`: recovery. The LAN is without DNS in between — do this when nobody minds.
- [ ] `gh pr ready <N>`; the owner merges. Sub-project 1's "Done means" list in the spec is then met, except the sealed-Vault alert, which is proven by its condition (`[STATUS] == 200` against a 503) rather than by sealing Vault.
