# Lab 3 — Exploring a cluster

**Time:** 45 min · **Mode:** on your own · **You will:** read a
node, work out what runs where and what owns it, watch a Deployment turn into
pods, see a pod replaced, and find a pod's process and IP address from the
node itself.

`$` = workstation · `node1$` = on node1 (`ssh node1` first) · `<something>` =
your own value · ★ = optional

Both tracks (full and bare) do this lab the same way. On a bare cluster you
will simply see fewer namespaces.

---

## Explore

### 1. Read a node

```bash
$ kubectl get nodes -o wide
$ kubectl describe node "$(kubectl get nodes -o jsonpath='{.items[1].metadata.name}')"
```

The second command describes one of your nodes. In its output find:

- **Conditions**: `MemoryPressure`, `DiskPressure`, `PIDPressure`, `Ready`
- **Capacity** and **Allocatable**
- **Non-terminated Pods**: what runs on this node
- **Allocated resources**: how much CPU and memory is already promised

```bash
$ kubectl top nodes
```

**Questions:**

- Why is Allocatable lower than Capacity?
- "Allocated resources" shows *requests*; `kubectl top` shows *usage*. Which
  one does the scheduler look at when it places a pod?

### 2. What runs where?

```bash
$ kubectl get namespaces
$ kubectl get pods -A -o wide
```

Count the pods per namespace, then per node:

```bash
$ kubectl get pods -A --no-headers -o custom-columns=NS:.metadata.namespace | sort | uniq -c
$ kubectl get pods -A --no-headers -o custom-columns=NODE:.spec.nodeName | sort | uniq -c
```

**Question:** is the load spread evenly over your nodes? Which node carries
the control plane as well?

### 3. Who owns it?

A pod is almost never created by hand. Something owns it and will recreate it.

```bash
$ kubectl get daemonsets -A
$ kubectl get deployments -A
$ kubectl get statefulsets -A
```

Fill in the table for your cluster (the first row is done):

| Component | Namespace | Kind | How many pods, and why |
|---|---|---|---|
| Cilium agent | `kube-system` | DaemonSet | one per node: every node needs pod networking |
| Traefik | | | |
| CoreDNS | | | |
| Hubble relay | | | |
| metrics-server | | | |

**Question:** a DaemonSet has no `replicas` setting. What decides how many
pods it runs?

---

## Operate

### 4. Watch a Deployment become pods

```bash
$ kubectl create namespace lab3
```

Terminal 1, watch the events (leave it running until step 7):

<!-- smoke: skip (watch) -->
```bash
$ kubectl -n lab3 get events -w
```

Terminal 2:

```bash
$ kubectl -n lab3 create deployment web --image=docker.io/library/nginx:1.27-alpine --replicas=3
$ kubectl -n lab3 rollout status deployment/web --timeout=120s
$ kubectl -n lab3 get deployments,replicasets,pods -o wide
```

In terminal 1, find the events for each step from the "Life of a pod" slide:
ReplicaSet created → pods created → **Scheduled** (to which node?) →
**Pulling** → **Started**.

**Question:** which component wrote the `Scheduled` events? Which one wrote
`Pulling` and `Started`?

### 5. Self-healing

Delete one of the three pods and look again straight away:

```bash
$ kubectl -n lab3 delete "$(kubectl -n lab3 get pods -o name | sort | sed -n 1p)"
$ kubectl -n lab3 get pods -o wide
```

Then scale up and down:

```bash
$ kubectl -n lab3 scale deployment web --replicas=5
$ kubectl -n lab3 get pods -o wide
$ kubectl -n lab3 scale deployment web --replicas=3
$ kubectl -n lab3 rollout status deployment/web --timeout=120s
```

**Questions:**

- Which controller made the replacement pod, and how did it know one was
  missing?
- When you scaled down to 3, who decided which two pods to remove?

### 6. Find the pod on the node

A pod is ordinary Linux processes on a node. Pick one `web` pod and note its
**NODE** and **IP**:

```bash
$ kubectl -n lab3 get pods -o wide
$ infra/scripts/lab-info.sh
```

`lab-info.sh` tells you which of node1, node2, node3 has that Kubernetes node
name. Log in to that node (the examples use node2):

<!-- smoke: skip (depends on which node your pod landed on) -->
```bash
$ ssh node2
node2$ sudo -i crictl ps --name nginx
node2$ ps -ef | grep '[n]ginx: master'
```

Take the PID of the nginx master process (second column) and look at it from
the node's side:

<!-- smoke: skip (needs your PID) -->
```bash
node2$ sudo cat /proc/<pid>/cgroup
node2$ sudo nsenter -t <pid> -n ip addr
```

**Questions:**

- Compare the IP address that `nsenter` shows with the pod's IP in
  `kubectl get pods -o wide`. What did `-n` do?
- From the `cgroup` line: is this process limited as part of a pod?

### 7. Clean up

Stop the watch in terminal 1 with `Ctrl-C`, then:

```bash
$ kubectl delete namespace lab3
```

---

## Checkpoint ✅

- [ ] You can read a node's conditions and say whether it is under pressure
- [ ] You filled in the "who owns it" table
- [ ] You saw the scheduler place pods (`Scheduled` events)
- [ ] You can explain why deleting a pod does not reduce the number of replicas
- [ ] You found a pod's process and IP address from the node itself
- [ ] The namespace `lab3` is gone

## If you're stuck

- Pods in `lab3` stay `ContainerCreating` or `ImagePullBackOff`:
  `kubectl -n lab3 describe pod <pod-name>` and read the Events at the bottom.
  The node may not reach the image registry; tell the instructor.
- You cannot tell which node is which: `infra/scripts/lab-info.sh`.
- Start again: `kubectl delete namespace lab3`, then repeat from step 4.

## ★ Stretch

- `kubectl get --raw /metrics | grep -c apiserver_request_total`: the API
  server publishes its own metrics. Prometheus collects them; you query it in lab 7.
- `kubectl api-resources | wc -l`: how many kinds of object does this cluster
  know? Compare with a neighbour on the other track.
- `kubectl -n lab3 get pod <pod-name> -o yaml | less` (before you clean up):
  find `ownerReferences`, `nodeName` and `status.podIP`.
- In k9s, press `x` on a Deployment (`:deploy`) to see the tree of what it
  owns.
