# Lab 8 — Vault: health, seal and unseal, and a secret for a pod

Two parts, each with its own checkpoint:

- **Part A — Vault health.** 30 min, follow along with the instructor.
  **You will:** read Vault's status, find its secret engines, login methods
  and policies, seal it, see what that breaks, and unseal it again.
- **Part B — A secret for a pod.** 45 min, on your own. **You will:** store
  a secret, write a policy and a role for it, have it delivered to a pod as
  a file without any Kubernetes Secret, rotate it, and see a pod that is not
  allowed to have it.

`$` = workstation · `<something>` = your own value · ★ = optional

The helper script and manifests are in `labs/files/lab-08/`. Part B works in
the namespace `lab8`.

> **Bare start?** Do **★ Build** at the end of this guide **first** (20
> minutes): you install Vault, initialise and unseal it by hand. Then do
> parts A and B like everyone else.

> ⚠️ **Lab shortcuts in this lab:** you work as Vault's **root** user, and
> all five unseal keys are in one file on your workstation. In production
> the root token is revoked after setup, people log in as themselves, and
> the key shares are held by different people (or the cluster uses
> auto-unseal with a cloud key service or an HSM).

---

## Part A — Vault health

### A1. What runs

```bash
$ cd "$K8S_COURSE_HOME"
$ kubectl -n vault get pods,statefulsets,deployments
$ kubectl -n vault get services,ingress,pvc
```

Two workloads: `vault-0` is Vault itself; `vault-agent-injector` is the part
that delivers secrets to pods (part B).

### A2. Status: the first thing to look at

```bash
$ kubectl -n vault exec vault-0 -- vault status
```

Find these lines:

| Line | Healthy value | Meaning |
|---|---|---|
| `Initialized` | `true` | Vault has been set up once and has its keys |
| `Sealed` | `false` | Vault can decrypt its data |
| `Total Shares` / `Threshold` | `5` / `3` | 5 unseal keys exist; any 3 unseal |
| `Storage Type` | `raft` | Data is on Vault's own disk, not in an external database |
| `HA Mode` | `active` | This pod answers requests |

**Question:** this command needed no login. Why is it useful that anyone can
ask Vault whether it is sealed?

### A3. Log in and look around

Load the lab's shortcuts, then use `v` wherever you would type `vault`:

```bash
$ cat labs/files/lab-08/vault-cli.sh
$ source labs/files/lab-08/vault-cli.sh
$ v token lookup -format=json | jq '.data | {display_name, policies, ttl}'
$ v operator raft list-peers
$ v secrets list
$ v auth list
$ v policy list
```

| Command | Shows |
|---|---|
| `v token lookup …` | Who you are: look at `policies` (⚠️ `root`). The `jq` part hides the token itself |
| `v operator raft list-peers` | The Vault servers that store the data (one, in this lab) |
| `v secrets list` | Secret engines: `secret/` is the key-value store |
| `v auth list` | Login methods: `token/` and `kubernetes/` |
| `v policy list` | The named sets of permissions |

### A4. Who may read what?

Follow one existing permission from end to end, the one Redis uses (lab 10):

```bash
$ v policy read redis
$ v read auth/kubernetes/role/redis
$ v read auth/kubernetes/config
$ v kv metadata get secret/platform/redis
```

**Questions:**

- The policy `redis` allows one thing. What, and on which path?
- The role `redis` connects that policy to a Kubernetes identity. Which
  service account, in which namespace?
- `kv metadata get` shows versions and dates but not the value. Why is that
  a useful command for an operator?

### A5. The injector, and the Helm fault

```bash
$ kubectl -n vault logs deployment/vault-agent-injector --tail=5
$ kubectl get mutatingwebhookconfigurations
$ kubectl get mutatingwebhookconfiguration vault-agent-injector-cfg -o jsonpath='{.webhooks[0].clientConfig.caBundle}' | wc -c
```

