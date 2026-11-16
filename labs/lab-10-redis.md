# Lab 10 — Redis: replication, a password from Vault, and losing a pod

**Time:** 35 min · **Mode:** on your own · **You will:** check
that Redis replication works, see how the Redis password arrives from Vault,
find where the data is stored, and delete first the replica and then the
primary to see what survives.

`$` = workstation · `<something>` = your own value · ★ = optional

The helper script is in `labs/files/lab-10/`. You work on the platform's
own Redis in the namespace `redis`, with keys that start with `lab10:`.

> **Bare start?** Do **★ Build** at the end of this guide **first** (10
> minutes): you install Redis with the in-house chart. Then do the rest
> like everyone else.

---

## Explore

### 1. What runs

```bash
$ cd "$K8S_COURSE_HOME"
$ kubectl -n redis get pods,statefulsets,pvc
$ kubectl -n redis get services,endpointslices
$ helm -n redis get values redis
```

Each pod shows **3/3**. Name the three containers:

```bash
$ kubectl -n redis get pod redis-0 -o jsonpath='{range .spec.containers[*]}{.name}{"\n"}{end}'
```

| Container | What it is for |
|---|---|
| `redis` | |
| `exporter` | |
| `vault-agent` | |

**Questions:**

- There are three Services. Look at the endpoints: which Service leads to
  **only** `redis-0`, and which one to both pods?
- Why would an application that **writes** have to use the first one?

### 2. Is replication working?

Load the shortcut, then ask both pods:

```bash
$ cat labs/files/lab-10/redis-cli.sh
$ source labs/files/lab-10/redis-cli.sh
$ rcli redis-0 ping
$ rcli redis-0 info replication
$ rcli redis-1 info replication
```

| Line | On `redis-0` | On `redis-1` |
|---|---|---|
| `role` | `master` | `slave` |
| `connected_slaves` | `1` | |
| `master_link_status` | | `up` |

Those three lines are the health check for replication. `verify.sh` uses
the last one.

Write on the primary, read on the replica, then try to write on the
replica:

```bash
$ rcli redis-0 set lab10:greeting "hello from the primary"
$ rcli redis-1 get lab10:greeting
$ rcli redis-1 set lab10:other "written on the replica"
```

**Question:** what did the last command answer, and why is that a good
thing?

### 3. Where does the password come from?

You have not typed a password, and `rcli` did not ask for one.

```bash
$ kubectl -n redis get secrets
$ kubectl -n redis get pod redis-0 -o yaml | grep 'vault.hashicorp.com/'
$ kubectl -n redis exec redis-0 -c redis -- ls -l /vault/secrets/
$ kubectl -n redis exec redis-0 -c redis -- cat /scripts/password.sh
$ kubectl -n redis logs redis-0 -c vault-agent --tail=5
```

Now the Vault side, with the shortcut from lab 8:

```bash
$ source labs/files/lab-08/vault-cli.sh
$ v read auth/kubernetes/role/redis
$ v policy read redis
```

**Questions:**

- There is no Secret with the Redis password in the namespace. Where is
  the password stored, and how does it reach the `redis` container?
- The `exporter` container needs the password too. How does it get it?
  (It is the same pod.)
- What would `redis-0` do if it restarted while Vault was sealed?

### 4. Where is the data?

```bash
$ rcli redis-0 config get appendonly
$ rcli redis-0 config get save
$ kubectl -n redis exec redis-0 -c redis -- ls -l /data /data/appendonlydir
$ kubectl get pv | grep redis
```

**Question:** Redis keeps everything in memory. What are the files in
`/data` for, and which of the two settings above decides how much you can
lose in a crash?

---

## Operate

### 5. Lose the replica

<!-- smoke: disruptive -->
```bash
$ kubectl -n redis delete pod redis-1
$ rcli redis-0 info replication
$ kubectl -n redis rollout status statefulset/redis --timeout=180s
$ rcli redis-1 info replication
$ rcli redis-1 get lab10:greeting
```

**Questions:**

- While `redis-1` was away, could applications still read and write?
- The new `redis-1` has the key. Where did it get it from: its volume,
  the primary, or both?

### 6. Lose the primary

Store a counter first, so you can tell whether anything is lost:

<!-- smoke: disruptive -->
```bash
$ rcli redis-0 set lab10:counter 100
$ rcli redis-0 incr lab10:counter
$ kubectl -n redis delete pod redis-0 --wait=false
$ sleep 5
$ kubectl -n redis get pods
$ rcli redis-1 info replication
$ rcli redis-1 get lab10:counter
```

The replica still answers **reads**, and reports `master_link_status:down`.
Nobody can **write**: the Service `redis` has no pod behind it.

