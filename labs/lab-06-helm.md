# Lab 6 — Helm: inspect, change, upgrade and roll back

Two parts, each with its own checkpoint:

- **Part A — Inspect the platform's releases.** 15 min, follow along with the
  instructor. **You will:** list every Helm release, find out who installed
  it, and read its values, history and objects.
- **Part B — Change, upgrade and roll back a chart.** 30 min, on your own.
  **You will:** read the in-house `redis-lab` chart, install a throw-away
  Redis, find its volume, upgrade it, break it, roll it back, and see what an
  uninstall leaves behind.

`$` = workstation · `<something>` = your own value · ★ = optional

> **Bare start?** Do **★ Build** at the end of this guide **first** (10
> minutes): you install the storage provisioner with Helm. Then do parts A
> and B like everyone else.

---

## Part A — Inspect the platform's releases

### A1. Every release in the cluster

```bash
$ cd "$K8S_COURSE_HOME"
$ helm list -A
```

**Questions:**

- Which releases start with `rke2-`? Who installed those (think back to the
  RKE2 slides)?
- Find the columns CHART and APP VERSION. What is the difference?

### A2. One release in detail

The storage provisioner is a small release, so it is easy to read:

```bash
$ helm -n local-path-storage status local-path-provisioner
$ helm -n local-path-storage get values local-path-provisioner
$ helm -n local-path-storage history local-path-provisioner
```

Compare the values with the file they came from:

```bash
$ cat infra/platform/storage/local-path-values.yaml
```

**Question:** `get values` shows only a few lines, yet the chart has many
more settings. Where do the others come from? (Try `get values --all`.)

### A3. Which objects belong to a release?

```bash
$ helm -n local-path-storage get manifest local-path-provisioner | grep '^kind:' | sort | uniq -c
$ kubectl -n local-path-storage get all
$ kubectl get storageclass
```

### A4. Where Helm keeps its records

```bash
$ kubectl -n local-path-storage get secrets -l owner=helm
```

One Secret per revision. That is all Helm leaves in the cluster.

### A5. The charts RKE2 manages

```bash
$ helm -n kube-system list
$ helm -n kube-system get values rke2-cilium
$ kubectl -n kube-system get helmcharts,helmchartconfigs
```

**Question:** `helm` can see these releases. Why should you still not run
`helm upgrade` on them?

### Checkpoint A ✅

- [ ] You can list every release and say which ones RKE2 owns
- [ ] You found the values, the history and the objects of one release
- [ ] You know where Helm stores a release's history

---

## Part B — Change, upgrade and roll back a chart

You work with a **copy** of Redis in the namespace `lab6`. The platform's own
Redis (if your cluster has one) is not touched.

### B1. Read the chart

```bash
$ ls infra/charts/redis-lab infra/charts/redis-lab/templates
$ cat infra/charts/redis-lab/Chart.yaml
$ helm show values infra/charts/redis-lab
$ helm lint infra/charts/redis-lab
```

In the values find: how many replicas, which image, how big the volume is.

### B2. Render it without installing

```bash
$ cat labs/files/lab-06/values-scratch.yaml
$ helm template scratch infra/charts/redis-lab -n lab6 -f labs/files/lab-06/values-scratch.yaml | grep -E '^kind:|^  name:'
```

`helm template` only prints YAML. It is the safe way to see what an install
or upgrade would create.

### B3. Install it

```bash
$ helm upgrade --install scratch infra/charts/redis-lab -n lab6 --create-namespace -f labs/files/lab-06/values-scratch.yaml
$ kubectl -n lab6 rollout status statefulset/scratch --timeout=180s
$ helm -n lab6 list
$ kubectl -n lab6 get pods,pvc
$ kubectl get pv
```

**Questions:**

- The pod is called `scratch-0`, not `scratch-7c9f-abcde`. Which kind of
  controller owns it?
- Find the PersistentVolume that belongs to the claim `data-scratch-0`. What
  is its reclaim policy?

Store something in it:

```bash
$ kubectl -n lab6 exec scratch-0 -c redis -- sh -c '. /scripts/password.sh; redis-cli set course "helm"'
$ kubectl -n lab6 exec scratch-0 -c redis -- sh -c '. /scripts/password.sh; redis-cli get course'
```

### B4. Upgrade: add a replica

```bash
$ helm upgrade --install scratch infra/charts/redis-lab -n lab6 -f labs/files/lab-06/values-scratch.yaml --set replicas=2
$ kubectl -n lab6 rollout status statefulset/scratch --timeout=180s
$ helm -n lab6 history scratch
$ kubectl -n lab6 get pods,pvc
$ kubectl -n lab6 exec scratch-1 -c redis -- sh -c '. /scripts/password.sh; redis-cli get course'
```

