# Lab 11 — Kafka: topics, consumer lag and losing a broker

Two parts, each with its own checkpoint:

- **Part A — Tour Kafka.** 20 min, follow along with the instructor.
  **You will:** find the custom resources and what Strimzi made of them,
  read a topic's partitions and replicas, and open the Kafka dashboards in
  Grafana.
- **Part B — Topics, lag and a lost broker.** 45 min, on your own. **You
  will:** create a topic, produce and consume messages, build up consumer
  lag and see it in Grafana, and delete a broker while the cluster keeps
  working.

`$` = workstation · `<something>` = your own value · ★ = optional

The helper script and the topic manifest are in `labs/files/lab-11/`.
Part B uses its own topic `lab11` and consumer group `lab11-readers`.

> **Bare start?** Do **★ Build** at the end of this guide **first** (20
> minutes): you install the Strimzi operator and a three-broker Kafka
> cluster. Then do parts A and B like everyone else.

---

## Part A — Tour Kafka

### A1. What you asked for, and what Strimzi made of it

```bash
$ cd "$K8S_COURSE_HOME"
$ kubectl -n kafka get kafkas,kafkanodepools,kafkatopics
$ kubectl -n kafka get pods -o wide
$ kubectl -n kafka get pvc
```

Fill in the table:

| Pod | How many | What it does |
|---|---|---|
| `strimzi-cluster-operator-…` | 1 | Turns the Kafka custom resources into pods, Services and configuration |
| `platform-dual-role-0`, `-1`, `-2` | | |
| `platform-entity-operator-…` | | |
| `platform-kafka-exporter-…` | | |

```bash
$ cat infra/platform/kafka/kafka-cluster.yaml
$ kubectl -n kafka get kafka platform -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}'
$ kubectl -n kafka get kafka platform -o jsonpath='{range .status.listeners[*]}{.name}: {.bootstrapServers}{"\n"}{end}'
```

**Questions:**

- Are the three brokers on three different nodes? Which part of
  `kafka-cluster.yaml` asks for that, and why does it matter?
- The last command prints the addresses applications connect to. What is
  the difference between the two listeners?

### A2. Topics, partitions, replicas

Load the shortcut for Kafka's own tools:

```bash
$ cat labs/files/lab-11/kafka-cli.sh
$ source labs/files/lab-11/kafka-cli.sh
$ kt topics --list
$ kt topics --describe --topic orders
```

Read one line of the `describe` output:

| Field | Meaning |
|---|---|
| `Partition: 0` | The topic is split into numbered logs; this is one of them |
| `Leader: 2` | The broker that takes reads and writes for this partition |
| `Replicas: 2,0,1` | The brokers that hold a copy |
| `Isr: 2,0,1` | **In-sync replicas**: the copies that are fully up to date |

**Healthy** = every partition has a leader, and `Isr` lists as many
brokers as `Replicas`.

```bash
$ kt topics --describe --under-replicated-partitions
$ kubectl -n kafka get kafkatopic orders -o yaml
```

The first command prints nothing when all is well. The second shows where
the topic came from: a KafkaTopic object, kept in
`infra/platform/kafka/topics.yaml`.

### A3. Who leads the cluster?

There is no ZooKeeper. The brokers elect a controller among themselves
(**KRaft**):

```bash
$ kt metadata-quorum describe --status
```

Find `LeaderId` and `CurrentVoters`.

**Question:** with three voters, how many can be lost before the cluster
can no longer agree on anything?

### A4. The dashboards

```bash
$ IP=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' | sed -E 's#https?://([^:/]+).*#\1#')
$ echo "http://grafana.$IP.sslip.io"
$ kubectl -n monitoring get configmaps -l grafana_dashboard=1 | grep strimzi
```

In Grafana (as `ops-admin`, through Keycloak) open **Dashboards** and
search for **Strimzi**:

1. **Strimzi Kafka**: brokers online, under-replicated partitions, offline
   partitions. Note the three numbers.
2. **Strimzi Kafka Exporter**: topics, partitions, and consumer group lag
   (empty for now: nobody is consuming).

The same from the command line:

```bash
$ labs/files/lab-07/promql.sh 'count(kafka_server_replicamanager_leadercount)'
$ labs/files/lab-07/promql.sh 'sum(kafka_server_replicamanager_underreplicatedpartitions)'
```

### Checkpoint A ✅

