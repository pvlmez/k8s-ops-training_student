# Example 24 — HorizontalPodAutoscaler: scale on CPU

**Shows:** the HPA reads the pods' CPU use from metrics-server, compares it
with their CPU **request**, and changes the Deployment's replica count:
up under load, down again when the load is gone.

**Objects:** Deployment, HorizontalPodAutoscaler · **Namespace:** `ex-hpa` · **About 10 minutes**

`$` = workstation · [All examples](../README.md)

![metrics-server collects CPU use from the kubelets; the HPA compares the average with 80% of the request and sets the Deployment's replicas between 1 and 4](diagram.svg)

The load test keeps up to 4 pods busy at 0.2 CPU each (0.8 CPU in all) for
a few minutes. On a busy lab cluster, keep it short.

## Apply

```bash
$ cd "$K8S_COURSE_HOME"
$ cat examples/24-hpa/hpa.yaml
$ kubectl apply -f examples/24-hpa/hpa.yaml
$ kubectl -n ex-hpa rollout status deployment/podinfo --timeout=120s
```

## Look at it

The HPA needs a minute before it has its first measurement (`TARGETS`
shows `<unknown>` until then):

```bash
$ for i in $(seq 18); do kubectl -n ex-hpa get hpa podinfo --no-headers | grep -qv unknown && break; sleep 10; done
$ kubectl -n ex-hpa get hpa podinfo
$ kubectl -n ex-hpa top pods
```

`TARGETS` is about `cpu: 2%/80%`: an idle podinfo uses about 1m of its 50m
request. `REPLICAS 1`.

## Try this

**Add load.** With `PODINFO_STRESS_CPU=1` podinfo keeps one CPU core busy,
capped by the 200m limit, which is 400% of the request. Changing the
environment rolls out a new pod:

```bash
$ kubectl -n ex-hpa set env deployment/podinfo PODINFO_STRESS_CPU=1
```

Watch it scale (on a projector, run `kubectl -n ex-hpa get hpa -w` in a
second terminal instead):

```bash
$ for i in $(seq 24); do kubectl -n ex-hpa get hpa podinfo --no-headers; [ "$(kubectl -n ex-hpa get deployment podinfo -o jsonpath='{.spec.replicas}')" = 4 ] && break; sleep 10; done
$ kubectl -n ex-hpa get pods
$ kubectl -n ex-hpa describe hpa podinfo | tail -5
```

The arithmetic: 1 pod at 400% with a target of 80% needs 400 / 80 = 5 pods;
`maxReplicas` caps it at 4. The events say `New size: 4; reason: cpu
resource utilization (percentage of request) above target`.

**Remove the load.**

```bash
$ kubectl -n ex-hpa set env deployment/podinfo PODINFO_STRESS_CPU-
$ for i in $(seq 30); do kubectl -n ex-hpa get hpa podinfo --no-headers; [ "$(kubectl -n ex-hpa get deployment podinfo -o jsonpath='{.spec.replicas}')" = 1 ] && break; sleep 10; done
$ kubectl -n ex-hpa get pods
```

Back to 1, after the 30-second stabilization window. With the default
window (5 minutes) the HPA waits longer, so a short dip in load does not
make it scale down and up again.

## What to remember

- The HPA scales on use **relative to the request**. No CPU request, no
  CPU-based scaling (`TARGETS <unknown>`, and the events say why).
- It needs metrics-server (RKE2 installs it): if `kubectl top pods` fails,
  the HPA is blind too.
- Leave `replicas` out of a Deployment that has an HPA, or every `apply`
  resets the count.
- Scaling up adds pods; whether they fit is the scheduler's problem.
  `Pending` pods mean the cluster is full, and the HPA cannot fix that.

## Clean up

```bash
$ kubectl delete namespace ex-hpa
```
