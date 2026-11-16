# Lab 5 — Networking: follow a request, then lock down a namespace

Two parts, each with its own checkpoint:

- **Part A — Follow a request with Hubble.** 20 min, follow along with the
  instructor. **You will:** deploy three small workloads, find the Service
  and its DNS name, publish it through Traefik, and watch the traffic in
  Hubble.
- **Part B — Lock down a namespace.** 35 min, on your own. **You will:**
  apply default-deny, allow one caller, then deny outgoing traffic, break
  DNS and repair it.

`$` = workstation · `<something>` = your own value · ★ = optional

Both tracks (full and bare) do this lab the same way. Everything happens in
the namespace `lab5`; the files are in `labs/files/lab-05/`.

---

## Part A — Follow a request with Hubble

### A1. Deploy the workloads

```bash
$ cd "$K8S_COURSE_HOME"
$ kubectl create namespace lab5
$ kubectl -n lab5 apply -f labs/files/lab-05/app.yaml
$ kubectl -n lab5 wait --for=condition=Available deployment --all --timeout=180s
$ kubectl -n lab5 get pods -o wide --show-labels
```

| Workload | Label | Role |
|---|---|---|
| `backend` | `app=backend` | The service we want to protect (2 pods) |
| `frontend` | `app=frontend` | Is supposed to call the backend |
| `intruder` | `app=intruder` | Has no business calling the backend |

### A2. The Service, its endpoints and its name

```bash
$ kubectl -n lab5 get service backend
$ kubectl -n lab5 get endpointslices
$ kubectl -n lab5 exec deployment/frontend -- nslookup backend.lab5.svc.cluster.local
$ kubectl -n lab5 exec deployment/frontend -- wget -qO- http://backend
```

**Questions:**

- Which address did `nslookup` return: a pod IP or the Service's CLUSTER-IP?
- The full DNS name is `<service>.<namespace>.svc.cluster.local`. The `wget`
  used only `backend`. Why does the short name work from a pod in `lab5`, and
  would it work from a pod in another namespace?

### A3. Publish the backend through Traefik

Your web UIs use names like `grafana.<node1-ip>.sslip.io`. Give the backend
one too. First put your node1 address in a variable:

```bash
$ IP=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' | sed -E 's#https?://([^:/]+).*#\1#')
$ echo "http://lab5.$IP.sslip.io"
$ kubectl -n lab5 create ingress backend --class=traefik --rule="lab5.$IP.sslip.io/*=backend:80"
$ kubectl -n lab5 get ingress
```

Call it from your workstation (if you get `404`, Traefik has not picked the
rule up yet: wait a few seconds and repeat):

```bash
$ curl -s -o /dev/null -w '%{http_code}\n' "http://lab5.$IP.sslip.io/"
```

You can open the same address in your browser.

**Question:** the request went workstation → node1 port 80 → ? → ? → pod.
Fill in the two question marks.

### A4. Watch it in Hubble

Open the **Hubble UI** (`infra/scripts/lab-info.sh` prints the address) and
choose the namespace `lab5`. Then create some traffic:

```bash
$ labs/files/lab-05/test.sh
$ curl -s -o /dev/null -w '%{http_code}\n' "http://lab5.$IP.sslip.io/"
```

`test.sh` calls the backend from the frontend and from the intruder and says
whether each call got through. Read it once: `cat labs/files/lab-05/test.sh`.

In the UI you should see `frontend` and `intruder` connected to `backend`,
and traffic arriving from outside the namespace.

The same on the command line. Terminal 2, connect the Hubble CLI and leave it
running:

<!-- smoke: skip (runs until stopped) -->
```bash
$ cilium hubble port-forward
```

Terminal 1:

<!-- smoke: skip (needs the port-forward from terminal 2) -->
```bash
$ hubble observe --namespace lab5 --last 20
$ hubble observe --namespace lab5 --to-label app=backend --last 10
```

**Questions:**

- Every line ends with a verdict. Which one do you see?
- Find a DNS lookup in the output. Which namespace does it go to?

### Checkpoint A ✅

- [ ] All pods in `lab5` are `Running` and READY
- [ ] The backend answers from the frontend **and** from your workstation
- [ ] You can see the flows in the Hubble UI
- [ ] `test.sh` reports ALLOWED twice and DNS WORKS

---

## Part B — Lock down a namespace

In this part the backend is for internal callers only. Remove the route from
outside first:

