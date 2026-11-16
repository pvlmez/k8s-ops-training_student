# Lab 15 — Capstone: one application, the whole platform

**Time:** 30 min · **Mode:** follow along with the instructor ·
**You will:** deploy a small shop application that uses Keycloak, Vault,
Redis and Kafka, follow one order through every layer, and operate it:
stop the worker, watch the backlog build up, and clear it.

`$` = workstation · `<something>` = your own value · ★ = optional

The application is in `apps/demo-app/`. It is deliberately small: the point
is not the code, it is that you can now explain **everything around it**.

| Part | What it does | Platform service |
|---|---|---|
| `web` (2 pods) | Shows the shop, takes orders from logged-in users | **Keycloak** for the login, **Redis** for sessions and counters |
| | Hands each order on | **Kafka**, topic `orders` |
| `worker` (1 pod) | Reads the orders and marks them processed | **Kafka** consumer group `demo-app-worker`, **Redis** |
| Both | Get their passwords as files | **Vault**, role `demo-app` |
| Both | Logs and metrics | **Loki**, **Prometheus** |

---

## Explore

### 1. Deploy it

```bash
$ cd "$K8S_COURSE_HOME"
$ infra/platform/verify.sh
$ infra/platform/deploy.sh app
$ kubectl -n demo-app get pods,services,ingress
```

While it starts, read what the layer did (the function `deploy_app`):

```bash
$ grep -n -A12 '^deploy_app()' infra/platform/deploy.sh
```

**Question:** the script did three things outside the namespace `demo-app`
before it created any pod. Which, and in which platform services?

### 2. What is in a pod?

```bash
$ kubectl -n demo-app get pods
$ kubectl -n demo-app get deployment web -o jsonpath='{range .spec.template.spec.containers[*]}{.name}: {.image}{"\n"}{end}'
$ kubectl -n demo-app get pod -l app.kubernetes.io/component=web -o jsonpath='{range .items[0].spec.containers[*]}{.name}{"\n"}{end}'
```

The Deployment asks for two containers; the pod has three.

| Container | Its job |
|---|---|
| `web` | The Python program (its code is mounted from a ConfigMap) |
| `to-kafka` | Sends each order to Kafka, with Kafka's own tools |
| `vault-agent` | |

**Question:** who added the third container, and what told it to?

### 3. The identity and the secrets

```bash
$ source labs/files/lab-08/vault-cli.sh
$ v read auth/kubernetes/role/demo-app
$ v policy read demo-app
$ kubectl -n demo-app exec deployment/web -c web -- ls -l /vault/secrets/
$ kubectl -n demo-app get secrets
$ labs/files/lab-09/kc.sh login
$ labs/files/lab-09/kc.sh get clients -r platform -q clientId=demo-app --fields clientId,redirectUris,publicClient
```

**Questions:**

- Which two Vault paths may this application read? Which one does it share
  with Redis itself?
- The application has a **client secret** for Keycloak. Follow it: where
  was it generated, where is it stored, and how does the pod get it?

### 4. Use it

```bash
$ IP=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' | sed -E 's#https?://([^:/]+).*#\1#')
$ echo "http://demo.$IP.sslip.io"
```

Open the address. Choose **Log in with Keycloak**, log in as `ops-user`
(`ChangeMe-User1`), and place a few orders. Reload the page: *Placed* and
*Processed* go up, and your orders appear under *Last processed*.

The same from the command line, for 20 orders at once:

```bash
$ apps/demo-app/place-order.sh ops-user ChangeMe-User1 20 tea
$ sleep 10
$ curl -s "http://demo.$IP.sslip.io/api/status" | jq '{placed, processed, waiting}'
```

### 5. Follow an order through the platform

Load the other two shortcuts, then visit each stop:

```bash
$ source labs/files/lab-10/redis-cli.sh
$ source labs/files/lab-11/kafka-cli.sh
```

**Keycloak** (who logged in):

```bash
$ kubectl -n demo-app logs deployment/web -c web --tail=30 | grep 'event=login' || echo "(no login line in the last 30)"
```

**Redis** (the counters and the last processed orders):

```bash
$ rcli redis-0 get demo:orders
$ rcli redis-0 get demo:processed
$ rcli redis-0 lrange demo:recent 0 2
```

**Kafka** (the orders in transit):

```bash
$ kt topics --describe --topic orders
$ kt consumer-groups --describe --group demo-app-worker
```

**Loki and Prometheus** (what the application said, and its numbers):

```bash
$ labs/files/lab-07/logql.sh '{namespace="demo-app"} |= "order_processed"'
$ labs/files/lab-07/promql.sh 'sum(demo_orders_placed_total)'
$ kubectl -n demo-app get servicemonitors
```

**Questions:**

- An order is placed. List, in order, every component it passes through
  until "processed" goes up by one.
- The web page is served by two pods, yet you stay logged in whichever pod
  answers. Where is your session kept?