The last number must not be 0: that field is the certificate the API server
uses to trust the injector. It is the `caBundle` from the "real fault" slide
in the Helm deck; a blank one means no pod gets its secrets.

### A6. Seal Vault

Sealing throws away the key in Vault's memory. The data stays on disk,
encrypted, and nobody can read it, Vault included.

<!-- smoke: disruptive -->
```bash
$ v operator seal
$ kubectl -n vault exec vault-0 -- vault status || echo "exit code $?: sealed"
$ kubectl -n vault get pods
$ v secrets list || echo "REFUSED: Vault is sealed"
$ infra/platform/verify.sh || echo "verify.sh found the problem"
```

**Questions:**

- `vault-0` is `Running` but `0/1`. Which probe is failing, and what does
  Kubernetes do with a pod that is not Ready? (Lab 4.)
- Which line of `verify.sh` is red?
- Pods that already have their secrets keep running. What would happen to a
  pod that **starts** now and needs a secret?

A Vault pod that restarts for any reason (node reboot, upgrade, crash)
comes back **sealed**. This is the most common Vault incident.

### A7. Unseal it

Any three of the five keys will do. Give them one at a time and watch
`Unseal Progress`:

<!-- smoke: disruptive -->
```bash
$ kubectl -n vault exec vault-0 -- vault operator unseal "$(unseal_key 0)"
$ kubectl -n vault exec vault-0 -- vault operator unseal "$(unseal_key 3)"
$ kubectl -n vault exec vault-0 -- vault operator unseal "$(unseal_key 4)"
$ kubectl -n vault wait --for=condition=Ready pod/vault-0 --timeout=120s
$ v secrets list
$ infra/platform/verify.sh --wait 120
```

**Questions:**

- After the first key, `Sealed` was still `true`. After which key did it
  change, and why that one?
- In production the five keys belong to five people. What does that protect
  against? What does it cost you at 3 a.m.?

### Checkpoint A ✅

- [ ] You can tell from `vault status` whether Vault is initialised, sealed
  and active
- [ ] You followed one permission: policy → role → service account
- [ ] You sealed Vault, saw what breaks, and unsealed it with three keys
- [ ] `verify.sh` ends with `0 failed`

---

## Part B — A secret for a pod

If you opened a new terminal, load the shortcuts again:

```bash
$ cd "$K8S_COURSE_HOME"
$ source labs/files/lab-08/vault-cli.sh
```

### B1. Store a secret

```bash
$ v kv put secret/lab8/web message="hello from vault" api_key="first-key-111"
$ v kv get secret/lab8/web
$ v kv get -field=message secret/lab8/web
```

**Question:** find `version` in the output. What do you expect it to be
after the next `kv put`?

### B2. A policy: what may be read

```bash
$ cat labs/files/lab-08/policy-lab8.hcl
$ v policy write lab8 - < labs/files/lab-08/policy-lab8.hcl
$ v policy read lab8
```

### B3. A role: who gets that policy

```bash
$ v write auth/kubernetes/role/lab8 bound_service_account_names=web bound_service_account_namespaces=lab8 policies=lab8 ttl=1h
$ v read auth/kubernetes/role/lab8
```

In words: *a pod that proves it runs as service account `web` in namespace
`lab8` gets a Vault token with the policy `lab8`, valid for one hour.*

### B4. Deliver it to a pod

```bash
$ cat labs/files/lab-08/web.yaml
$ kubectl create namespace lab8
$ kubectl -n lab8 apply -f labs/files/lab-08/web.yaml
$ kubectl -n lab8 rollout status deployment/web --timeout=180s
$ kubectl -n lab8 get pods
```

The pod shows **2/2**: your file asked for one container, and the injector
added a second one. Look at what was added, and at the result:

```bash
$ kubectl -n lab8 get pods -o jsonpath='{range .items[0].spec.initContainers[*]}init: {.name}{"\n"}{end}{range .items[0].spec.containers[*]}container: {.name}{"\n"}{end}'
$ kubectl -n lab8 exec deployment/web -c web -- cat /vault/secrets/web.txt
$ kubectl -n lab8 get secrets
$ kubectl -n lab8 logs deployment/web -c vault-agent --tail=5
```