<!-- smoke: disruptive -->
```bash
$ kubectl -n redis get endpointslices
$ kubectl -n redis rollout status statefulset/redis --timeout=180s
$ rcli redis-0 get lab10:counter
$ rcli redis-0 get lab10:greeting
$ rcli redis-1 info replication
```

> ⚠️ **Lab only:** this Redis has no automatic failover. When the primary
> is gone, writes stop until Kubernetes has restarted it (here: seconds,
> because the node was fine; with a dead node and a local volume: until the
> node is back). Production uses Redis Sentinel, Redis Cluster or an
> operator, which promote a replica.

**Questions:**

- The counter is still 101 and the greeting is still there. The pod was
  deleted, so where did the new `redis-0` get them from?
- `redis-0` came back with the same name and the same volume. Which kind
  of controller guarantees that? What would a Deployment have done?
- Is the replica connected again (`master_link_status`)? Did anyone have
  to tell it where the primary is?

### 7. Health from the outside

The `exporter` container publishes Redis's numbers for Prometheus:

```bash
$ labs/files/lab-07/promql.sh 'redis_up'
$ labs/files/lab-07/promql.sh 'redis_connected_slaves'
$ labs/files/lab-07/promql.sh 'redis_memory_used_bytes / redis_memory_max_bytes'
```

**Question:** write down an alert rule (just the `expr`) that would have
told you about step 6.

### 8. Clean up

```bash
$ rcli redis-0 del lab10:greeting lab10:counter
$ infra/platform/verify.sh --wait 120
```

---

## Checkpoint ✅

- [ ] You can check replication with `info replication` on both pods
- [ ] You can explain how the password gets from Vault into the pod
- [ ] You deleted the replica and then the primary, and no data was lost
- [ ] You can say what this Redis does **not** do when the primary is gone
- [ ] `verify.sh` ends with `0 failed`

## If you're stuck

- `rcli` says `command not found`: `source labs/files/lab-10/redis-cli.sh`
  (needed in every new terminal).
- A Redis pod stays at `Init:0/1`: Vault is sealed or refuses the pod.
  `kubectl -n redis logs <pod> -c vault-agent-init --tail=10`, then lab 8,
  step A7.
- `redis-1` stays not Ready after a change: a StatefulSet does not replace
  a pod that never became Ready (lab 6). Delete that pod.
- Redis itself is broken: `infra/platform/deploy.sh redis`, then
  `infra/platform/verify.sh --wait 180`.

---

## ★ Build — install Redis with the in-house chart (bare start)

Do this part **first**. 10 minutes. Vault must be running and unsealed
(lab 8): Redis gets its password from it. You run the same chart and values
as `infra/platform/deploy.sh redis`.

```bash
$ cd "$K8S_COURSE_HOME"
$ infra/platform/verify.sh
$ cat infra/platform/redis/values-vault.yaml
$ helm template redis infra/charts/redis-lab -n redis -f infra/platform/redis/values-vault.yaml -f infra/platform/redis/values-pinned.yaml | grep -E '^kind:|vault.hashicorp'
$ helm upgrade --install redis infra/charts/redis-lab -n redis --create-namespace -f infra/platform/redis/values-vault.yaml -f infra/platform/redis/values-pinned.yaml
$ kubectl -n redis rollout status statefulset/redis --timeout=300s
$ kubectl -n redis get pods
$ infra/platform/verify.sh
```

**Questions:**

- `redis-1` was only created after `redis-0` was Ready. Why does a
  StatefulSet start its pods one at a time?
- What is in `values-pinned.yaml`, and what does it protect you from?

### Build checkpoint ✅

- [ ] `redis-0` and `redis-1` are `3/3`
- [ ] `verify.sh` shows the Redis lines green and ends with `0 failed`

---

## ★ Stretch

- **Fill it up.** This Redis may use 96 MB (`rcli redis-0 config get
  maxmemory`) and then evicts the least recently used keys
  (`maxmemory-policy`). When is that the right behaviour, and when is it a
  disaster?
- **How far behind is the replica?** Compare `master_repl_offset` on
  `redis-0` with `slave_repl_offset` on `redis-1` in `info replication`.
- **The dashboard.** In Grafana Explore (Prometheus), graph
  `rate(redis_commands_processed_total[1m])` and run
  `rcli redis-0 ping` a few times.
- **Rotate the password.** Think it through before you try it: the
  password is in Vault **and** in the running Redis. Which steps, in which
  order, change it without an outage? (Hint: both pods read it only when
  they start.)
- **Read the chart.** `infra/charts/redis-lab/templates/configmap.yaml`:
  how does a pod decide whether it is the primary?
