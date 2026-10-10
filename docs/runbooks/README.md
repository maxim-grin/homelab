# Runbooks

Copy-paste commands for running and checking the homelab. A runbook owns
"how do I run or check X now"; [rebuild.md](../rebuild.md) owns "in what order
for a rebuild" and links in
([ADR 0025](../decisions/0025-runbooks-own-operator-commands.md)). Why a
thing is built a certain way is in [decisions/](../decisions/).

## Index

| I want to...                                   | Runbook                                                                | Entry                                                                                          |
| ---------------------------------------------- | ---------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| plan or apply Terraform for an environment     | [playbooks-and-terraform](playbooks-and-terraform.md)                  | [Plan and apply an environment](playbooks-and-terraform.md#plan-and-apply-an-environment)     |
| repair state after a failed apply              | [playbooks-and-terraform](playbooks-and-terraform.md)                  | [Repair state after a failed apply](playbooks-and-terraform.md#repair-state-after-a-failed-apply) |
| grow a node's disk                             | [playbooks-and-terraform](playbooks-and-terraform.md)                  | [Resize a node](playbooks-and-terraform.md#resize-a-node)                                      |
| build the kubeadm cluster                      | [playbooks-and-terraform](playbooks-and-terraform.md)                  | [Build the kubeadm cluster](playbooks-and-terraform.md#build-the-kubeadm-cluster)              |
| redo control-plane init or join workers        | [playbooks-and-terraform](playbooks-and-terraform.md)                  | [Re-run control-plane init and the worker join](playbooks-and-terraform.md#re-run-control-plane-init-and-the-worker-join) |
| apply out-of-band cluster Secrets              | [playbooks-and-terraform](playbooks-and-terraform.md)                  | [Apply out-of-band cluster Secrets](playbooks-and-terraform.md#apply-out-of-band-cluster-secrets) |
| register dev with the prod hub                 | [playbooks-and-terraform](playbooks-and-terraform.md)                  | [Register dev with the prod hub](playbooks-and-terraform.md#register-dev-with-the-prod-hub)    |
| install ArgoCD on prod                         | [playbooks-and-terraform](playbooks-and-terraform.md)                  | [Deploy ArgoCD to prod](playbooks-and-terraform.md#deploy-argocd-to-prod)                      |
| pin `vault.mgryn.cc` in CoreDNS                | [playbooks-and-terraform](playbooks-and-terraform.md)                  | [Pin names in CoreDNS](playbooks-and-terraform.md#pin-names-in-coredns)                        |
| provision NFS                                  | [playbooks-and-terraform](playbooks-and-terraform.md)                  | [Provision NFS](playbooks-and-terraform.md#provision-nfs)                                      |
| install support tools or the workstation toolchain | [playbooks-and-terraform](playbooks-and-terraform.md)              | [Install support tools and the workstation](playbooks-and-terraform.md#install-support-tools-and-the-workstation) |
| install Vault, seed it, configure dev or prod  | [playbooks-and-terraform](playbooks-and-terraform.md)                  | [Vault playbook](playbooks-and-terraform.md#vault-playbook)                                    |
| seed the Prometheus remote-write credential    | [playbooks-and-terraform](playbooks-and-terraform.md)                  | [Seed the remote-write credential](playbooks-and-terraform.md#seed-the-remote-write-credential) |
| run `lan_services` for Gatus only              | [playbooks-and-terraform](playbooks-and-terraform.md)                  | [Apply one LAN service](playbooks-and-terraform.md#apply-one-lan-service)                      |
| apply every LAN service                        | [playbooks-and-terraform](playbooks-and-terraform.md)                  | [Apply all LAN services](playbooks-and-terraform.md#apply-all-lan-services)                    |
| lint or render before a commit                 | [playbooks-and-terraform](playbooks-and-terraform.md)                  | [Static checks](playbooks-and-terraform.md#static-checks)                                      |
| know whether Vault is sealed                   | [checks](checks.md)                                                    | [Is Vault up and unsealed](checks.md#is-vault-up-and-unsealed)                                 |
| check KV is seeded, snapshot age, audit disk   | [checks](checks.md)                                                    | [Vault](checks.md#vault)                                                                       |
| see whether `kube-prometheus-stack` is synced in prod    | [checks](checks.md)                                                    | [List Applications with sync and health](checks.md#list-applications-with-sync-and-health) (filtered with `grep kube-prometheus-stack`) |
| find why an Application is `Unknown`           | [checks](checks.md)                                                    | [Spot ComparisonError (the sealed-Vault tell)](checks.md#spot-comparisonerror-the-sealed-vault-tell) |
| refresh or sync an Application by hand         | [checks](checks.md)                                                    | [Refresh an Application](checks.md#refresh-an-application), [Sync an Application by hand](checks.md#sync-an-application-by-hand) |
| check the AVP sidecar can render Helm apps     | [checks](checks.md)                                                    | [Check the CMP sidecar](checks.md#check-the-cmp-sidecar)                                       |
| land the uniform-apps PR (before and after merge) | [checks](checks.md)                                                 | [Land the uniform-apps PR](checks.md#land-the-uniform-apps-pr)                                 |
| verify Argo accepts the ApplicationSet         | [checks](checks.md)                                                    | [Verify the ApplicationSet](checks.md#verify-the-applicationset)                               |
| move an app into the ApplicationSet            | [checks](checks.md)                                                    | [Roll an app into the set](checks.md#roll-an-app-into-the-set)                                 |
| remove an app from the ApplicationSet          | [checks](checks.md)                                                    | [Retire an app from the set](checks.md#retire-an-app-from-the-set)                             |
| adopt dev's live apps into the hub           | [checks](checks.md)                                                    | [Adopt dev into the hub](checks.md#adopt-dev-into-the-hub)                                     |
| prove AVP renders a secret                     | [checks](checks.md)                                                    | [Prove AVP end to end](checks.md#prove-avp-end-to-end)                                         |
| check nodes, pods, PVCs, certificates, ingress | [checks](checks.md)                                                    | [Cluster](checks.md#cluster)                                                                   |
| check the NFS exports                          | [checks](checks.md)                                                    | [Exports](checks.md#exports)                                                                   |
| check Gatus and Glance                         | [checks](checks.md)                                                    | [Gatus and Glance](checks.md#gatus-and-glance)                                                 |
| check Prometheus targets, Alertmanager, Telegram (prod) | [checks](checks.md)                                           | [LAN and alerts](checks.md#lan-and-alerts)                                                     |
| check host memory, VMs and the thin pool       | [checks](checks.md)                                                    | [Memory, VMs and thin pool](checks.md#memory-vms-and-thin-pool)                                |
| fetch the dev or prod kubeconfig, or `talosconfig` | [access](access.md)                                                | [Kubeconfigs](access.md#kubeconfigs)                                                           |
| make the dev names resolve                     | [access](access.md)                                                    | [Add the dev names to /etc/hosts](access.md#add-the-dev-names-to-etchosts)                     |
| find a UI's URL and where its login lives      | [access](access.md)                                                    | [UIs](access.md#uis)                                                                           |
| log in to the ArgoCD CLI (expired token, 504)  | [access](access.md)                                                    | [Log in to the ArgoCD CLI](access.md#log-in-to-the-argocd-cli)                                 |
| read a Vault field without leaking it          | [access](access.md)                                                    | [Read a Vault field without leaking it](access.md#read-a-vault-field-without-leaking-it)       |
| SSH to a node or the Proxmox host              | [access](access.md)                                                    | [Reach a node or the Proxmox host](access.md#reach-a-node-or-the-proxmox-host)                 |
| check the Vault snapshot job                   | [backups-and-recovery](backups-and-recovery.md)                        | [Check the snapshot job](backups-and-recovery.md#check-the-snapshot-job)                       |
| restore Vault from a snapshot                  | [backups-and-recovery](backups-and-recovery.md)                        | [Restore a raft snapshot](backups-and-recovery.md#restore-a-raft-snapshot)                     |
| hold dev-jobboard still for a database restore | [backups-and-recovery](backups-and-recovery.md)                        | [Hold dev-jobboard still](backups-and-recovery.md#hold-dev-jobboard-still)                     |
| learn what has no backup                       | [backups-and-recovery](backups-and-recovery.md)                        | [What has no backup](backups-and-recovery.md#what-has-no-backup)                               |
| clean up retained `nfs-prod` volumes           | [backups-and-recovery](backups-and-recovery.md)                        | [Clean up retained nfs-prod volumes](backups-and-recovery.md#clean-up-retained-nfs-prod-volumes) |
| rebuild after a disk loss                      | [backups-and-recovery](backups-and-recovery.md)                        | [Rebuild pointers](backups-and-recovery.md#rebuild-pointers)                                   |

## Conventions

Stated here once; the runbooks do not repeat them.

- Everything runs from the operator's workstation unless a block says it runs
  on a host.
- Playbooks run from `ansible/` with `-e @secret.yaml --ask-vault-pass`. The
  default inventory is `inventories/dev`; `shared` and `prod` runs name theirs
  with `-i`.
- `$DEV_KC` and `$PROD_KC` are the paths of the dev and prod kubeconfigs. Fetch
  them with [Kubeconfigs](access.md#kubeconfigs); both are mode 600 and never
  committed.
- Vault is reached with `VAULT_ADDR` and a token read without echo, so it never
  lands in shell history, and the token is unset afterwards:

  ```bash
  export VAULT_ADDR=https://10.0.0.133:8200
  export VAULT_CACERT=~/.homelab-ca/ca.crt   # not needed on vault-02 itself
  printf 'Vault token: '; read -rs VAULT_TOKEN; echo; export VAULT_TOKEN
  # ... vault commands ...
  unset VAULT_TOKEN
  ```

  The `printf` prompt is deliberate: a bare `read -rs` shows nothing, and
  pasting a whole block into a shell without bracketed paste can make `read`
  swallow the next pasted line.

- A `<placeholder>` is explained on the line above its command.
- Each entry has the same parts: when to run it, one complete block, an
  "Expect:" line, an "If not:" pointer.
- No runbook prints a credential; the one value shown is the Grafana admin
  username.

## Keeping it current

`scripts/check-runbooks.sh` runs in pre-commit and CI. It fails when a
playbook in `ansible/playbooks/` is not named in
[playbooks-and-terraform](playbooks-and-terraform.md), when a command names a
playbook or inventory that does not exist, or when a relative link does not
resolve. A pull request that adds or changes a playbook, a flag or an operator
step updates the runbook in the same pull request.