- `demo_orders_placed_total` may show `(0 series)` at first. Why, and when
  does it appear?

---

## Operate

### 6. Stop the worker and watch the backlog

```bash
$ kubectl -n demo-app scale deployment/worker --replicas=0
$ kubectl -n demo-app rollout status deployment/worker --timeout=120s
$ apps/demo-app/place-order.sh ops-user ChangeMe-User1 50 cake
$ kt consumer-groups --describe --group demo-app-worker
```

The shop still takes orders: *Waiting* is 50, and the consumer group's
`LAG` adds up to 50. Kafka is holding the work.

In Grafana, open **Strimzi Kafka Exporter** and find the group
`demo-app-worker`.

### 7. Bring it back, twice as strong

```bash
$ kubectl -n demo-app scale deployment/worker --replicas=2
$ kubectl -n demo-app rollout status deployment/worker --timeout=180s
$ sleep 45
$ curl -s "http://demo.$IP.sslip.io/api/status" | jq '{placed, processed, waiting}'
$ kt consumer-groups --describe --group demo-app-worker
```

**Questions:**

- No order was lost while the worker was away. Which component made that
  possible, and for how long would it have kept them? (Lab 11: retention.)
- With two workers, look at the `CONSUMER-ID` column. How did Kafka divide
  the six partitions?
- An application team says "our orders are slow". From what you just saw,
  which **one** number do you look at first?

### 8. Change a secret without a restart

The greeting on the page comes from Vault:

```bash
$ v kv patch secret/demo-app/config greeting="Hello from the capstone"
$ sleep 45
$ curl -s "http://demo.$IP.sslip.io/" | grep -o 'class="box">[^<]*'
$ kubectl -n demo-app get pods
```

The pods were not restarted. Put it back:

```bash
$ v kv patch secret/demo-app/config greeting="Hello from Vault"
```

### 9. What if?

Do not try these now; answer them from what you learned in this course. For
each one: **what does the user see, and where would you look first?**

| If this fails | The user sees | You look at |
|---|---|---|
| Vault is sealed | | |
| Keycloak is down | | |
| `redis-0` is down | | |
| One Kafka broker is down | | |
| Two Kafka brokers are down | | |
| The worker crashes in a loop | | |
| A network policy blocks `demo-app` from `kafka` | | |

The instructor picks two of them and tries them on the projector.

Leave the application running: the wrap-up uses it.

---

## Checkpoint ✅

- [ ] The shop answers, and you placed an order after logging in through
  Keycloak
- [ ] You found your order's trace in Redis, in Kafka and in Loki
- [ ] You stopped the worker, saw the lag, and cleared it with two workers
- [ ] You changed the greeting in Vault and saw it on the page without a
  restart
- [ ] You filled in the "what if" table

## If you're stuck

- `deploy.sh app` stops with "the demo app needs the '…' layer": that
  layer is missing. `infra/platform/deploy.sh all`, then
  `infra/platform/deploy.sh app`.
- The pods stay at `Init:0/1`: Vault is sealed or refuses them.
  `kubectl -n demo-app logs <pod> -c vault-agent-init --tail=10`, then
  `infra/platform/vault/init-unseal.sh`.
- The `web` pods are `Running` but not Ready: they cannot reach Redis.
  `kubectl -n demo-app logs deployment/web -c web --tail=10`, then lab 10.
- Login ends in "Login failed": the client `demo-app` or its secret is
  wrong. Run `infra/platform/deploy.sh app` again and tell the instructor.
- Orders are placed but never processed: look at both containers of the
  worker, `kubectl -n demo-app logs deployment/worker -c from-kafka --tail=20`
  and `-c worker`.
- Start again: `kubectl delete namespace demo-app`, wait until it is gone,
  then `infra/platform/deploy.sh app`.

## ★ Stretch

- **Deploy it by hand.** Delete the namespace `demo-app`, read `deploy_app`
  in `infra/platform/deploy.sh`, and run its steps yourself, one at a
  time. (The Keycloak client and the Vault secret already exist; start at
  "code (ConfigMap) and workloads".)
- **Read the code.** `apps/demo-app/app/web.py` is about 200 lines. Find
  the two steps of the login (`login` and `callback`) and match them to
  the "A login, step by step" slide in deck 14.
- **An alert for the backlog.** Write a PrometheusRule that fires when
  `sum(kafka_consumergroup_lag{consumergroup="demo-app-worker"})` stays
  above 20 for a minute, apply it in the namespace `demo-app`, and repeat
  step 6. (Lab 7 has the pattern.)
- **Lock it down.** Write network policies for the namespace `demo-app`:
  default-deny, then allow exactly what the application needs. Which
  namespaces must it reach, on which ports? Do not forget DNS and Vault.
- **Restore etcd yourself**: the ★ Stretch at the end of lab 13, now that
  the capstone is done.
