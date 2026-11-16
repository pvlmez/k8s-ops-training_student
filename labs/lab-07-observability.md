# Lab 7 — Observability: metrics, logs and alerts

Two parts, each with its own checkpoint:

- **Part A — Find a pod's metrics and logs.** 25 min, follow along with the
  instructor. **You will:** see which parts the monitoring and logging stack
  is made of, check that Prometheus reaches all its targets, and find the
  metrics and the logs of one pod in Grafana.
- **Part B — Query, alert and trace a log line.** 45 min, on your own.
  **You will:** follow one log line from the container to Loki, write PromQL
  queries, load an alert rule, make it fire and watch it clear.

`$` = workstation · `node2$` = on node2 (`ssh node2` first) · `<something>` =
your own value · ★ = optional

The helper scripts and manifests are in `labs/files/lab-07/`. Part B works in
the namespace `lab7`.

> **Bare start?** Do **★ Build** at the end of this guide **first** (20
> minutes): you install Prometheus, Grafana, Loki and Fluent Bit with Helm.
> Then do parts A and B like everyone else.

---

## Part A — Find a pod's metrics and logs

### A1. What the stack is made of

```bash
$ cd "$K8S_COURSE_HOME"
$ kubectl -n monitoring get pods
$ kubectl -n logging get pods -o wide
```

Fill in the table (the first row is done):

| Component | Namespace | Kind | What it does |
|---|---|---|---|
| Prometheus | `monitoring` | StatefulSet | Collects and stores metrics |
| Alertmanager | | | |
| Grafana | | | |
| node-exporter | | | |
| kube-state-metrics | | | |
| Loki | | | |
| Fluent Bit | | | |

**Question:** two of these run one pod on every node. Which two, and why do
they have to?

### A2. Who tells Prometheus what to collect?

Nobody edits a Prometheus configuration file. The settings are Kubernetes
objects, and the Prometheus Operator turns them into configuration:

```bash
$ kubectl -n monitoring get prometheus,alertmanager
$ kubectl get servicemonitors -A
$ kubectl get prometheusrules -A
$ kubectl -n logging get servicemonitors -o yaml
```

In the last output find `selector` and `endpoints`: this ServiceMonitor tells
Prometheus to collect metrics from the Fluent Bit Service.

### A3. Does Prometheus reach all its targets?

Put your node1 address in a variable (the same line as in lab 5):

```bash
$ IP=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' | sed -E 's#https?://([^:/]+).*#\1#')
$ echo "http://prometheus.$IP.sslip.io/targets"
```

Open that address in your browser. Every target should be **UP**. The same
information on the command line:

```bash
$ curl -s "http://prometheus.$IP.sslip.io/api/v1/targets?state=active" | jq -r '.data.activeTargets[] | "\(.health)  \(.labels.job)"' | sort | uniq -c
```

Prometheus keeps the result of every collection in a metric called `up`
(1 = worked, 0 = failed). `promql.sh` runs a query for you:

```bash
$ labs/files/lab-07/promql.sh 'count by (job) (up)'
$ labs/files/lab-07/promql.sh 'up == 0'
```

**Questions:**

- The second query should print `(0 series)`. What would a line in that
  output mean?
- Why is there no target for `kube-proxy` on this cluster?

### A4. Metrics of one pod, in Grafana