**Questions:**

- `kubectl -n lab8 get secrets` shows nothing with your values in it.
  Where is the secret stored, then? Compare with how you read the Grafana
  password in lab 1.
- `vault-agent-init` runs before your container starts, `vault-agent` runs
  next to it. What is each one for?
- Which annotation in `web.yaml` decides the file's name, and which one its
  content?

### B5. Rotate the secret

```bash
$ v kv put secret/lab8/web message="rotated" api_key="second-key-222"
$ sleep 45
$ kubectl -n lab8 exec deployment/web -c web -- grep rotated /vault/secrets/web.txt
$ kubectl -n lab8 get pods
```

The file changed and the pod was **not** restarted (same name, same age).

**Questions:**

- Who rewrote the file?
- The file is new. Does the application know? What would nginx, or your
  own application, have to do to use the new value?
- `v kv get -version=1 secret/lab8/web` still shows the old value. When is
  that useful, and when is it a risk?

### B6. A pod that is not allowed

`intruder.yaml` asks for the same secret, but its pod runs as the service
account `default`:

```bash
$ cat labs/files/lab-08/intruder.yaml
$ kubectl -n lab8 apply -f labs/files/lab-08/intruder.yaml
$ sleep 45
$ kubectl -n lab8 get pods
$ kubectl -n lab8 logs deployment/intruder -c vault-agent-init --tail=5
```

**Questions:**

- In which state is the intruder pod stuck, and what does the log say?
- Which of the three things you created (secret, policy, role) refused it?
- This is also what a **typo** in a service account name or a role name
  looks like. Where would you look first?

### B7. Clean up

```bash
$ kubectl delete namespace lab8
$ v delete auth/kubernetes/role/lab8
$ v policy delete lab8
$ v kv metadata delete secret/lab8/web
```

**Question:** deleting the namespace did not remove the secret, the policy
or the role. Why not?

### Checkpoint B ✅

- [ ] A pod read a secret from Vault as a file, with no Kubernetes Secret
- [ ] You rotated the secret and the file changed without a restart
- [ ] You saw Vault refuse a pod with the wrong service account, and found
  the reason in the log
- [ ] The namespace `lab8`, the role, the policy and the secret are gone

## If you're stuck

- `v` says `command not found`: `source labs/files/lab-08/vault-cli.sh`
  (needed in every new terminal).
- Everything answers "Vault is sealed": do step A7. Or let the script do
  it: `infra/platform/vault/init-unseal.sh`.
- The `web` pod stays at `Init:0/1`: read
  `kubectl -n lab8 logs deployment/web -c vault-agent-init --tail=10`.
  "permission denied" means the role, the service account name or the
  namespace does not match (B3); "sealed" means A7.
- The `web` pod shows `1/1` and there is no `/vault/secrets`: the injector
  did not act. `kubectl -n vault get pods`, then step A5.
- Vault itself is broken: `infra/platform/deploy.sh vault`, then
  `infra/platform/verify.sh --wait 180`.
- Start part B again: do B7, wait until the namespace is gone, repeat from
  B1.

---

## ★ Build — install, initialise and unseal Vault (bare start)

Do this part **first**. 20 minutes. You run the same chart version and
values file as `infra/platform/deploy.sh vault`, and do by hand what its
two scripts do.

**Install.** `$(helm_csa_flag)` is the fix from the "real fault" slide in
the Helm deck:

```bash
$ cd "$K8S_COURSE_HOME"
$ source infra/platform/lib.sh
$ detect_ingress_ip
$ helm_repos
$ render infra/platform/vault/values.yaml > /tmp/vault-values.yaml
$ helm upgrade --install vault hashicorp/vault -n vault --create-namespace --version "$CHART_VAULT" $(helm_csa_flag) -f /tmp/vault-values.yaml
$ kubectl -n vault wait --for=jsonpath='{.status.phase}'=Running pod/vault-0 --timeout=300s
$ kubectl -n vault get pods
$ kubectl -n vault exec vault-0 -- vault status || echo "exit code $?: not ready yet"
```

