# Part 2 cheat sheet — Workloads, networking, storage, Helm

`$` = workstation · `<ns>` = namespace

## Workloads

| Kind | Guarantees | On our platform |
|---|---|---|
| Deployment | N interchangeable pods, rolling updates | Grafana, CoreDNS, operators |
| DaemonSet | One pod on every node | Cilium, Traefik, Fluent Bit |
| StatefulSet | Fixed names, one volume per pod, ordered updates | Redis, Vault, PostgreSQL, Prometheus |
| Job / CronJob | Run to completion / on a schedule | Helm install jobs, backups |

```bash
$ kubectl -n <ns> get deployments,statefulsets,daemonsets        # READY 3/3 ?
$ kubectl -n <ns> rollout status deployment/<name>               # finished, or stuck?
$ kubectl -n <ns> rollout history deployment/<name>
$ kubectl -n <ns> rollout undo deployment/<name>                 # back one revision
$ kubectl -n <ns> rollout restart deployment/<name>              # new pods, same version
$ kubectl -n <ns> scale deployment/<name> --replicas=5
```

| You see | It means | Look at |
|---|---|---|
| `ImagePullBackOff` | Image name or tag wrong, registry refuses | `describe pod` → Events |
| `Running`, READY `0/1` | Readiness probe fails: no traffic is sent to it | `describe pod` → Events |
| RESTARTS growing | Liveness probe fails, or the process crashes | `logs --previous` |
| `OOMKilled` | Over its memory **limit** | `describe pod` → Last State |
| `Pending` | No node has enough **unrequested** CPU or memory, or the volume is not ready | `describe pod` → Events |
| StatefulSet stuck after a fix | A pod that never became Ready is not replaced | Fix the spec **and** delete that pod |

Request = guaranteed, used by the scheduler. Limit = ceiling: CPU is throttled, memory is OOMKilled.

## Configuration

| Reaches the pod as | After the ConfigMap or Secret changes |
|---|---|
| Environment variable | Nothing, until the pod is replaced |
| Mounted file | Updated within about a minute; the app must re-read it |
| Mounted with `subPath` | Never, until the pod is replaced |

Apply a config change reliably: `kubectl -n <ns> rollout restart deployment/<name>`

A Secret is base64, not encryption: `kubectl -n <ns> get secret <name> -o jsonpath='{.data.<key>}' | base64 -d`

## Networking

| Range | Used for |
|---|---|
| `10.42.0.0/16` | Pod IPs |
| `10.43.0.0/16` | Service IPs (ClusterIP) |

Service DNS name: `<service>.<namespace>.svc.cluster.local`

```bash
$ kubectl -n <ns> get services,endpointslices        # no endpoints = selector matches no Ready pod
$ kubectl -n <ns> exec <pod> -- nslookup <service>.<ns>.svc.cluster.local
$ kubectl get ingress -A                             # every web UI
$ kubectl -n kube-system logs daemonset/rke2-traefik --tail=20
$ cilium status
```

Request from outside: browser → node port 80 → **Traefik** → Ingress rule → **Service** → a Ready **pod**.

## Network policy

- A pod no policy selects accepts everything
- Once a policy selects it, only what is explicitly allowed gets through
- Default deny = a policy with `podSelector: {}` and no rules
- Deny egress → remember to allow **DNS** (UDP and TCP 53 to `k8s-app=kube-dns` in `kube-system`)

```bash
$ kubectl -n <ns> get networkpolicies,ciliumnetworkpolicies
$ cilium hubble port-forward &
$ hubble observe --namespace <ns> --last 20
$ hubble observe --namespace <ns> --verdict DROPPED
```

## Storage

Pod → **PersistentVolumeClaim** (the request) → **PersistentVolume** (the volume) ← made by the **StorageClass**'s provisioner.

```bash
$ kubectl get storageclass
$ kubectl get pvc -A
$ kubectl get pv
$ kubectl -n <ns> describe pvc <name>                # why is it Pending?
```

| Symptom | Likely cause |
|---|---|
| PVC `Pending` | No default StorageClass, or provisioner down ("waiting for first consumer" is normal) |
| Pod `Pending`, volume node affinity conflict | Its volume is on a node that is down or cordoned (local-path ⚠️) |
| Old data after a re-install | StatefulSet claims are kept on uninstall |

## Helm

```bash
$ helm list -A                                           # every release
$ helm -n <ns> status <release>
$ helm -n <ns> get values <release>                      # what we set (--all: with defaults)
$ helm -n <ns> get manifest <release>                    # the objects it owns
$ helm -n <ns> history <release>
$ helm template <release> <chart> -f values.yaml         # render only, change nothing
$ helm upgrade --install <release> <chart> -n <ns> -f values.yaml
$ helm -n <ns> rollback <release> <revision>
$ helm -n <ns> uninstall <release>
```

- Values: chart defaults < each `-f` file < each `--set`. Keep them in files in git
- `deployed` means the API accepted the objects, **not** that the pods are healthy: check the pods
- `rke2-*` releases belong to RKE2: change them with a `HelmChartConfig`, never with `helm upgrade`