```bash
$ echo "http://grafana.$IP.sslip.io"
$ kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

Log in as `admin` with that password. Then:

1. **Dashboards → Kubernetes / Compute Resources / Namespace (Pods)**. Choose
   the namespace `monitoring`. Find the pod that uses the most memory.
2. Click that pod's name: you are now on **Kubernetes / Compute Resources /
   Pod**. Find its memory **requests** and **limits** lines in the graph.
3. **Dashboards → Node Exporter / Nodes**. Pick each of your nodes in turn.
   Which one is busiest?

**Question:** on the pod dashboard, how far is the pod's memory use from its
limit? What happens when it gets there? (Think back to lab 4.)

### A5. Logs of the same pod, in Grafana

1. **Explore** (the compass in the left menu). Choose the data source
   **Loki** at the top.
2. Switch the query editor from *Builder* to **Code** and run:
   `{namespace="monitoring", app="grafana"}`
3. Open one log line and look at its labels: `namespace`, `pod`,
   `container`, `node`, `app`.
4. Narrow the search to lines containing a word:
   `{namespace="monitoring", app="grafana"} |= "error"`

The same lines, straight from the pod:

```bash
$ kubectl -n monitoring logs deployment/kube-prometheus-stack-grafana -c grafana --tail=5
```

**Question:** `kubectl logs` and Loki show the same lines. Which of the two
still has them after the pod has been deleted?

### Checkpoint A ✅

- [ ] You filled in the table of components
- [ ] Every Prometheus target is UP, and you can check that with one query
- [ ] You found a pod's memory use, request and limit in Grafana
- [ ] You found the same pod's log lines in Grafana Explore

---

## Part B — Query, alert and trace a log line

### B1. Start something to observe

```bash
$ cat labs/files/lab-07/chatty.yaml
$ kubectl create namespace lab7
$ kubectl -n lab7 apply -f labs/files/lab-07/chatty.yaml
$ kubectl -n lab7 rollout status deployment/chatty --timeout=120s
$ kubectl -n lab7 logs deployment/chatty --tail=5
```

`chatty` writes one line every two seconds. Every fifth line reports a
failed order.

### B2. Follow a log line from the container to Loki

**Stop 1: the node.** The container writes to its standard output; the
container runtime saves that in a file on the node. Find out which node one
of the pods is on (`lab-info.sh` tells you which of node1, node2, node3
that is), and look at the file there. The example uses node2:

```bash
$ kubectl -n lab7 get pods -o wide
$ infra/scripts/lab-info.sh
```

<!-- smoke: skip (depends on which node your pod landed on) -->
```bash
$ ssh node2
node2$ ls /var/log/containers/ | grep chatty
node2$ sudo tail -n 3 /var/log/containers/chatty-*_lab7_*.log
node2$ exit
```

**Stop 2: Fluent Bit.** One Fluent Bit pod per node reads those files, adds
the pod's name, namespace and labels, and sends the lines to Loki:

```bash
$ NODE=$(kubectl -n lab7 get pods -l app=chatty -o jsonpath='{.items[0].spec.nodeName}')
$ kubectl -n logging get pods -l app.kubernetes.io/name=fluent-bit -o wide --field-selector spec.nodeName="$NODE"
$ cat infra/platform/observability/fluent-bit.yaml
```

In the file find the three stages: `[INPUT]` (which files), `[FILTER]`
(what is added) and `[OUTPUT]` (where it goes, and with which labels).

Is every Fluent Bit pod sending? It publishes its own metrics:

```bash
$ labs/files/lab-07/promql.sh 'sum by (pod) (rate(fluentbit_output_proc_records_total[5m]))'
```

**Stop 3: Loki.** `logql.sh` asks Loki, the same way Grafana does:

```bash
$ labs/files/lab-07/logql.sh '{namespace="lab7"}'
$ labs/files/lab-07/logql.sh '{namespace="lab7"} |= "status=failed"'
$ labs/files/lab-07/logql.sh 'sum by (pod) (count_over_time({namespace="lab7"} |= "status=failed" [5m]))'
```

Run the first two queries in Grafana Explore as well.

**Questions:**

- The part in `{ }` selects by **label**; the part after `|=` searches the
  **text**. Which labels can you select on? (Look at the `[OUTPUT]` section.)
- The last query returns a number, not log lines. What does it count?
- Why is it a bad idea to make `order` (a different value on every line) a
  label?

### B3. PromQL: ask questions about the new pods

Run each query, here or in the Prometheus web page (**Graph** tab):

```bash
$ labs/files/lab-07/promql.sh 'kube_deployment_status_replicas_available{namespace="lab7"}'
$ labs/files/lab-07/promql.sh 'kube_pod_status_phase{namespace="lab7", phase="Running"} == 1'
$ labs/files/lab-07/promql.sh 'container_memory_working_set_bytes{namespace="lab7", container="chatty"}'
$ labs/files/lab-07/promql.sh 'sum by (namespace) (kube_pod_info)'
$ labs/files/lab-07/promql.sh 'sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="lab7", container="chatty"}[5m]))'
```

A query that prints `(0 series)` for the new pods is not broken: Prometheus
collects every 30 seconds, and `rate(...[5m])` needs at least two
collections. Run it again a minute later.

**Questions:**

- Which component publishes `kube_deployment_…` and `kube_pod_…` metrics?
  Which one publishes `container_…` metrics? (Read the `job` label.)
- `container_cpu_usage_seconds_total` only ever goes up. What does `rate()`
  turn it into?
- Write a query that shows the memory use of every pod in the namespace
  `logging`.

### B4. Load an alert rule

```bash
$ cat labs/files/lab-07/alert-rule.yaml
$ kubectl -n lab7 apply -f labs/files/lab-07/alert-rule.yaml
$ kubectl -n lab7 get prometheusrules
$ labs/files/lab-07/alert-state.sh Lab7ReplicasMissing --wait inactive 300
```

The last command waits until Prometheus has loaded the rule; that can take
a minute or two. Meanwhile, read the rule: which **expr** must be true, and
for how long (**for**)?

`inactive` means: loaded, and the condition is false. See it in the browser
too: `http://prometheus.<node1-ip>.sslip.io/alerts`.

