# Lab 12 — Node operations: drain a node, add a node

**Time:** 45 min · **Mode:** on your own · **You will:** find out
what runs on a node and what protects it, take the node out of service for
maintenance and bring it back, and add a fourth node to the cluster with
Ansible.

`$` = workstation · `<something>` = your own value · ★ = optional

Both tracks do this lab the same way: by now everyone has the same cluster.
You take **node3** out of service. node4 is the spare node on your desk card.

---

## Explore

### 1. What runs on node3?

Kubernetes knows node3 under its own node name. Put it in a variable:

```bash
$ cd "$K8S_COURSE_HOME"
$ kubectl get nodes -o wide
$ N3=$(ssh node3 hostname)
$ echo "$N3"
$ kubectl get pods -A -o wide --field-selector spec.nodeName="$N3"
```

Sort those pods into three groups:

| Group | How to recognise it | When the node is drained |
|---|---|---|
| DaemonSet pods | `cilium`, `rke2-traefik`, `fluent-bit`, `node-exporter` | Stay: every node has its own |
| Pods **without** their own volume | Deployments such as Grafana, operators | Are started again on another node |
| Pods **with** a volume | `redis-…`, `platform-dual-role-…`, `vault-0`, `postgres-0`, `prometheus-…`, `loki-0` | Depends on where the volume is |

### 2. Where are the volumes?

```bash
$ kubectl get pv -o custom-columns='VOLUME:.metadata.name,CLAIM:.spec.claimRef.namespace,NAME:.spec.claimRef.name,NODE:.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]'
```

**Question:** which claims are tied to node3? What can a pod that uses one
of them do while node3 is out of service?

### 3. What protects applications during a drain?

```bash
$ kubectl get poddisruptionbudgets -A
```

A PodDisruptionBudget (PDB) tells Kubernetes how many pods of an application
may be taken away **on purpose** at the same time. A drain respects it; a
crash does not.

**Questions:**

- Who created the budget in the namespace `kafka`? (You did not.)
- Which of your stateful services have **no** budget? What does that mean
  for a drain?

---

## Operate

### 4. Take node3 out of service

Open a second terminal and leave this running until step 6:

<!-- smoke: skip (watch) -->
```bash
$ kubectl get nodes -w
```

**Cordon** first: no new pods are placed on the node, running pods stay.

<!-- smoke: disruptive -->
```bash
$ kubectl cordon "$N3"
$ kubectl get nodes
```

Then **drain**: the pods are asked to leave, politely and in order.

<!-- smoke: disruptive -->
```bash
$ kubectl drain "$N3" --ignore-daemonsets --delete-emptydir-data --timeout=300s
$ kubectl get pods -A -o wide --field-selector spec.nodeName="$N3"
$ kubectl get pods -A --field-selector status.phase=Pending
```

| Flag | Why it is needed |
|---|---|
| `--ignore-daemonsets` | DaemonSet pods cannot be moved; without the flag the drain refuses to start |
| `--delete-emptydir-data` | Pods with scratch space (`emptyDir`) lose it; you confirm that is acceptable |
| `--timeout` | Give up instead of waiting for ever on a pod that a budget protects |

**Questions:**

- Only DaemonSet pods are left on node3. Where did the others go?
- Some pods are now `Pending`. Run `kubectl describe pod` on one of them
  and read the Events. Why can it not start on another node?
- ⚠️ This is the price of local-path storage. What would be different
  with storage that is replicated across nodes?

### 5. Do the maintenance

The node is empty, so now it is safe to patch it, change hardware, or, as
here, reboot it:

<!-- smoke: disruptive -->
```bash
$ ssh node3 "sudo reboot" || echo "(the connection closes: that is the reboot)"
$ sleep 90
$ kubectl wait --for=condition=Ready "node/$N3" --timeout=300s
$ kubectl get nodes
```

The node is `Ready` again but still says `SchedulingDisabled`: a cordon
survives a reboot. Nothing comes back by itself.

### 6. Put it back in service

<!-- smoke: disruptive -->
```bash
$ kubectl uncordon "$N3"
$ kubectl get pods -A --field-selector status.phase=Pending
$ infra/platform/vault/init-unseal.sh
$ infra/platform/verify.sh --wait 300
```

`init-unseal.sh` does nothing if Vault is unsealed. If `vault-0` lived on
node3, it has restarted, and a restarted Vault is sealed (lab 8).

> **Note: a drain can remove a webhook.** The Vault Agent Injector is a
> webhook: it adds the `vault-agent` container while a pod is being
> **created**. A drain recreates many pods at once. If the only injector pod
> was on the drained node, pods created in those seconds are admitted
> **without** the agent, and they never get it later. This happened while
> this course was being written: `redis-0` came back without its password
> file and ran with no password. The replica and the demo app were then
> refused (`AUTH ... called without any password configured`). This
> platform now runs two injector replicas with a PodDisruptionBudget,
> `redis-0` refuses to start without its password file, and `verify.sh`
> checks that Redis requires a password. Spot it yourself: an injected pod
> lists a `vault-agent` container in
> `kubectl get pod <pod> -o jsonpath='{.spec.containers[*].name}'`. The
> repair is to delete the pod, so that it is created again while the
> injector is up. Before maintenance, ask of every webhook in
> `kubectl get mutatingwebhookconfigurations`: does it survive losing one
> node?

