# Example 15 — Service (ExternalName): a DNS alias

**Shows:** an ExternalName Service is only a DNS alias (a CNAME): no IP, no
pods, no ports. Clients keep using one name while you point it somewhere
else.

**Objects:** two Deployments with Services, two ExternalName Services, a client pod · **Namespace:** `ex-externalname` · **About 5 minutes**

`$` = workstation · [All examples](../README.md)

![The client looks up backend; CoreDNS answers with a CNAME to old-db, and later, after one patch, to new-db; the client's configuration never changes](diagram.svg)

## Apply

```bash
$ cd "$K8S_COURSE_HOME"
$ cat examples/15-service-externalname/service.yaml
$ kubectl apply -f examples/15-service-externalname/service.yaml
$ kubectl -n ex-externalname rollout status deployment/old-db --timeout=120s
$ kubectl -n ex-externalname rollout status deployment/new-db --timeout=120s
$ kubectl -n ex-externalname wait --for=condition=Ready pod/client --timeout=120s
```

## Look at it

```bash
$ kubectl -n ex-externalname get services
$ kubectl -n ex-externalname get endpointslices
```

`backend` and `docs` have no `CLUSTER-IP` and no EndpointSlice;
their `EXTERNAL-IP` column shows the name they point to.

Ask DNS:

```bash
$ kubectl -n ex-externalname exec client -- nslookup backend.ex-externalname.svc.cluster.local
$ kubectl -n ex-externalname exec client -- nslookup docs.ex-externalname.svc.cluster.local
```

The answers start with `canonical name = ...`: CoreDNS returns the alias, and
the client looks that name up in turn. A client that uses `backend` reaches
the old backend:

```bash
$ kubectl -n ex-externalname exec client -- wget -qO- http://backend/api/info | grep message
```

## Try this

**Move the clients to the new backend** with one change, and no change to
the clients:

```bash
$ kubectl -n ex-externalname patch service backend -p '{"spec":{"externalName":"new-db.ex-externalname.svc.cluster.local"}}'
$ sleep 35
$ kubectl -n ex-externalname exec client -- wget -qO- http://backend/api/info | grep message
```

The wait is for DNS caching: CoreDNS keeps an answer for up to 30 seconds,
so for a short while after a change some clients still get the old alias.

## What to remember

- ExternalName = a CNAME in cluster DNS. Kubernetes does no load balancing,
  port mapping or health checking for it.
- Good for: giving an external database or API a cluster-local name, or
  moving clients between services with one change.
- Watch out for HTTPS and virtual hosts: the client still sends the name it
  used (`backend`) in the `Host` header and for TLS, and the far end may
  reject it. That is why `docs` (kubernetes.io) is only looked up here, not
  called.

## Clean up

```bash
$ kubectl delete namespace ex-externalname
```