### B5. Make it fire

Take one of the two pods away and watch the alert go from `inactive` to
`pending` to `firing`:

```bash
$ kubectl -n lab7 scale deployment/chatty --replicas=1
$ labs/files/lab-07/alert-state.sh Lab7ReplicasMissing --wait firing 300
$ labs/files/lab-07/promql.sh 'ALERTS{alertname="Lab7ReplicasMissing"}'
```

A firing alert is handed to Alertmanager, which decides who is told:

```bash
$ curl -s "http://alertmanager.$IP.sslip.io/api/v2/alerts" | jq -r '.[].labels.alertname' | sort | uniq -c
$ echo "http://alertmanager.$IP.sslip.io"
```

Open that address and find your alert, with its `summary` text.

> ⚠️ In this lab Alertmanager shows alerts but sends them nowhere. In
> production it routes them to mail, chat or an on-call system, according to
> their labels (for example `severity`).

**Questions:**

- Why did the alert spend a minute in `pending` first? What is that good
  for?
- `Watchdog` is firing all the time, on purpose. What could an alert that
  always fires be useful for?

### B6. Repair it and clean up

```bash
$ kubectl -n lab7 scale deployment/chatty --replicas=2
$ labs/files/lab-07/alert-state.sh Lab7ReplicasMissing --wait inactive 300
$ kubectl delete namespace lab7
```

The rule lived in the namespace, so it is deleted with it.

**Question:** after the namespace is gone, run
`labs/files/lab-07/logql.sh '{namespace="lab7"} |= "status=failed"'` once
more. Why do you still get lines?

### Checkpoint B ✅

- [ ] You found one log line in three places: the node, Fluent Bit's
  configuration, Loki
- [ ] You can explain the difference between a label selector `{…}` and a
  text filter `|=`
- [ ] You ran PromQL queries with a label filter, `sum by` and `rate`
- [ ] You saw your alert go `inactive` → `pending` → `firing` → `inactive`
- [ ] The namespace `lab7` is gone

## If you're stuck

- A target is DOWN, or Grafana, Prometheus or Loki does not answer:
  `infra/platform/verify.sh`. Repair with
  `infra/platform/deploy.sh observability`, then
  `infra/platform/verify.sh --wait 180`.
