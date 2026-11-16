# Lab 13 — Backups and the daily health check

Two parts, each with its own checkpoint:

- **Part A — Take backups.** 15 min, follow along with the instructor.
  **You will:** take an etcd snapshot, a Vault snapshot and a database
  dump, and find out where they are stored and how they are scheduled.
- **Part B — The daily health check by hand.** 30 min, on your own. **You
  will:** check the platform layer by layer with the commands of the earlier labs,
  then compare your findings with `verify.sh`.

`$` = workstation · `node1$` = on node1 (`ssh node1` first) · `<something>` =
your own value · ★ = optional

You do **not** restore anything in this lab. The instructor restores an etcd
snapshot on their own cluster. Doing it yourself is the ★ Stretch at the
end, and only **after** the capstone: a failed restore leaves you without a
cluster.

---

## Part A — Take backups

### A1. What needs backing up?

| What | Holds | Lost without it |
|---|---|---|
| **etcd** | Every Kubernetes object: Deployments, Services, ConfigMaps, Secrets, custom resources | The whole cluster definition |
| **Vault** | Secrets, policies, roles | Every password the platform uses |
| **PostgreSQL** (Keycloak) | Realms, users, roles, clients | Every account |
| **Volumes** | Redis data, Kafka messages, metrics, logs | Depends on the application |
| **Git** | Manifests, values files, playbooks | The way to rebuild all of the above |

etcd does **not** contain what is inside volumes, and it does not contain
what is inside Vault.

### A2. An etcd snapshot

RKE2 takes snapshots on a schedule, and on request:

```bash
$ cd "$K8S_COURSE_HOME"
$ ssh node1
node1$ sudo grep snapshot /etc/rancher/rke2/config.yaml
node1$ sudo rke2 etcd-snapshot save --name lab13
node1$ sudo rke2 etcd-snapshot ls
node1$ sudo ls -lh /var/lib/rancher/rke2/server/db/snapshots/
node1$ exit
```

The cluster keeps a record of its snapshots too:

```bash
$ kubectl get etcdsnapshotfiles
```

**Questions:**

- How often is a snapshot taken automatically, and how many are kept?
  (The schedule is in cron notation.)
- ⚠️ The snapshots are on node1's own disk. What happens to them if node1
  is lost? Where should they go? (RKE2 can copy them to S3-compatible
  storage.)
- A snapshot contains every Kubernetes Secret. Who should be able to read
  that directory?

### A3. A Vault snapshot

```bash
$ source labs/files/lab-08/vault-cli.sh
$ v operator raft snapshot save /tmp/vault-lab13.snap
$ kubectl -n vault exec vault-0 -- ls -l /tmp/vault-lab13.snap
$ kubectl -n vault exec vault-0 -- cat /tmp/vault-lab13.snap > /tmp/vault-lab13.snap
$ kubectl -n vault exec vault-0 -- rm /tmp/vault-lab13.snap
$ ls -l /tmp/vault-lab13.snap
```

The snapshot was written inside the pod first, then copied to your
workstation: a backup that stays in the pod is gone with the pod.

**Questions:**

- The snapshot is encrypted, like everything Vault stores. What else do
  you need to make use of it after a restore? Where is that kept ⚠️?
- Nothing takes this snapshot automatically in the lab. How would you
  schedule it? (Deck 06: which kind of workload runs on a schedule?)

### A4. A database dump

```bash
$ kubectl -n keycloak exec postgres-0 -- pg_dump -U keycloak keycloak | gzip > /tmp/keycloak-lab13.sql.gz
$ ls -l /tmp/keycloak-lab13.sql.gz
$ gunzip -c /tmp/keycloak-lab13.sql.gz | grep -c 'CREATE TABLE'
```

**Question:** this file contains every user of the realm, with their
(hashed) passwords. Where may it be stored, and for how long?

### A5. Write it down

Fill in the table for **your** platform as it is today:

| What | How | Where it ends up | How often | Restore tested? |
|---|---|---|---|---|
| etcd | `rke2 etcd-snapshot` | | | |
| Vault | `vault operator raft snapshot save` | | | |
| Keycloak database | `pg_dump` | | | |
| Redis, Kafka, metrics, logs | | | | |
| Manifests and values | git | | | |

### Checkpoint A ✅

- [ ] You took an etcd snapshot and can say where the scheduled ones are
- [ ] You took a Vault snapshot and copied it out of the pod
- [ ] You dumped the Keycloak database
- [ ] You can name two things that an etcd snapshot does **not** contain

---

## Part B — The daily health check by hand

Imagine it is 08:30 and you have just sat down. Work from the bottom of the
platform to the top. For each layer, run the commands, decide **healthy or
not**, and note the one line that told you.

Load the shortcuts of the earlier labs first:

```bash
$ cd "$K8S_COURSE_HOME"
$ source labs/files/lab-08/vault-cli.sh
$ source labs/files/lab-10/redis-cli.sh
$ source labs/files/lab-11/kafka-cli.sh
```

### B1. The cluster

```bash
$ kubectl get --raw /readyz
$ kubectl get nodes
$ kubectl top nodes
$ kubectl get pods -A --no-headers | grep -v -E 'Running|Completed' || echo "every pod is Running or Completed"
$ kubectl get events -A --field-selector type=Warning --sort-by=.lastTimestamp | tail -n 5
```

### B2. Network