**Questions:**

- `scratch-1` has its own claim. Did you create it?
- The key you stored on `scratch-0` can be read on `scratch-1`. How did it
  get there?

### B5. Break it with an upgrade

```bash
$ helm upgrade --install scratch infra/charts/redis-lab -n lab6 -f labs/files/lab-06/values-scratch.yaml --set replicas=2 --set image.tag=does-not-exist
$ helm -n lab6 history scratch
$ kubectl -n lab6 rollout status statefulset/scratch --timeout=30s || echo "THE ROLLOUT IS STUCK"
$ kubectl -n lab6 get pods
```

**Questions:**

- Helm says revision 3 is `deployed`. Is the application healthy? What does
  Helm's status actually tell you?
- Which pod did the StatefulSet try to update first? Is `scratch-0` still
  serving?

### B6. Roll back, and meet the StatefulSet that stays stuck

```bash
$ helm -n lab6 rollback scratch 2
$ helm -n lab6 history scratch
$ kubectl -n lab6 get pods
```

The release is back at the good settings, but `scratch-1` is **still**
broken. A StatefulSet does not replace a pod that never became Ready; it
waits for you. Delete the broken pod and it comes back with the corrected
settings:

```bash
$ kubectl -n lab6 delete pod scratch-1
$ kubectl -n lab6 rollout status statefulset/scratch --timeout=180s
$ kubectl -n lab6 get pods
$ kubectl -n lab6 exec scratch-0 -c redis -- sh -c '. /scripts/password.sh; redis-cli get course'
```

> ⚠️ This happened for real while this platform was being built: Keycloak's
> database stayed down after its settings had been corrected. It is a known
> Kubernetes limitation, and one of the faults you may meet in lab 14.

**Question:** a Deployment in the same situation would have recovered by
itself after the rollback. What is different about a StatefulSet?

### B7. Uninstall, and see what is left

```bash
$ helm -n lab6 uninstall scratch
$ kubectl -n lab6 get pods,pvc
```

**Question:** the pods are gone but the claims are still there. Is that a
bug or a feature? What would happen if you installed `scratch` again now?

Remove everything, claims and data included:

```bash
$ kubectl delete namespace lab6
```

### Checkpoint B ✅

- [ ] You rendered a chart with `helm template` before installing it
- [ ] `helm history` showed four revisions: install, upgrade, broken upgrade, rollback
- [ ] You can explain why Helm said `deployed` while a pod was broken
- [ ] You unstuck the StatefulSet by deleting the broken pod
- [ ] The namespace `lab6` is gone

## If you're stuck

- `scratch-0` stays `Pending`: `kubectl -n lab6 describe pvc data-scratch-0`.
  If there is no StorageClass, the storage layer is missing:
  `infra/platform/deploy.sh storage`.
- Start part B again: `helm -n lab6 uninstall scratch`, then
  `kubectl delete namespace lab6`, wait until it is gone, repeat from B3.
- The platform itself looks unhealthy: `infra/platform/verify.sh`.

---

## ★ Build — install the storage provisioner with Helm (bare start)

Do this part **first**. 10 minutes. It uses the same chart version and the
same values file as `infra/platform/deploy.sh storage`.

```bash
$ cd "$K8S_COURSE_HOME"
$ source infra/versions.env
$ echo "$REPO_LOCAL_PATH  chart version $CHART_LOCAL_PATH"
$ helm repo add containeroo "$REPO_LOCAL_PATH"
$ helm repo update
$ cat infra/platform/storage/local-path-values.yaml
$ helm upgrade --install local-path-provisioner containeroo/local-path-provisioner -n local-path-storage --create-namespace --version "$CHART_LOCAL_PATH" -f infra/platform/storage/local-path-values.yaml --wait
```

Check it:

```bash
$ kubectl -n local-path-storage get pods
$ kubectl get storageclass
$ infra/platform/verify.sh
```

**Question:** which line in the values file makes this the **default**
StorageClass, and why does that matter for every chart you install later?

### Build checkpoint ✅

- [ ] `kubectl get storageclass` shows `local-path (default)`
- [ ] `verify.sh` shows the Storage line green and ends with `0 failed`

---

## ★ Stretch

- Change a **config** value instead of the image:
  add `--set config="maxmemory 64mb"` to the upgrade in B4 and watch the
  pods. The chart restarts them because of a checksum annotation; find it
  with `helm template … | grep checksum`.
- `helm -n lab6 get values scratch --revision 2` against `--revision 3`:
  what exactly differed?
- `helm -n lab6 get manifest scratch | less`: find the readiness probe of the
  Redis container. What does it run?
- On a full cluster: `helm -n monitoring history kube-prometheus-stack`. Why
  does it have more than one revision? (Hint: Grafana single sign-on.)