- `logql.sh` says "No log lines matched": check the pods write anything
  (`kubectl -n lab7 logs deployment/chatty --tail=3`), then that Fluent Bit
  runs on every node (`kubectl -n logging get pods -o wide`).
- The alert stays `not loaded`: `kubectl -n lab7 get prometheusrules`, then
  the operator's log:
  `kubectl -n monitoring logs deployment/kube-prometheus-stack-operator --tail=20`.
- Start part B again: `kubectl delete namespace lab7`, wait until it is
  gone, repeat from B1.

---

## ★ Build — install the observability stack with Helm (bare start)

Do this part **first**. 20 minutes, most of it waiting. You run the same
Helm commands, chart versions and values files as
`infra/platform/deploy.sh observability`.

Load the helper functions `deploy.sh` uses, and let them work out your
cluster's address:

```bash
$ cd "$K8S_COURSE_HOME"
$ source infra/platform/lib.sh
$ detect_ingress_ip
$ echo "UIs will be at <name>.$DOMAIN"
$ helm_repos
```

**Prometheus, Alertmanager, Grafana** (one chart: kube-prometheus-stack).
The Grafana admin password goes into a Secret first; `render` fills your
address into the values file:

```bash
$ kubectl create namespace monitoring
$ kubectl -n monitoring create secret generic grafana-admin --from-literal=admin-user=admin --from-literal=admin-password="$(lab_secret grafana-admin)"
$ render infra/platform/observability/kube-prometheus-stack.yaml > /tmp/kps-values.yaml
$ less /tmp/kps-values.yaml
$ helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack -n monitoring --version "$CHART_KUBE_PROM_STACK" -f /tmp/kps-values.yaml --wait --timeout 10m
$ kubectl -n monitoring get pods
```

**Loki**, then **Fluent Bit**:

```bash
$ helm upgrade --install loki grafana-community/loki -n logging --create-namespace --version "$CHART_LOKI" -f infra/platform/observability/loki.yaml --wait --timeout 10m
$ helm upgrade --install fluent-bit fluent/fluent-bit -n logging --version "$CHART_FLUENT_BIT" -f infra/platform/observability/fluent-bit.yaml --wait
$ kubectl -n logging get pods -o wide
```

Check it:

```bash
$ helm list -A
$ infra/platform/verify.sh
```

**Questions:**

- In `/tmp/kps-values.yaml`, find the three `…SelectorNilUsesHelmValues:
  false` lines. What would Prometheus ignore without them?
- In `loki.yaml`, what is marked as lab-only, and what does production use
  instead?

### Build checkpoint ✅

- [ ] `helm list -A` shows `kube-prometheus-stack`, `loki` and `fluent-bit`
  as `deployed`
- [ ] `verify.sh` shows the Observability lines green and ends with `0 failed`
- [ ] Grafana opens at `http://grafana.<node1-ip>.sslip.io`

---

## ★ Stretch

- Node logs are in Loki too. In Grafana Explore run
  `{job="systemd"}` and then `{job="systemd", unit="rke2-agent.service"}`.
  Which part of `fluent-bit.yaml` collects these?
- Change the alert: copy `alert-rule.yaml`, set `for: 15s`, apply it and
  repeat B5. What is the risk of a very short `for`?
- In the Prometheus web page, **Status → Configuration**: search for
  `lab7` while your rule is loaded, and for `fluent-bit`. Who wrote this
  file?
- `labs/files/lab-07/promql.sh 'topk(5, count by (__name__) ({__name__=~".+"}))'`:
  the five metric names with the most series. Why does the number of series
  matter to Prometheus's memory use?
- In Grafana, **Dashboards → New → Import** is how you add a dashboard by
  hand. On this platform dashboards are loaded from ConfigMaps instead:
  `kubectl get configmaps -A -l grafana_dashboard=1`.
