# Part 4 cheat sheet — Operators, Keycloak, Redis, Kafka

`$` = workstation · `<ns>` = namespace · `<ip>` = node1 address

## Operators and custom resources

A **CRD** adds a kind to the API. A **custom resource** says what you want. The **operator** makes it so and writes `status`.

```bash
$ kubectl get crds | grep -E 'keycloak|strimzi|coreos|cilium'
$ kubectl api-resources --api-group=<group>            # k8s.keycloak.org, kafka.strimzi.io, monitoring.coreos.com
$ kubectl explain <kind>.spec                           # what may be set
$ kubectl -n <ns> get <kind>                            # Ready?
$ kubectl -n <ns> describe <kind> <name>                # conditions and events
$ kubectl -n <ns> logs deployment/<operator> --tail=20
```

| Operator | Namespace | Kinds |
|---|---|---|
| `keycloak-operator` | `keycloak` | Keycloak, KeycloakRealmImport |
| `strimzi-cluster-operator` | `kafka` | Kafka, KafkaNodePool, KafkaTopic, KafkaUser |
| `kube-prometheus-stack-operator` | `monitoring` | Prometheus, ServiceMonitor, PodMonitor, PrometheusRule |

- Change the **custom resource**, not the StatefulSet or Service the operator made: it puts them back
- Operator down = nothing is repaired or changed; the application keeps running
- Never delete a CRD: every resource of that kind goes with it
- Before an operator upgrade: read the release notes for removed API versions and fields

## Keycloak

Realm `platform` · users `ops-admin`, `ops-user` · roles `grafana-admin`, `grafana-editor` · client `grafana`.
Console: `http://keycloak.<ip>.sslip.io`, user `temp-admin` ⚠️, password:
`kubectl -n keycloak get secret keycloak-initial-admin -o jsonpath='{.data.password}' | base64 -d`

```bash
$ kubectl -n keycloak get keycloaks,pods,pvc            # keycloak-0 (operator-made), postgres-0 (the data)
$ kubectl -n keycloak logs keycloak-0 --tail=30
$ labs/files/lab-09/kc.sh login                         # then any kcadm command:
$ labs/files/lab-09/kc.sh get users -r platform --fields username,enabled
$ labs/files/lab-09/sso-login.sh <user> <password>      # a Grafana login through Keycloak, without a browser
```

| Task | Console (realm `platform`) | `labs/files/lab-09/kc.sh …` |
|---|---|---|
| Add a user | Users → Create new user | `create users -r platform -s username=<u> -s enabled=true` |
| Reset a password | Users → *user* → Credentials (tick Temporary) | `set-password -r platform --username <u> --new-password <p>` |
| Give a role | Users → *user* → Role mapping | `add-roles -r platform --uusername <u> --rolename <role>` |
| Disable a user | Users → *user* → Enabled off | `update users/<id> -r platform -s enabled=false` |
| End sessions | Users → *user* → Sessions → Sign out | |
| Login history | Events → User events | `get events -r platform` |

| Symptom | Likely cause |
|---|---|
| Grafana: "Login failed" after the Keycloak page | Client secret differs, or the Grafana pod cannot reach Keycloak |
| "Invalid parameter: redirect_uri" | Address missing from the client's Valid redirect URIs |
| "HTTPS required" | Realm's Require SSL setting (lab has no TLS ⚠️) |
| Role change has no effect | Takes effect at the user's next login |
| Keycloak accepts a re-created user, Grafana refuses ("unable to create user") | Grafana still has the old user under another Keycloak ID: delete it in Grafana (`labs/files/lab-09/grafana-user.sh delete <login>`) |
| Edited `realm-platform.yaml`, nothing changed | A realm import never updates an existing realm |

Repair: `infra/platform/deploy.sh keycloak`, then `infra/platform/verify.sh --wait 300`.

## Redis

`redis-0` = primary (reads and writes), `redis-1` = replica (reads only). Applications use `redis.redis.svc:6379`, which leads only to `redis-0`. ⚠️ No automatic failover.

```bash
$ source labs/files/lab-10/redis-cli.sh                 # gives you: rcli <pod> <redis command>
$ kubectl -n redis get pods,pvc                         # 3/3: redis, exporter, vault-agent
$ rcli redis-0 info replication                         # role:master, connected_slaves:1
$ rcli redis-1 info replication                         # role:slave, master_link_status:up
$ rcli redis-0 info memory                              # used_memory_human, maxmemory_human
$ rcli redis-0 info stats                               # evicted_keys
$ kubectl -n redis logs redis-0 -c redis --tail=20
```

Prometheus: `redis_up` · `redis_connected_slaves` · `redis_memory_used_bytes / redis_memory_max_bytes`

| Symptom | Likely cause |
|---|---|
| Pod stuck at `Init:0/1` | Vault sealed, or the Vault role does not match |
| Writes fail, reads work | `redis-0` is down |
| `master_link_status:down` | Primary down, or different passwords |
| Keys disappear | Memory full: `allkeys-lru` evicts |
| Pod `Pending` after a node failure | Its local-path volume is on that node ⚠️ |

Repair: `infra/platform/deploy.sh redis`, then `infra/platform/verify.sh --wait 180`.

## Kafka and Strimzi

Cluster `platform`: brokers `platform-dual-role-0`, `-1`, `-2` (each also a controller ⚠️). Applications connect to `platform-kafka-bootstrap.kafka.svc:9092`.

```bash
$ source labs/files/lab-11/kafka-cli.sh                 # gives you: kt <tool> <arguments>
$ kubectl -n kafka get kafkas,kafkanodepools,kafkatopics,pods
$ kt topics --list
$ kt topics --describe --topic <topic>                  # Leader, Replicas, Isr per partition
$ kt topics --describe --under-replicated-partitions    # prints nothing when healthy
$ kt consumer-groups --list
$ kt consumer-groups --describe --group <group>         # CURRENT-OFFSET, LOG-END-OFFSET, LAG
$ kt metadata-quorum describe --status                  # LeaderId, CurrentVoters
$ kubectl -n kafka logs platform-dual-role-0 --tail=30
```

A topic is a KafkaTopic object with the label `strimzi.io/cluster: platform`. Partitions can go up, never down.

| Brokers up | Read | Write (replicas 3, `min.insync.replicas` 2) |
|---|---|---|
| 3 | Yes | Yes |
| 2 | Yes | Yes, under-replicated |
| 1 | Yes | No: "not enough replicas" |

Prometheus: `sum(kafka_server_replicamanager_underreplicatedpartitions)` (0) · `sum by (consumergroup) (kafka_consumergroup_lag)`.
Grafana dashboards: **Strimzi Kafka**, **Strimzi Kafka Exporter**.

| Symptom | Likely cause |
|---|---|
| Lag grows, cluster healthy | The consuming application is slow or down |
| Under-replicated partitions stay | A broker is down or cannot catch up |
| "Unknown topic" | Never declared; automatic creation is off |
| KafkaTopic not Ready | Missing cluster label, or partitions reduced |
| Broker `Pending` | Not enough memory, or its volume's node is down ⚠️ |

Repair: `infra/platform/deploy.sh kafka`, then `infra/platform/verify.sh --wait 300`.

## ⚠️ Lab shortcuts in this part

Keycloak over HTTP with the bootstrap admin and one PostgreSQL pod · Redis without failover ·
Kafka without authentication, brokers that are also controllers, `deleteClaim: true` · everything on local-path volumes.