```bash
$ cilium status --wait-duration 10s
$ kubectl -n kube-system get pods -l k8s-app=kube-dns
$ kubectl -n kube-system rollout status daemonset/rke2-traefik --timeout=5s
$ kubectl get ingress -A
```

### B3. Storage

```bash
$ kubectl get storageclass
$ kubectl get pvc -A --no-headers | grep -v Bound || echo "every claim is Bound"
$ ssh node1 df -h /
```

### B4. Observability

```bash
$ labs/files/lab-07/promql.sh 'up == 0'
$ labs/files/lab-07/promql.sh 'ALERTS{alertstate="firing"}'
$ kubectl -n logging get pods -o wide
$ labs/files/lab-07/logql.sh '{namespace="kube-system"}'
```

### B5. Vault

```bash
$ kubectl -n vault exec vault-0 -- vault status
$ kubectl -n vault get pods
```

### B6. Keycloak

```bash
$ kubectl -n keycloak get keycloaks,pods
$ labs/files/lab-09/sso-login.sh ops-admin ChangeMe-Admin1
```

### B7. Redis

```bash
$ kubectl -n redis get pods
$ rcli redis-0 info replication
$ rcli redis-1 info replication
```

### B8. Kafka

```bash
$ kubectl -n kafka get kafkas,kafkatopics
$ kt topics --describe --under-replicated-partitions
$ kt consumer-groups --list
```

### B9. Backups

```bash
$ ssh node1 "sudo rke2 etcd-snapshot ls"
```

How old is the newest snapshot?

### B10. Your findings

| Layer | Healthy? | The line that told you |
|---|---|---|
| Cluster | | |
| Network | | |
| Storage | | |
| Observability | | |
| Vault | | |
| Keycloak | | |
| Redis | | |
| Kafka | | |
| Backups | | |

### B11. Compare with the script

```bash
$ infra/platform/verify.sh
$ grep -c 'check "' infra/platform/verify.sh
$ grep 'check "' infra/platform/verify.sh | cut -c1-110
```

**Questions:**

- Did the script and you agree on every layer?
- Find one thing **you** checked that the script does not. Find one thing
  the script checks that you did not.
- `Watchdog` shows up as a firing alert in B4. Is that a problem? (Lab 7.)
- The script is green. Does that mean the applications **on** the platform
  are healthy? What would you add for your own environment?
- Which of these checks should wake someone at night, which belong in the
  morning round, and which once a week?

### Checkpoint B ✅

- [ ] You checked every layer by hand and filled in the table
- [ ] You can name the one command per layer you would keep
- [ ] You compared your result with `verify.sh` and found a difference in
  what is checked

## If you're stuck

- `v`, `rcli` or `kt`: command not found: load the three shortcut files
  again (start of part B).
- `sudo rke2 etcd-snapshot` says "command not found": use the full path,
  `sudo /usr/local/bin/rke2 etcd-snapshot ls`.
- A layer really is unhealthy: `infra/platform/verify.sh` names it. Repair
  with `infra/platform/deploy.sh <layer>` (or `all`), then
  `infra/platform/verify.sh --wait 300`. Tell the instructor: a real fault
  is good material for the troubleshooting module.

---

## ★ Stretch — restore the etcd snapshot yourself

**Only after lab 15.** You go back in time on your own cluster. If it goes
wrong, the repair is a rebuild (`reset.yml`, `site.yml`, `deploy.sh all`),
which takes most of an hour.

Make a marker before the snapshot and another after it:

<!-- smoke: skip (restores etcd: stretch only, after the capstone) -->
```bash
$ kubectl create namespace before-the-snapshot
$ ssh node1 "sudo rke2 etcd-snapshot save --name restore-test"
$ kubectl create namespace after-the-snapshot
$ ssh node1 "sudo ls /var/lib/rancher/rke2/server/db/snapshots/ | grep restore-test"
```

Stop RKE2 on node1, restore, and start it again. Use the file name from the
last command:

<!-- smoke: skip (restores etcd: stretch only, after the capstone) -->
```bash
$ ssh node1
node1$ sudo systemctl stop rke2-server
node1$ sudo rke2 server --cluster-reset --cluster-reset-restore-path=/var/lib/rancher/rke2/server/db/snapshots/<snapshot-file>
```

Wait for the line *"Managed etcd cluster membership has been reset, restart
without --cluster-reset flag now"*. The command then ends by itself; if it
does not after a minute, stop it with `Ctrl-C`.

<!-- smoke: skip (restores etcd: stretch only, after the capstone) -->
```bash
node1$ sudo systemctl start rke2-server
node1$ exit
$ kubectl get nodes
$ kubectl get namespace before-the-snapshot
$ kubectl get namespace after-the-snapshot || echo "gone: it was created after the snapshot"
```

Give the cluster a few minutes. If node2 or node3 stays `NotReady`:
`ssh node2 sudo systemctl restart rke2-agent`. Then:

<!-- smoke: skip (restores etcd: stretch only, after the capstone) -->
```bash
$ infra/platform/vault/init-unseal.sh
$ infra/platform/verify.sh --wait 600
$ kubectl delete namespace before-the-snapshot
```

**Questions:**

- The namespace made after the snapshot is gone. What else would be gone
  in real life: Deployments, Secrets, …? What is **not** rolled back?
  (Think of Redis data, Kafka messages, Vault.)
- Kubernetes now describes the state of an hour ago; the volumes hold
  today's data. When could that mismatch hurt?
- Who in your organisation decides to restore, and how long would it take
  with a snapshot from last night?