**Questions:**

- The `Pending` pods started as soon as the node was schedulable again.
  Did the pods that had moved to other nodes come **back** to node3? Why
  not?
- Which service was unavailable during your maintenance, and for how long?
  How would you have announced it?

Stop the watch in the second terminal with `Ctrl-C`.

### 7. Add a fourth node

node4 is prepared but not part of the cluster. Its address is on your desk
card and in the inventory, in the group `[spare]`:

<!-- smoke: skip (needs the spare node and an edit of the inventory) -->
```bash
$ kubectl get nodes
$ grep -n -A3 'spare' infra/ansible/inventory/hosts.ini
$ nano infra/ansible/inventory/hosts.ini
```

In the editor, **move** the `node4 …` line from under `[spare]` to under
`[rke2_agents]` (remove a leading `#` if there is one), then save. Check
what Ansible now sees, and add the node:

<!-- smoke: skip (needs the spare node and an edit of the inventory) -->
```bash
$ ansible-inventory --graph
$ cat infra/ansible/playbooks/add-node.yml
$ ansible-playbook infra/ansible/playbooks/add-node.yml -e new_node=node4
$ kubectl get nodes -o wide
$ infra/scripts/lab-info.sh --ssh-config
$ N4=$(ssh node4 hostname)
$ kubectl get pods -A -o wide --field-selector spec.nodeName="$N4"
```

**Questions:**

- The playbook has four plays. What does each do, and why is the last one
  run on the **old** nodes?
- Run the playbook a second time. What does the `PLAY RECAP` line say
  under `changed`, and what is that property called?
- Only DaemonSet pods run on node4. Nobody moved Grafana or Redis there.
  Why not?

### 8. Use the new node

New pods are placed where there is room, so node4 gets its share from now
on:

<!-- smoke: skip (needs the spare node) -->
```bash
$ kubectl create namespace lab12
$ kubectl -n lab12 create deployment spread --image=docker.io/library/nginx:1.27-alpine --replicas=8
$ kubectl -n lab12 rollout status deployment/spread --timeout=180s
$ kubectl -n lab12 get pods -o custom-columns=NODE:.spec.nodeName --no-headers | sort | uniq -c
$ kubectl delete namespace lab12
$ infra/platform/verify.sh
```

---

## Checkpoint ✅

- [ ] You can say which pods on a node move during a drain, which stay,
  and which get stuck
- [ ] You cordoned, drained, rebooted and uncordoned node3
- [ ] You know why a rebooted Vault needs attention
- [ ] node4 is `Ready` in `kubectl get nodes`
- [ ] `verify.sh` ends with `0 failed`

## If you're stuck

- The drain hangs on one pod: a PodDisruptionBudget is protecting it. Stop
  with `Ctrl-C`, look at `kubectl get pdb -A`, wait until the application
  is healthy again, and repeat the drain.
- node3 does not come back after the reboot: wait three minutes, then
  `ssh node3 sudo systemctl status rke2-agent`. Tell the instructor if
  `ssh` itself fails.
- You forgot the uncordon: `kubectl get nodes` shows `SchedulingDisabled`.
  `kubectl uncordon <node-name>`.
- `add-node.yml` stops with "list that host under [rke2_agents] first":
  the inventory edit is not saved, or node4 is still commented out.
- Pods stay `Pending` after the uncordon, or `verify.sh` stays red:
  `infra/platform/deploy.sh all`, then `infra/platform/verify.sh --wait 300`.

## ★ Stretch

- **Remove a node again.** Drain node4, then `kubectl delete node "$N4"`,
  then on the node `sudo /usr/local/bin/rke2-uninstall.sh`, and move its
  line back to `[spare]` in the inventory. In which order would things go
  wrong if you skipped the drain?
- **A budget of your own.** Before step 8's clean-up:
  `kubectl -n lab12 create poddisruptionbudget spread --selector=app=spread --min-available=7`,
  then drain the node with the most `spread` pods. What does the drain
  print, and how long does it take?
- **Taints.** `kubectl taint node "$N4" maintenance=true:NoSchedule`, then
  scale `spread` up. Which pods still land on node4? Remove the taint with
  the same command and a trailing `-`.
- **What Ansible did on node4.** `ssh node4 "sudo cat /etc/rancher/rke2/config.yaml"`
  (⚠️ it contains the join token) and
  `cat infra/ansible/roles/rke2_agent/tasks/main.yml`. Compare with what
  you typed by hand in lab 2.