- [ ] You filled in the table of pods
- [ ] You can read `Leader`, `Replicas` and `Isr` for a partition
- [ ] No partition is under-replicated
- [ ] You found the Strimzi dashboards in Grafana

---

## Part B — Topics, lag and a lost broker

If you opened a new terminal, load the shortcut again:

```bash
$ cd "$K8S_COURSE_HOME"
$ source labs/files/lab-11/kafka-cli.sh
```

### B1. Create a topic

```bash
$ cat labs/files/lab-11/topic-lab11.yaml
$ kubectl apply -f labs/files/lab-11/topic-lab11.yaml
$ kubectl -n kafka wait kafkatopic/lab11 --for=condition=Ready --timeout=120s
$ kubectl -n kafka get kafkatopics
$ kt topics --describe --topic lab11
```

**Question:** you created a Kubernetes object, and a topic appeared in
Kafka. Which pod did that? (A1.)

### B2. Produce and consume

Send 100 messages, then read them as the consumer group `lab11-readers`:

```bash
$ seq 1 100 | sed 's/^/order /' | kt console-producer --topic lab11
$ kt console-consumer --topic lab11 --group lab11-readers --from-beginning --max-messages 100 --timeout-ms 60000
$ kt consumer-groups --describe --group lab11-readers
```

In the last output, every partition has three numbers:

| Column | Meaning |
|---|---|
| `LOG-END-OFFSET` | How many messages the partition holds |
| `CURRENT-OFFSET` | How far this group has read |
| `LAG` | The difference: messages waiting to be read |

**Questions:**

- The messages did not come out in the order 1 to 100. Why not? Within
  what is the order kept?
- Kafka remembers how far the **group** has read. What happens when a
  consumer of that group restarts?

### B3. Build up lag

Nobody is consuming now. Send 150 more messages:

```bash
$ seq 101 250 | sed 's/^/order /' | kt console-producer --topic lab11
$ kt consumer-groups --describe --group lab11-readers
```

Total lag is now 150. That number is the most useful Kafka alert there is:
it means "consumers are not keeping up", whatever the reason.

Prometheus collects it through the Kafka Exporter. It can take a minute or
two to show up:

```bash
$ sleep 90
$ labs/files/lab-07/promql.sh 'sum by (consumergroup, topic) (kafka_consumergroup_lag{consumergroup="lab11-readers"})'
```

In Grafana open **Strimzi Kafka Exporter** and find the group
`lab11-readers` in the consumer lag panel.

Now let the consumer catch up:

```bash
$ kt console-consumer --topic lab11 --group lab11-readers --max-messages 150 --timeout-ms 60000
$ kt consumer-groups --describe --group lab11-readers
```

**Questions:**

- Lag is back to 0 on the command line. How long until the graph agrees?
- Lag grows steadily during the night and drops to zero each morning. Is
  that a Kafka problem? Whom do you call?

### B4. Lose a broker

Delete one of the three brokers and look at the topic **while it is
away**:

<!-- smoke: disruptive -->
```bash
$ kubectl -n kafka delete pod platform-dual-role-2 --wait=false
$ sleep 20
$ kubectl -n kafka get pods
$ kt topics --describe --topic lab11
$ kt topics --describe --under-replicated-partitions
```

Can you still write? The topic needs 2 in-sync copies
(`min.insync.replicas`), and 2 brokers are left:

```bash
$ seq 251 270 | sed 's/^/order /' | kt console-producer --topic lab11
$ kt console-consumer --topic lab11 --group lab11-readers --max-messages 20 --timeout-ms 60000
```

Wait for the broker to come back, then look again:

<!-- smoke: disruptive -->
```bash
$ sleep 40
$ kubectl -n kafka wait --for=condition=Ready pod/platform-dual-role-2 --timeout=300s
$ sleep 30
$ kt topics --describe --topic lab11
$ kt topics --describe --under-replicated-partitions
$ infra/platform/verify.sh --wait 180
```

**Questions:**

- While broker 2 was away: what did `Isr` show, and who became leader of
  the partitions it had led?
- Producing and consuming carried on. What would have happened with a
  **second** broker down at the same time? (Compare `Isr` with
  `min.insync.replicas`.)
- The broker came back with the same name and the same volume. It had
  missed 20 messages. How did it get them?
- In the **Strimzi Kafka** dashboard, find the moment in the
  "under-replicated partitions" graph.

