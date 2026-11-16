# Lab 4 — Workloads: deploy, scale, roll out, break and roll back

Two parts, each with its own checkpoint:

- **Part A — Deploy and scale.** 20 min, follow along with the instructor.
  **You will:** deploy a small web server from a YAML file, see what
  Kubernetes creates from it, scale it, and read its logs and events.
- **Part B — Roll out, break and roll back.** 35 min, on your own.
  **You will:** roll out a new version, break it in two different ways, read
  the evidence, roll back, and change its configuration.

`$` = workstation · `<something>` = your own value · ★ = optional

Both tracks (full and bare) do this lab the same way. Everything happens in
the namespace `lab4`; the files are in `labs/files/lab-04/`.

---

## Part A — Deploy and scale

### A1. Read the file before you apply it

```bash
$ cd "$K8S_COURSE_HOME"
$ cat labs/files/lab-04/web.yaml
```

It describes three objects. Find:

- the **ConfigMap** with the web page
- the **Deployment**: how many replicas, which image, which probes, which
  requests and limits
- the **Service**: which label it selects

### A2. Apply it

```bash
$ kubectl create namespace lab4
$ kubectl -n lab4 apply -f labs/files/lab-04/web.yaml
$ kubectl -n lab4 rollout status deployment/web --timeout=120s
```

### A3. What did Kubernetes make of it?

```bash
$ kubectl -n lab4 get deployments,replicasets,pods -o wide
$ kubectl -n lab4 get pods --show-labels
$ kubectl -n lab4 get service web
$ kubectl -n lab4 get endpointslices
```

**Questions:**

- You wrote one Deployment. Which objects did Kubernetes create for it, and
  how can you tell from the names who owns what?
- The EndpointSlice lists three addresses. Whose addresses are they?

### A4. Call the web server

From inside the cluster, through the Service name:

```bash
$ kubectl -n lab4 exec deployment/web -- wget -qO- http://web
```

**Question:** `http://web` is not an address you typed anywhere. Who turned
the name into an IP address?

### A5. Scale it

```bash
$ kubectl -n lab4 scale deployment/web --replicas=5
$ kubectl -n lab4 rollout status deployment/web --timeout=120s
$ kubectl -n lab4 get pods -o wide
$ kubectl -n lab4 get endpointslices
$ kubectl -n lab4 scale deployment/web --replicas=3
$ kubectl -n lab4 rollout status deployment/web --timeout=120s
```

**Question:** did you have to tell the Service about the two extra pods?

### A6. Logs and events

```bash
$ kubectl -n lab4 logs -l app=web --tail=3 --prefix
$ kubectl -n lab4 get events --sort-by=.lastTimestamp
$ kubectl -n lab4 describe deployment web
```

In the `describe` output find **RollingUpdateStrategy** and the **Events**
that record the scaling you just did.

### Checkpoint A ✅

- [ ] `kubectl -n lab4 get deployment web` shows READY `3/3`
- [ ] The web page comes back when you call `http://web` from a pod
- [ ] You can explain Deployment → ReplicaSet → Pod
- [ ] You know where to find the events of a namespace

---

## Part B — Roll out, break and roll back

### B1. Roll out a new version

Change the image from nginx 1.27 to 1.28 and watch:

```bash
$ kubectl -n lab4 set image deployment/web nginx=docker.io/library/nginx:1.28-alpine
$ kubectl -n lab4 rollout status deployment/web --timeout=180s
$ kubectl -n lab4 get replicasets
$ kubectl -n lab4 rollout history deployment/web
```

**Questions:**

- There are now two ReplicaSets. How many pods does each have, and why is the
  old one still there?
- The file says `maxSurge: 1` and `maxUnavailable: 0`. What is the largest
  and the smallest number of pods that existed during the rollout?

### B2. Break it: an image that does not exist

```bash
$ kubectl -n lab4 set image deployment/web nginx=docker.io/library/nginx:0.0.0-does-not-exist
$ kubectl -n lab4 rollout status deployment/web --timeout=30s || echo "THE ROLLOUT IS STUCK"
$ kubectl -n lab4 get pods
```

