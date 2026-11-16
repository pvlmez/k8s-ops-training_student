# Lab Environment

## Per-attendee topology

```
                   ┌────────────────────────────┐
                   │  workstation (Linux / WSL) │  kubectl, helm, k9s, ansible, cilium, hubble,
                   │  ~/.kube/config            │  vault, jq, yq, stern  (installed via arkade)
                   └──────────────┬─────────────┘
                                  │ SSH (Ansible) + 6443 (API) + 80/443 (ingress)
       ┌──────────────────────────┼──────────────────────────┬─────────────────────┐
┌──────┴───────┐          ┌───────┴──────┐           ┌───────┴──────┐      ┌───────┴──────┐
│ node1        │          │ node2        │           │ node3        │      │ node4 (opt.) │
│ rke2-server  │          │ rke2-agent   │           │ rke2-agent   │      │ rke2-agent   │
│ etcd, API,   │          │ workloads    │           │ workloads    │      │ added in     │
│ sched, ctrl  │          │              │           │              │      │ lab 12       │
│ + workloads  │          │              │           │              │      │              │
└──────────────┘          └──────────────┘           └──────────────┘      └──────────────┘
   8 GB / 2–4 vCPU each.  CNI: Cilium (kube-proxy replacement)  Ingress: Traefik (RKE2-bundled)
```

- **One server, two agents** until lab 12. The server is also schedulable so
  the 3 nodes share the load.
- **The 4th node** (if available) is kept back and joined in the
  "add a node" lab (lab 12). With only 3 nodes, lab 12 drains and re-joins node3.
- A 3-server HA control plane is covered on slides only. The playbook does
  support it (`[rke2_servers]` with 3 hosts) if you want to demo it.

## Memory budget (3 × 8 GB = 24 GB)

| Component | Approx. RAM | Notes |
|---|---|---|
| RKE2 server (etcd, API, controller, scheduler) | 1.5–2 GB | node1 |
| RKE2 agents + kubelet/containerd | 0.4 GB/node | |
| Cilium agent + operator + Hubble relay/UI | 0.3 GB/node | |
| Traefik, CoreDNS, metrics-server | 0.3 GB | |
| kube-prometheus-stack (Prometheus, Grafana, Alertmanager, node-exporter, KSM) | 2–2.5 GB | retention 2d, no HA |
| Loki (single binary, filesystem) + Fluent Bit | 0.6 GB | |
| Vault (1 replica, Raft) + injector | 0.3 GB | |
| Keycloak + PostgreSQL | 1.2 GB | |
| Redis | 0.1 GB | |
| Strimzi operator + Kafka (3 broker/controller nodes) | 3 GB | 512 MB heap each |
| Demo app | 0.2 GB | |
| **Total** | **≈ 12–13 GB** | leaves headroom for labs and failure tests |

## Software versions

Pinned in `infra/versions.env` and `infra/ansible/group_vars/all.yml`.

| Component | How installed | Notes |
|---|---|---|
| Ubuntu 22.04 / 24.04 | pre-provisioned | nodes. The workstation is a Linux desktop or Windows with WSL (Ubuntu); all commands run in the Linux shell |
| RKE2 v1.35 channel | Ansible (`get.rke2.io`) | SUSE extended support to Dec 2027. Change the channel to match production. |
| Cilium | Bundled RKE2 chart (`cni: cilium`) and `HelmChartConfig` | kube-proxy replacement, Hubble enabled |
| Traefik | Bundled RKE2 chart (`ingress-controller: traefik`) | ingress-nginx was retired upstream in March 2026. RKE2 v1.36+ defaults to Traefik. |
| local-path-provisioner | Helm | Lab-only storage, see "Lab shortcuts" |
| kube-prometheus-stack | Helm (prometheus-community) | |
| Loki | Helm (**grafana-community** repo) | The chart moved out of the grafana repo in March 2026 |
| Fluent Bit | Helm (fluent) | Promtail is deprecated, so Fluent Bit is the shipper |
| Vault | Helm (hashicorp) | Raft storage, Agent Injector |
| Keycloak | Keycloak Operator (official manifests) | Postgres as a plain StatefulSet |
| Redis | In-house `redis-lab` Helm chart, official `redis` image | Bitnami's free images ended in Sep 2025 |
| Kafka | Strimzi operator (Helm) and Kafka CRs | KRaft only (ZooKeeper was removed in Kafka 4) |
| CLI tools | arkade | `infra/scripts/install-tools.sh` |

## Network and ports

| From → To | Port | Purpose |
|---|---|---|
| workstation → all nodes | 22 | Ansible/SSH |
| workstation → server | 6443 | Kubernetes API |
| workstation → server | 80/443 | Traefik ingress (Grafana, Keycloak, Vault UI, Hubble UI) |
| agents → server | 9345 | RKE2 supervisor (node join) |
| all ↔ all nodes | 6443, 9345, 10250, 2379-2380, 4240, 8472/udp, 4244 | API, join, kubelet, etcd, Cilium health, VXLAN, Hubble |

If the nodes run `ufw`, the node-prep playbook opens these. The simplest
option for a lab is to disable it (`node_firewall: disabled`).

## Ingress hostnames

No DNS server needed: `*.sslip.io` resolves to the IP embedded in the name.
`infra/scripts/lab-info.sh` prints the addresses for a cluster.

| UI | URL |
|---|---|
| Grafana | `http://grafana.<NODE1_IP>.sslip.io` |
| Hubble UI | `http://hubble.<NODE1_IP>.sslip.io` |
| Vault UI | `http://vault.<NODE1_IP>.sslip.io` |
| Keycloak | `http://keycloak.<NODE1_IP>.sslip.io` |
| Demo app | `http://app.<NODE1_IP>.sslip.io` |

## Lab shortcuts (call these out in class)

| Lab shortcut | Production equivalent |
|---|---|
| local-path storage (data tied to one node) | replicated CSI storage (e.g. Longhorn / SAN CSI) |
| Single RKE2 server | 3 servers (etcd quorum) |
| Vault: 1 replica, unseal keys printed to the terminal | 3+ replicas, auto-unseal (KMS/HSM/Transit), keys held by named custodians |
| HTTP ingress, no TLS | cert-manager / corporate CA |
| Prometheus retention 2 days, no Thanos/remote write | long-term storage |
| Keycloak `start-dev`-style hostname settings | proper hostname/TLS, HA, external DB |