### B5. Clean up

```bash
$ kt consumer-groups --delete --group lab11-readers
$ kubectl delete -f labs/files/lab-11/topic-lab11.yaml
$ kubectl -n kafka get kafkatopics
```

### Checkpoint B ✅

- [ ] You created a topic by applying a KafkaTopic
- [ ] You produced and consumed messages, and can read `LAG` for a
  consumer group
- [ ] You saw consumer lag in Prometheus or Grafana
- [ ] You deleted a broker; producing and consuming carried on, and the
  partitions were back in sync afterwards
- [ ] The topic `lab11` is gone and `verify.sh` ends with `0 failed`

## If you're stuck

- `kt` says `command not found`: `source labs/files/lab-11/kafka-cli.sh`
  (needed in every new terminal).
- `kt` cannot connect, or you deleted the pod it runs in: use another
  broker, for example `KAFKA_POD=platform-dual-role-1 kt topics --list`.
- The KafkaTopic does not become Ready:
  `kubectl -n kafka describe kafkatopic lab11`, then the Topic Operator's
  log: `kubectl -n kafka logs deployment/platform-entity-operator -c topic-operator --tail=20`.
- A broker pod stays `Pending`: not enough memory on the nodes.
  `kubectl -n kafka describe pod <pod>`, and tell the instructor.
- Kafka itself is broken: `infra/platform/deploy.sh kafka`, then
  `infra/platform/verify.sh --wait 300`.
- Start part B again: do B5, then repeat from B1.

---

## ★ Build — install Strimzi and a Kafka cluster (bare start)

Do this part **first**. 20 minutes, much of it waiting for the brokers. You
do by hand what `infra/platform/deploy.sh kafka` does, with the same chart
version and manifests, and let the script finish.

**The operator**, with Helm:

```bash
$ cd "$K8S_COURSE_HOME"
$ source infra/platform/lib.sh
$ helm_repos
$ helm upgrade --install strimzi strimzi/strimzi-kafka-operator -n kafka --create-namespace --version "$CHART_STRIMZI" -f infra/platform/kafka/strimzi-values.yaml --wait
$ kubectl -n kafka get pods
$ kubectl get crds | grep strimzi
```

**The cluster.** One file holds a KafkaNodePool (three nodes), a Kafka
(listeners and settings) and the metrics configuration. Apply it and watch
the operator build the cluster; this takes three to five minutes:

```bash
$ kubectl apply -f infra/platform/kafka/kafka-cluster.yaml
$ kubectl -n kafka get kafkas,kafkanodepools
$ wait_for kafka kafka/platform Ready 900 strimzi.io/cluster=platform
$ kubectl -n kafka get pods -o wide
```

**Topics and dashboards.** Let the script do the rest. It repeats what you
did (nothing changes), then creates the platform's topics and loads the
Grafana dashboards:

```bash
$ infra/platform/deploy.sh kafka
$ infra/platform/verify.sh
```

**Questions:**

- The pods appeared one after another, and the entity operator and the
  exporter came last. Who decided that order?
- In `kafka-cluster.yaml`, find the line marked LAB ONLY. What does it do
  to the data when the cluster is deleted?

### Build checkpoint ✅

- [ ] Three `platform-dual-role-…` pods are `1/1`
- [ ] `kubectl -n kafka get kafkatopics` shows `orders` and `audit-events`
- [ ] `verify.sh` shows the Kafka lines green and ends with `0 failed`

---

## ★ Stretch

- **A topic nobody declared.** `seq 1 3 | kt console-producer --topic
  not-declared`. What happens, and which setting in `kafka-cluster.yaml`
  is responsible? Why is that the safer choice?
- **More partitions.** Copy `topic-lab11.yaml`, set `partitions: 6`, apply
  it (before B5). Then try to set it back to 3. What does the KafkaTopic's
  status say?
- **Reset a group.** With the group idle:
  `kt consumer-groups --reset-offsets --to-earliest --group lab11-readers --topic lab11 --execute`.
  What is the lag now? When would you do this for real, and what does the
  application then see?
- **The operator at work.** `kubectl -n kafka logs deployment/strimzi-cluster-operator --tail=20`
  after B4: how does Strimzi describe the pod you deleted?
- **Who owns the broker pods?** `kubectl -n kafka get strimzipodsets`.
  Strimzi does not use StatefulSets. Why might an operator want to control
  pods itself?
