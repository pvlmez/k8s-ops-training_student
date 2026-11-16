# Part 3 cheat sheet — Observability and Vault

`$` = workstation · `<ns>` = namespace · `<ip>` = node1 address

## Where things are

| | Namespace | Web page |
|---|---|---|
| Prometheus, Alertmanager, Grafana, node-exporter, kube-state-metrics | `monitoring` | `prometheus.<ip>.sslip.io` · `alertmanager.<ip>.sslip.io` · `grafana.<ip>.sslip.io` |
| Loki, Fluent Bit | `logging` | Through Grafana → Explore → Loki |
| Vault, Agent Injector | `vault` | `vault.<ip>.sslip.io` |

Order during an incident: **alert** (that something is wrong) → **dashboard** (where) → **logs** (why).

## Metrics: Prometheus and PromQL

```bash
$ kubectl -n monitoring get pods
$ kubectl get servicemonitors,prometheusrules -A        # what the operator turns into configuration
$ labs/files/lab-07/promql.sh 'up == 0'                 # targets Prometheus cannot reach (should be none)
$ labs/files/lab-07/alert-state.sh <alert-name>         # not loaded | inactive | pending | firing
```

| Pattern | Example |
|---|---|
| Filter by label | `up{namespace="logging"}` (also `!=`, `=~"regex"`) |
| Compare | `kube_deployment_status_replicas_available < 2` |
| Rate of a counter | `rate(container_cpu_usage_seconds_total[5m])` |
| Aggregate | `sum by (namespace) (kube_pod_info)` |
| Memory per pod | `sum by (pod) (container_memory_working_set_bytes{namespace="<ns>", container!=""})` |
| CPU cores per pod | `sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="<ns>"}[5m]))` |
| Firing alerts | `ALERTS{alertstate="firing"}` |

- **Counter** (`…_total`) only goes up: use it inside `rate()`. **Gauge** goes up and down: use as it is
- `kube_…` = kube-state-metrics · `container_…` = kubelet · `node_…` = node-exporter
- Alert states: `inactive` → `pending` (true, waiting for `for:`) → `firing` (sent to Alertmanager)
- A target is missing: does the ServiceMonitor's label match the **Service**, and does the port **name** exist?
- Every different label combination is a stored series. Never use IDs as label values

## Logs: Fluent Bit, Loki and LogQL

Container stdout → node file `/var/log/containers/*.log` → **Fluent Bit** (one pod per node) → **Loki** → Grafana.

```bash
$ kubectl -n logging get pods -o wide                   # one Fluent Bit per node, all Ready
$ kubectl -n logging logs daemonset/fluent-bit --tail=20
$ labs/files/lab-07/logql.sh '{namespace="<ns>"} |= "error"'
```

| Pattern | Example |
|---|---|
| Select by label (always first) | `{namespace="redis", pod="redis-0"}` |
| Contains / does not contain | `{namespace="redis"} \|= "error"` · `!= "PING"` |
| Regular expression | `{app="grafana"} \|~ "status=(500\|503)"` |
| Count lines | `sum by (pod) (count_over_time({namespace="<ns>"} \|= "failed" [5m]))` |
| Node logs | `{job="systemd", unit="rke2-agent.service"}` |

Labels on container logs: `namespace`, `pod`, `container`, `node`, `app`. On node logs: `unit`, `node`.

| Symptom | Likely cause |
|---|---|
| A target is DOWN | The pod is down, or a network policy blocks Prometheus |
| A target is not listed at all | ServiceMonitor label or port name matches nothing |
| No logs from one node | Fluent Bit is not Ready on that node |
| Prometheus or Loki `Pending` or crash-looping | Its volume is full or missing: `kubectl -n <ns> get pvc`, `describe pod` |
| Alert never fires | Rule not loaded (`alert-state.sh`), or the `expr` returns nothing: try it as a query |

Repair: `infra/platform/deploy.sh observability`, then `infra/platform/verify.sh --wait 180`.

## Vault

```bash
$ kubectl -n vault exec vault-0 -- vault status         # Initialized true, Sealed false, HA Mode active
$ kubectl -n vault get pods                             # vault-0 1/1, vault-agent-injector 1/1
$ source labs/files/lab-08/vault-cli.sh                 # gives you: v <vault arguments>   ⚠️ root token, lab only
$ v secrets list
$ v auth list
$ v policy list
$ v policy read <policy>
$ v read auth/kubernetes/role/<role>                    # which service account + namespace gets which policies
$ v operator raft list-peers
```

**Unseal** (after any restart of the Vault pod; any 3 of the 5 keys, one at a time):

```bash
$ kubectl -n vault exec vault-0 -- vault operator unseal "$(unseal_key 0)"     # then 1, then 2
$ infra/platform/vault/init-unseal.sh                                          # or: the script does all three
```

**Key-value secrets** (version 2):

```bash
$ v kv put secret/<path> key=value other=value          # new version; replaces ALL keys
$ v kv get secret/<path>
$ v kv get -field=<key> secret/<path>
$ v kv get -version=1 secret/<path>
$ v kv metadata get secret/<path>                       # versions and dates, not the values
$ v kv metadata delete secret/<path>                    # remove it completely
```

Path trap: command line `secret/lab8/web` = in policies and annotations `secret/data/lab8/web`.

**A secret for a pod**: secret → policy (`read` on its path) → role (service account + namespace → policy) → annotations on the pod:

```yaml
vault.hashicorp.com/agent-inject: "true"
vault.hashicorp.com/role: "<role>"
vault.hashicorp.com/agent-inject-secret-<file>: "secret/data/<path>"     # appears as /vault/secrets/<file>
```

| Symptom | Likely cause | Look at |
|---|---|---|
| `vault-0` is `0/1`; "Vault is sealed" | The pod restarted | `vault status`, then unseal |
| New pod stuck at `Init:0/1` | Role does not match the service account or namespace; `data/` missing in the policy path; Vault sealed | `kubectl -n <ns> logs <pod> -c vault-agent-init` |
| Pod is `1/1`, no `/vault/secrets` | Injector did not act: injector pod down, annotation typo, blank `caBundle` | `kubectl -n vault logs deployment/vault-agent-injector` |
| Secret changed, application still uses the old value | The file was rewritten; the application has not re-read it | `kubectl -n <ns> rollout restart deployment/<name>` |

Repair: `infra/platform/deploy.sh vault`, then `infra/platform/verify.sh --wait 180`.

## ⚠️ Lab shortcuts in this part

Prometheus and Loki: one replica, 2 days, local disk · Alertmanager notifies nobody · Vault: root token in use,
all unseal keys in one file, one server, no TLS, no audit log.
