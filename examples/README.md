# Appendix A — Kubernetes objects by example

Small, self-contained examples of the Kubernetes objects, one concept each.
Every example has a manifest you can read in a minute, a diagram, the few
commands that make the concept visible, one thing to try, and a clean-up.
Use them to see a concept on its own, away from the platform's moving parts:
before or after a lab, while reading a slide, or on a projector.

They do not depend on each other or on the labs, and they do not touch the
platform: each example lives in its own namespace, `ex-<name>`, and its last
step deletes that namespace.

## How to use an example

1. `cd "$K8S_COURSE_HOME"` and open the example's `README.md`.
2. Read the manifest (`cat`), then apply it.
3. Run the "Look at it" commands and read the notes under them.
4. Do "Try this": the part where something changes or breaks.
5. Clean up: `kubectl delete namespace ex-<name>`.

`$` = a command on your workstation; `node1$` = on that node (`ssh node1`
first). ⚠️ marks a shortcut that is fine here and wrong in production.

**On a projector**, split the terminal: commands in one pane, a watch in the
other (`kubectl -n ex-<name> get pods -w`, or k9s with `:ns` then the
namespace). The networking examples are good to follow in the Hubble UI;
podinfo's own web page (through a port-forward or an Ingress) shows its pod
name, version and colour.

## The examples

| # | Example | Objects | What you see |
|---|---|---|---|
| | **Workloads** | | |
| 01 | [Pod](01-pod/README.md) | Pod | IP, node, logs, exec; a crash restarts the container; a deleted pod is gone |
| 02 | [Init containers and sidecars](02-multi-container/README.md) | Pod, `emptyDir` | Containers sharing `localhost` and a volume; an init container that blocks the start |
| 03 | [Probes](03-probes/README.md) | Deployment, Service | Readiness takes a pod out of the Service; liveness restarts it |
| 04 | [Requests, limits, QoS](04-resources/README.md) | Pods | QoS classes; `OOMKilled`; `Pending` with `Insufficient cpu` |
| 05 | [ReplicaSet](05-replicaset/README.md) | ReplicaSet | A deleted pod comes back; a relabelled pod is let go |
| 06 | [Deployment](06-deployment/README.md) | Deployment, Service, Ingress | Blue to green rolling update, rollback, a stuck rollout |
| 07 | [DaemonSet](07-daemonset/README.md) | DaemonSet | One pod per node; a node selector |
| 08 | [StatefulSet](08-statefulset/README.md) | StatefulSet, headless Service, PVCs | Stable names and DNS; data that survives the pod |
| 09 | [Job](09-job/README.md) | Job | Completions and parallelism; `BackoffLimitExceeded` |
| 10 | [CronJob](10-cronjob/README.md) | CronJob | Scheduled Jobs, a run by hand, suspend |
| | **Networking** | | |
| 11 | [Service: ClusterIP](11-service-clusterip/README.md) | Service, EndpointSlice | Load spread over pods; DNS; an empty selector |
| 12 | [Service: headless](12-service-headless/README.md) | Service `clusterIP: None` | DNS returns the pod IPs |
| 13 | [Service: NodePort](13-service-nodeport/README.md) | Service `type: NodePort` | The same port on every node; `externalTrafficPolicy` |
| 14 | [Service: LoadBalancer](14-service-loadbalancer/README.md) | Service `type: LoadBalancer` | `EXTERNAL-IP <pending>`, and why |
| 15 | [Service: ExternalName](15-service-externalname/README.md) | Service `type: ExternalName` | A DNS alias; moving clients with one change |
| 16 | [Ingress](16-ingress/README.md) | Ingress | Two apps behind one entry point, routed by host name |
| 17 | [NetworkPolicy](17-networkpolicy/README.md) | NetworkPolicy | Default deny, then allow one client |
| | **Configuration** | | |
| 18 | [ConfigMap](18-configmap/README.md) | ConfigMap | Files follow a change, variables need a restart |
| 19 | [Secret](19-secret/README.md) | Secret | base64 is not encryption; `tmpfs`; who may read it |
| 20 | [Downward API](20-downward-api/README.md) | Pod fields as env and files | A pod that knows its name, node, IP and limits |
| | **Storage** | | |
| 21 | [Volumes](21-volumes/README.md) | `emptyDir`, PVC, PV, StorageClass | What survives a new pod; where the data lives |
| | **Operations** | | |
| 22 | [ResourceQuota and LimitRange](22-quota-limitrange/README.md) | ResourceQuota, LimitRange | Defaults filled in; pods refused over budget |
| 23 | [RBAC](23-rbac/README.md) | ServiceAccount, Role, RoleBinding | `auth can-i`; a `403` from inside a pod |
| 24 | [HorizontalPodAutoscaler](24-hpa/README.md) | HPA | Scale up under CPU load and back down |
| 25 | [PodDisruptionBudget](25-pdb/README.md) | PDB, Eviction | An eviction allowed, the next one refused |

## What they run

| Image | Used for |
|---|---|
| `ghcr.io/stefanprodan/podinfo:6.15.0` (and `6.14.1` as the "old" version in example 06) | The app in almost every example: a small web server made for demos |
| `docker.io/library/busybox:1.37` | Clients, init containers, sidecars, Jobs |

podinfo is useful because it reports on itself and can be told to misbehave:

| podinfo | Does |
|---|---|
| `GET /` (`curl`) or the web page (browser) | Pod name, version, colour and message |
| `GET /env`, `GET /configs` | Its environment variables; the files in its config directory |
| `POST /readyz/disable`, `/readyz/enable` | Fail or pass the readiness probe |
| `GET /panic` | Crash (exit code 255) |
| `POST /store`, `GET /store/<hash>` | Write a file to `/data`, read it back |
| `PODINFO_UI_COLOR`, `PODINFO_UI_MESSAGE` | Colour and message of its page |
| `PODINFO_UNHEALTHY=true` | Fail the liveness probe |
| `PODINFO_STRESS_CPU=1`, `PODINFO_STRESS_MEMORY=<MB>` | Burn CPU; take memory at start |

Every podinfo flag can be set as a `PODINFO_<FLAG>` environment variable.

Each pod requests 5–10m CPU and 8–32Mi memory, so an example uses a few
percent of one node. Only example 24 (the autoscaler) generates real load,
up to 0.8 CPU for a few minutes.

## If something does not work

- `ImagePullBackOff`: the node cannot reach `ghcr.io` or Docker Hub.
- An Ingress address answers `404` for a few seconds after it is created:
  Traefik has not picked up the rule yet. Wait and repeat.
- A namespace hangs in `Terminating`: something in it still has a finalizer.
  `kubectl get all -n ex-<name>` shows what is left.
- To reset an example, delete its namespace and start from "Apply".
