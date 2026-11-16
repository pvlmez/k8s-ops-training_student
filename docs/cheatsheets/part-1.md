# Part 1 cheat sheet — Kubernetes foundations and RKE2

`$` = workstation · `node1$` = on a node

## Where am I, and is it healthy?

| Question | Command |
|---|---|
| Which cluster am I talking to? | `kubectl config current-context` |
| Are all nodes there? | `kubectl get nodes -o wide` |
| Is the API server healthy? | `kubectl get --raw='/readyz?verbose'` |
| Is anything not running? | `kubectl get pods -A --field-selector status.phase!=Running` |
| Is the whole platform healthy? | `infra/platform/verify.sh` (after a restart: `--wait 180`) |
| My nodes and web UI addresses | `infra/scripts/lab-info.sh` |

## Finding things

| I want | Command |
|---|---|
| All pods, with node and IP | `kubectl get pods -A -o wide` |
| Pods in one namespace | `kubectl get pods -n <namespace>` |
| Pods by label | `kubectl get pods -A -l <key>=<value>` |
| What owns the pods | `kubectl get deployments,daemonsets,statefulsets -A` |
| Everything about one object | `kubectl get <kind> <name> -o yaml` |
| What a field means | `kubectl explain <kind>.<field>` |
| Usage right now | `kubectl top nodes`, `kubectl top pods -A` |

## What is wrong with it?

Work in this order: **get** (what state?) → **describe** (why?) → **logs** (what does it say?).

```bash
$ kubectl -n <namespace> get pods
$ kubectl -n <namespace> describe pod <pod>          # read the Events at the bottom
$ kubectl -n <namespace> logs <pod>                  # add --previous after a crash, -c <container> to pick one
$ kubectl -n <namespace> get events --sort-by=.lastTimestamp
```

| Pod STATUS | Usually means | Look at |
|---|---|---|
| `Pending` | No node fits, or its volume is not ready | `describe pod` → Events |
| `ContainerCreating` | Pulling the image, mounting volumes, waiting for an IP | `describe pod` |
| `ImagePullBackOff` | Wrong image name or tag, or the registry refuses | `describe pod` |
| `CrashLoopBackOff` | Starts, exits, is restarted, again and again | `logs --previous` |
| `Running` but `0/1` READY | Readiness probe fails; it gets no traffic | `describe pod`, `logs` |
| `OOMKilled` (last state) | Hit its memory limit | `describe pod` |
| `Terminating`, stuck | A finalizer, or the node is unreachable | `get pod -o yaml` |

## The control plane

| Component | Job | If it is down |
|---|---|---|
| kube-apiserver | Front door to the cluster | No changes possible; running pods keep running |
| etcd | Stores all cluster state | The API fails |
| kube-scheduler | Picks a node for new pods | New pods stay `Pending` |
| kube-controller-manager | Runs the reconcile loops | Nothing self-heals |
| kubelet (every node) | Runs the containers, reports status | Node goes `NotReady`; containers keep running |

They run on node1 as **static pods**: `kubectl -n kube-system get pods -o wide`

## On an RKE2 node

| What | Where |
|---|---|
| Service | `systemctl status rke2-server` (node1) · `rke2-agent` (other nodes) |
| Service log | `sudo journalctl -u rke2-server` · `-u rke2-agent` |
| Config | `/etc/rancher/rke2/config.yaml` (contains the join token) |
| Static pod manifests | `/var/lib/rancher/rke2/agent/pod-manifests/` (server) |
| Add-ons RKE2 applies itself | `/var/lib/rancher/rke2/server/manifests/` (server) |
| kubelet log | `/var/lib/rancher/rke2/agent/logs/kubelet.log` |
| Container logs | `/var/log/pods/` |
| etcd snapshots | `/var/lib/rancher/rke2/server/db/snapshots/` (server) |

```bash
node1$ sudo -i crictl ps                 # running containers
node1$ sudo -i crictl pods               # pods on this node
node1$ sudo -i crictl logs <container-id>
node1$ sudo -i crictl images
```

Stopping `rke2-agent` stops the kubelet, not the containers. The node shows
`NotReady` within a minute; after 5 minutes Kubernetes starts replacing its pods.

## Where things live in our cluster

| Namespace | What runs there |
|---|---|
| `kube-system` | Control plane, Cilium, Hubble, CoreDNS, Traefik, metrics-server |
| `local-path-storage` | Storage provisioner (lab only) |
| `monitoring` | Prometheus, Alertmanager, Grafana |
| `logging` | Loki, Fluent Bit |
| `vault` | Vault, Agent Injector |
| `keycloak` | Keycloak Operator, Keycloak, PostgreSQL |
| `redis` | Redis |
| `kafka` | Strimzi operator, Kafka |

## k9s

`:pods` `:deploy` `:nodes` switch view · `0` all namespaces · `/` filter ·
`d` describe · `l` logs · `s` shell · `y` YAML · `Esc` back · `?` help · `:q` quit