```bash
$ kubectl -n lab5 delete ingress backend
```

### B1. The starting point: everything is allowed

```bash
$ kubectl -n lab5 get networkpolicies
$ labs/files/lab-05/test.sh
```

No policies, and the intruder reaches the backend. That is the Kubernetes
default.

### B2. Default deny

```bash
$ cat labs/files/lab-05/1-default-deny-ingress.yaml
$ kubectl -n lab5 apply -f labs/files/lab-05/1-default-deny-ingress.yaml
$ labs/files/lab-05/test.sh
```

Both callers are now BLOCKED. Look in the Hubble UI (namespace `lab5`): the
blocked flows are drawn in red. On the command line:

<!-- smoke: skip (needs the port-forward from terminal 2) -->
```bash
$ hubble observe --namespace lab5 --verdict DROPPED --last 10
```

**Questions:**

- The policy has `podSelector: {}` and no `ingress:` rules. What does each of
  those two facts mean?
- What reason does Hubble give for the drops?

### B3. Allow the frontend, and only the frontend

```bash
$ cat labs/files/lab-05/2-allow-frontend.yaml
$ kubectl -n lab5 apply -f labs/files/lab-05/2-allow-frontend.yaml
$ kubectl -n lab5 get networkpolicies
$ labs/files/lab-05/test.sh
```

Expected: frontend ALLOWED, intruder BLOCKED.

**Questions:**

- The two policies do not contradict each other. How do they combine?
- You scale the frontend to 3 pods. Do you have to change the policy? Why not?

### B4. Deny outgoing traffic too, and break DNS

Blocking what comes **in** is half the job. Now block what goes **out**:

```bash
$ kubectl -n lab5 apply -f labs/files/lab-05/3-default-deny-egress.yaml
$ labs/files/lab-05/test.sh
```

The frontend is BLOCKED again, although you allowed it in B3.

**Question:** look at the DNS line of `test.sh`. Why can the frontend no
longer call `http://backend`, even though the backend still accepts it?

Repair it by allowing exactly what the frontend needs to send:

```bash
$ cat labs/files/lab-05/4-allow-egress.yaml
$ kubectl -n lab5 apply -f labs/files/lab-05/4-allow-egress.yaml
$ labs/files/lab-05/test.sh
```

Expected: frontend ALLOWED, intruder BLOCKED, DNS WORKS.

**Question:** the egress policy has two rules. Which one is for DNS, and
which pods in which namespace does it point at?

> "Default-deny egress that forgot DNS" is one of the most common network
> policy mistakes. The symptom is never "DNS is blocked"; it is "the
> application cannot connect to anything".

### B5. Clean up

Stop `cilium hubble port-forward` in terminal 2 with `Ctrl-C`, then:

```bash
$ kubectl delete namespace lab5
```

### Checkpoint B ✅

- [ ] With default-deny only, both callers were BLOCKED
- [ ] With the allow rule, only the frontend was ALLOWED
- [ ] You saw DNS fail after the egress deny, and you can explain why
- [ ] You saw dropped flows in Hubble and the reason for them
- [ ] The namespace `lab5` is gone

## If you're stuck

- See what applies right now: `kubectl -n lab5 get networkpolicies`.
- Remove all policies and start part B again:
  `kubectl -n lab5 delete networkpolicies --all`.
- Start the whole lab again: `kubectl delete namespace lab5`, wait until it
  is gone, then repeat from A1.
- `hubble observe` says it cannot connect: `cilium hubble port-forward` is
  not running in the other terminal.

## ★ Stretch

- **HTTP-aware policy.** A CiliumNetworkPolicy can allow `GET` and refuse
  everything else. Before the clean-up:
  `kubectl -n lab5 delete networkpolicy allow-frontend-to-backend`, then
  apply `labs/files/lab-05/5-cnp-http-get-only.yaml`. Compare
  `kubectl -n lab5 exec deployment/frontend -- wget -qO- http://backend`
  with the same command plus `--post-data=x`. What answer does the POST get,
  and what does Hubble show for it?
- Scale the frontend to 3 (`kubectl -n lab5 scale deployment/frontend
  --replicas=3`) and run `kubectl -n lab5 get ciliumendpoints`. Which pods
  share an identity number?
- Draw your policies at <https://editor.networkpolicy.io/> by pasting
  `2-allow-frontend.yaml` into it.