One pod is in `ErrImagePull` or `ImagePullBackOff`. Find out why, as you
would at 03:00 without knowing what was changed:

```bash
$ kubectl -n lab4 describe "$(kubectl -n lab4 get pods -o name --field-selector=status.phase=Pending | sed -n 1p)"
$ kubectl -n lab4 get events --sort-by=.lastTimestamp
```

Is the web shop down?

```bash
$ kubectl -n lab4 get deployment web
$ kubectl -n lab4 exec deployment/web -- wget -qO- http://web
```

**Questions:**

- Which line in the Events tells you what is wrong?
- The page still comes back. Which setting in `web.yaml` protected you?

Roll back:

```bash
$ kubectl -n lab4 rollout undo deployment/web
$ kubectl -n lab4 rollout status deployment/web --timeout=120s
$ kubectl -n lab4 get pods
```

### B3. Break it: a readiness probe that can never succeed

```bash
$ cat labs/files/lab-04/patches/bad-probe.yaml
$ kubectl -n lab4 patch deployment web --patch-file labs/files/lab-04/patches/bad-probe.yaml
$ kubectl -n lab4 rollout status deployment/web --timeout=30s || echo "THE ROLLOUT IS STUCK"
$ kubectl -n lab4 get pods
```

This time the new pod is `Running`, but look at the READY column.

```bash
$ kubectl -n lab4 describe "$(kubectl -n lab4 get pods -o name --sort-by=.metadata.creationTimestamp | sed -n '$p')"
$ kubectl -n lab4 get endpointslices
```

**Questions:**

- The container runs, yet the pod is `0/1`. What do the Events say?
- Is the new pod's address in the EndpointSlice? What would a user notice?
- How does this failure look different from B2 in `kubectl get pods`?

Roll back:

```bash
$ kubectl -n lab4 rollout undo deployment/web
$ kubectl -n lab4 rollout status deployment/web --timeout=120s
```

### B4. Change the configuration

The page content comes from the ConfigMap `web-content`, mounted as a file.

```bash
$ kubectl -n lab4 apply -f labs/files/lab-04/patches/content-v2.yaml
$ kubectl -n lab4 exec deployment/web -- wget -qO- http://web
```

You probably still see version 1: the kubelet refreshes mounted files within
about a minute. Do not wait for it; replace the pods in a controlled way:

```bash
$ kubectl -n lab4 rollout restart deployment/web
$ kubectl -n lab4 rollout status deployment/web --timeout=120s
$ kubectl -n lab4 exec deployment/web -- wget -qO- http://web
```

**Question:** if the setting had been an environment variable instead of a
file, would waiting a minute have helped?

### B5. Clean up

```bash
$ kubectl delete namespace lab4
```

### Checkpoint B ✅

- [ ] You rolled out a new image and saw two ReplicaSets
- [ ] You can tell "image cannot be pulled" from "readiness probe fails" in
      `kubectl get pods`, and you know where the reason is written
- [ ] You rolled back twice with `rollout undo`
- [ ] The page showed "content version 2" after a `rollout restart`
- [ ] The namespace `lab4` is gone

## If you're stuck

- Start again from a clean state:
  `kubectl delete namespace lab4`, wait until it is gone, then repeat from A2.
- `rollout undo` went back to a broken version (it toggles between the last
  two): `kubectl -n lab4 apply -f labs/files/lab-04/web.yaml` restores the
  original.
- The platform itself looks unhealthy: `infra/platform/verify.sh`, and tell
  the instructor which line is red.

## ★ Stretch

- **Too little memory.** Before the clean-up in B5, apply
  `labs/files/lab-04/patches/tiny-memory.yaml` with `kubectl patch` as in B3.
  What status do the new pods get? Find the reason in `kubectl describe pod`
  under *Last State*, then roll back.
- `kubectl -n lab4 get pod <pod-name> -o jsonpath='{.status.qosClass}'`:
  what is this pod's QoS class, and what would make it `Guaranteed`?
- `kubectl -n lab4 rollout history deployment/web --revision=2`: what does a
  revision record?
- Open k9s, go to `:deploy` in `lab4`, and repeat B1 while watching the pods
  view (`:pods`).