`vault-0` is `0/1`, and the status says `Initialized false`: a new Vault has
no keys yet.

**Initialise.** This happens once in a Vault's life. It prints the unseal
keys and the root token, and never shows them again:

```bash
$ kubectl -n vault exec vault-0 -- vault operator init -key-shares=5 -key-threshold=3 -format=json > /tmp/vault-init.json
$ jq '{keys: (.unseal_keys_b64 | length), threshold: .unseal_threshold, has_root_token: (.root_token != null)}' /tmp/vault-init.json
```

The second command must print `"keys": 5`. **If it does not, stop and ask
the instructor**: do not run the next line. It puts the file where the lab
scripts expect it:

```bash
$ install -m 600 /tmp/vault-init.json infra/platform/.secrets/vault-init.json
$ rm /tmp/vault-init.json
```

> ⚠️ Lab only. Losing this file means losing every secret in Vault; anyone
> who has it can read every secret. In production these keys never sit
> together in one file.

**Unseal**, with any three keys:

```bash
$ source labs/files/lab-08/vault-cli.sh
$ kubectl -n vault exec vault-0 -- vault operator unseal "$(unseal_key 0)"
$ kubectl -n vault exec vault-0 -- vault operator unseal "$(unseal_key 1)"
$ kubectl -n vault exec vault-0 -- vault operator unseal "$(unseal_key 2)"
$ kubectl -n vault wait --for=condition=Ready pod/vault-0 --timeout=120s
$ v status
```

**Configure.** Switch on the key-value store and the Kubernetes login
method by hand, then let the script add the platform's policies, roles and
first secrets:

```bash
$ v secrets enable -path=secret kv-v2
$ v auth enable kubernetes
$ v write auth/kubernetes/config kubernetes_host="https://kubernetes.default.svc:443"
$ cat infra/platform/vault/configure.sh
$ infra/platform/vault/configure.sh
$ infra/platform/verify.sh
```

**Questions:**

- Why did `vault-0` only become `1/1` after the third unseal key?
- `configure.sh` runs the same three commands you just typed. Why did it
  not fail on "already enabled"?

### Build checkpoint ✅

- [ ] `v status` shows `Initialized true`, `Sealed false`
- [ ] `v secrets list` shows `secret/`, `v auth list` shows `kubernetes/`
- [ ] `verify.sh` shows the Vault lines green and ends with `0 failed`

---

## ★ Stretch

- **The web UI.** Print the address with
  `infra/scripts/lab-info.sh`, open the Vault one and log in with method
  *Token*. The token is the value of `root_token` in
  `infra/platform/.secrets/vault-init.json` (⚠️ lab only). Find your
  secret, its versions, and the policy `lab8`.
- **Lose the pod instead of sealing it.** `kubectl -n vault delete pod
  vault-0`, wait for the new pod, and look at `vault status`. Then unseal
  it as in A7. This is the incident as it happens in real life.
- **Too little permission.** While the `web` pod runs (before B7), store a
  second secret with `v kv put secret/other/thing x=1` and add an
  annotation for it to a copy of `web.yaml`. What does the agent log say?
  Delete it afterwards: `v kv metadata delete secret/other/thing`.
- **A Raft snapshot** is Vault's backup:
  `v operator raft snapshot save /tmp/vault.snap`, then
  `kubectl -n vault exec vault-0 -- ls -l /tmp/vault.snap`. You take one
  properly in lab 13.
- **Vault Secrets Operator** is the alternative to the injector: it copies
  Vault secrets into Kubernetes Secrets. Read the comparison on the last
  slides of the Vault deck. Which of the two would have updated a running
  application that reads its password from an environment variable?
