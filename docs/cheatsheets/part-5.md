# Part 5 cheat sheet — Automation, nodes, backup, upgrades, troubleshooting

`$` = workstation · `node1$` = on node1 · `<ns>` = namespace · `<node>` = Kubernetes node name

## Automation: where things are

| File | Holds |
|---|---|
| `infra/versions.env` | Every version pin |
| `infra/ansible/inventory/hosts.ini` | The nodes and their role |
| `infra/ansible/inventory/group_vars/all.yml` | RKE2 settings (version, snapshot schedule) |
| `infra/platform/<layer>/` | Helm values and manifests per layer |
| `infra/platform/.secrets/` ⚠️ | Generated passwords, Vault keys (not in git) |

```bash
$ ansible-inventory --graph                                       # groups and nodes
$ ansible cluster -m ping                                         # can Ansible reach them?
$ ansible-playbook infra/ansible/playbooks/site.yml               # build (safe to re-run)
$ ansible-playbook infra/ansible/playbooks/add-node.yml -e new_node=node4
$ ansible-playbook infra/ansible/playbooks/reset.yml -e confirm=yes     # ⚠️ DESTROYS the cluster
$ infra/platform/deploy.sh <layer>                                # or: all   (safe to re-run)
$ infra/platform/deploy.sh app                                    # the demo app (not part of "all")
$ infra/platform/verify.sh                                        # add: --wait 180 after a restart
```

Layers: `network storage observability vault keycloak redis kafka`. Change the **file**, then run the tool.

## Node maintenance

```bash
$ kubectl get pods -A -o wide --field-selector spec.nodeName=<node>     # what runs there
$ kubectl get pdb -A                                                    # ALLOWED DISRUPTIONS 0 = drain will wait
$ kubectl cordon <node>                                                 # no new pods
$ kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --timeout=300s
  ... patch, reboot, replace ...
$ kubectl uncordon <node>                                               # do not forget
$ kubectl get pods -A --field-selector status.phase=Pending             # anything stuck?
$ infra/platform/vault/init-unseal.sh                                   # Vault restarts sealed
$ infra/platform/verify.sh --wait 300
```

- One node at a time; health check between nodes
- ⚠️ local-path: a stateful pod waits `Pending` for its own node. ⚠️ One server: draining node1 stops the API
- Remove a node: `drain` → `kubectl delete node <node>` → on the machine `sudo /usr/local/bin/rke2-uninstall.sh`

## Backup

| What | Command | ⚠️ |
|---|---|---|
| etcd (all Kubernetes objects, incl. Secrets) | `node1$ sudo rke2 etcd-snapshot save --name <name>` | Files stay on node1: copy them off |
| Vault | `v operator raft snapshot save /tmp/x.snap`, then copy it **out of the pod** | Useless without the unseal keys |
| Keycloak database | `kubectl -n keycloak exec postgres-0 -- pg_dump -U keycloak keycloak \| gzip > file.sql.gz` | Contains every account |
| Volumes (Redis, Kafka, metrics, logs) | Not backed up in the lab | Decide per application |

```bash
node1$ sudo rke2 etcd-snapshot ls
node1$ sudo ls -lh /var/lib/rancher/rke2/server/db/snapshots/
$ kubectl get etcdsnapshotfiles
```

**Restore etcd** (single server; throws away every change since the snapshot):

```bash
node1$ sudo systemctl stop rke2-server
node1$ sudo rke2 server --cluster-reset --cluster-reset-restore-path=/var/lib/rancher/rke2/server/db/snapshots/<file>
node1$ sudo systemctl start rke2-server
$ infra/platform/vault/init-unseal.sh
$ infra/platform/verify.sh --wait 600
```

Volumes, Vault and databases are **not** rolled back by an etcd restore.

## Upgrades

- One minor version at a time. Servers first, then agents. Read the release notes; snapshot first
- Per node: drain → install the new version → restart the service → `Ready` → uncordon

```bash
$ kubectl get nodes -o wide                         # VERSION per node
$ helm list -A                                      # chart versions
$ infra/scripts/show-latest-versions.sh             # what is available
node$ curl -sfL https://get.rke2.io | sudo INSTALL_RKE2_VERSION='<version>' sh -
node$ sudo systemctl restart rke2-agent             # rke2-server on node1
$ helm template <release> <chart> --version <new> -f values.yaml > /tmp/new.yaml     # then diff with: helm get manifest
$ infra/scripts/pin-versions.sh --dry-run           # record what a tested cluster runs
```

Way back: chart → `helm rollback` · operator → often none · RKE2 minor version → restore the snapshot.

## Troubleshooting: top-down

| Layer | Look at |
|---|---|
| **Symptom** | Reproduce it with the user's command or address |
| **Nodes** | `kubectl get nodes` · `kubectl top nodes` · `kubectl describe node <node>` |
| **Pods** | `kubectl -n <ns> get pods -o wide` · `describe pod` (Events!) · `logs` · `logs --previous` |
| **Network** | `kubectl -n <ns> get service,endpointslices,ingress,networkpolicies` · `hubble observe --verdict DROPPED` |
| **Application, dependencies** | Its logs (Loki for history) · `infra/platform/verify.sh` |
| **What changed?** | `kubectl -n <ns> get events --sort-by=.lastTimestamp` · `rollout history` · `helm history` · `git log` |

Stop at the first unhealthy layer. Change one thing at a time. Save the evidence before you delete a pod.

| Status | Usually |
|---|---|
| `Pending` | No room, volume not ready, or no node allowed |
| `Init:0/1` | Vault agent cannot log in, or Vault is sealed |
| `ImagePullBackOff` | Wrong image name or tag |
| `CrashLoopBackOff` | Process exits: `logs --previous` |
| `Running` `0/1` | Readiness probe fails |
| All `Running`, service down | Service selector, network policy, ingress, or a dependency |

## Lab 14 and the demo app

```bash
$ labs/files/lab-14/fault.sh setup | inject <n> | hint <n> | check <n> | fix <n> | status | cleanup
$ apps/demo-app/place-order.sh <user> <password> [how-many] [item]
$ kubectl -n demo-app get pods                      # web: web + to-kafka + vault-agent; worker: from-kafka + worker + vault-agent
$ kt consumer-groups --describe --group demo-app-worker        # the backlog
```

## The daily round (lab 13B)

Nodes Ready · no pods stuck · `cilium status` · every claim Bound · `up == 0` empty · firing alerts known ·
Vault unsealed · Keycloak login works · Redis replication up · no under-replicated partitions ·
newest etcd snapshot is recent. Or: `infra/platform/verify.sh`.
