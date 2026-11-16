# Lab 9 — Keycloak: the operator, users, roles and single sign-on

Two parts, each with its own checkpoint:

- **Part A — Tour Keycloak.** 20 min, follow along with the instructor.
  **You will:** find the custom resources, the operator, the database and
  the admin console, and watch the operator repair something you delete.
- **Part B — Routine user administration.** 45 min, on your own. **You
  will:** add a user, give them a Grafana role through the realm, log in to
  Grafana with single sign-on, reset a password, disable the user, and
  follow a login through the Keycloak and Grafana logs.

`$` = workstation · `<something>` = your own value · ★ = optional

The helper scripts are in `labs/files/lab-09/`.

> **Bare start?** Do **★ Build** at the end of this guide **first** (25
> minutes): you install the Keycloak Operator, a database and a Keycloak
> instance. Then do parts A and B like everyone else.

> ⚠️ **Lab shortcuts in this lab:** Keycloak is reached over plain HTTP, you
> work as the bootstrap admin `temp-admin`, and the test users have known
> passwords. In production Keycloak is only reachable over HTTPS, the
> bootstrap admin is replaced by named administrators, and users come from
> a directory (LDAP, Active Directory) or set their own passwords.

---

## Part A — Tour Keycloak

### A1. New kinds of object

In lab 7 you met ServiceMonitor and PrometheusRule: kinds of object that
plain Kubernetes does not have. They come from **CustomResourceDefinitions**
(CRDs). See which ones this cluster has:

```bash
$ cd "$K8S_COURSE_HOME"
$ kubectl get crds | grep -E 'keycloak|strimzi|coreos|cilium'
$ kubectl api-resources --api-group=k8s.keycloak.org
```

**Question:** which software added each group of CRDs? (The names tell
you.)

### A2. What you asked for, and what the operator made of it

```bash
$ kubectl -n keycloak get keycloaks,keycloakrealmimports
$ cat infra/platform/keycloak/keycloak.yaml
$ kubectl -n keycloak get pods,statefulsets,deployments,services
```

The file asks for *one Keycloak with this database and this hostname*. It
does not mention a StatefulSet or a Service. The **operator** created those:

```bash
$ kubectl -n keycloak get statefulset keycloak -o jsonpath='{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}{"\n"}'
$ kubectl -n keycloak get keycloak keycloak -o jsonpath='{range .status.conditions[*]}{.type}={.status}  {.message}{"\n"}{end}'
$ kubectl -n keycloak logs deployment/keycloak-operator --tail=5
```

Fill in the table:

| Pod | Created by | Its job |
|---|---|---|
| `keycloak-operator-…` | A Deployment we applied | |
| `keycloak-0` | | |
| `postgres-0` | A StatefulSet we applied | |

**Question:** the status shows `Ready=True`. Who wrote that status: you,
Kubernetes, or the operator?

### A3. The operator repairs what it owns

Delete the Service the operator created, and look again a few seconds
later:

<!-- smoke: disruptive -->
```bash
$ kubectl -n keycloak get service keycloak-service
$ kubectl -n keycloak delete service keycloak-service
$ sleep 20
$ kubectl -n keycloak get service keycloak-service
```

**Questions:**

- Look at AGE. Who brought the Service back?
- You changed nothing in `keycloak.yaml`. What does that tell you about
  editing objects an operator owns, instead of the custom resource?

### A4. The database

Keycloak itself stores nothing on disk. Realms, users and sessions are in
PostgreSQL:

```bash
$ kubectl -n keycloak get pvc
$ kubectl -n keycloak exec postgres-0 -- psql -U keycloak -d keycloak -c 'select name, enabled from realm'
$ kubectl -n keycloak exec postgres-0 -- psql -U keycloak -d keycloak -c 'select count(*) as users from user_entity'
```

**Question:** if `keycloak-0` is deleted, what is lost? If the volume of
`postgres-0` is lost, what is lost?

### A5. The admin console

```bash
$ IP=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' | sed -E 's#https?://([^:/]+).*#\1#')
$ echo "http://keycloak.$IP.sslip.io"
$ kubectl -n keycloak get secret keycloak-initial-admin -o jsonpath='{.data.password}' | base64 -d; echo
```

Open the address, log in as `temp-admin` with that password, then:

1. Top left, switch from the realm **master** to **platform**.
2. **Users**: find `ops-admin` and `ops-user`. Open `ops-admin` → **Role
   mapping**.
3. **Clients**: open `grafana`. Find its **Valid redirect URIs**.
4. **Realm roles**: find `grafana-admin` and `grafana-editor`.

Everything an application needs to know about this realm is published at
one address:

```bash
$ curl -s "http://keycloak.$IP.sslip.io/realms/platform/.well-known/openid-configuration" | jq '{issuer, authorization_endpoint, token_endpoint, userinfo_endpoint}'
$ grep -A6 'auth.generic_oauth' infra/platform/observability/grafana-keycloak-sso.yaml
```

**Question:** compare the two outputs. Which of Keycloak's addresses did we
give to Grafana?

### Checkpoint A ✅

- [ ] You can name the three pods in the namespace `keycloak` and say who
  created each
- [ ] You saw the operator recreate a Service you deleted
- [ ] You know where Keycloak's data is stored
- [ ] You found the users, the client `grafana` and the roles in the admin
  console

---

## Part B — Routine user administration

Each task is done with `kc.sh`, which runs Keycloak's own admin tool. After
each step, look at the result in the admin console as well: the console is
what you will mostly use; the command line is what you script.

### B1. Log in and list the users

```bash
$ cd "$K8S_COURSE_HOME"
$ cat labs/files/lab-09/kc.sh
$ labs/files/lab-09/kc.sh login
$ labs/files/lab-09/kc.sh get users -r platform --fields username,enabled,email
$ labs/files/lab-09/kc.sh get roles -r platform --fields name,description
```

`-r platform` chooses the realm. Leave it out and you are working on
`master`, which holds only the administrators.

### B2. Add a user

```bash
$ labs/files/lab-09/kc.sh create users -r platform -s username=lab9-user -s enabled=true -s email=lab9-user@example.test -s emailVerified=true -s firstName=Lab -s lastName=Nine
$ labs/files/lab-09/kc.sh set-password -r platform --username lab9-user --new-password 'Lab9-Pass1'
$ ID=$(labs/files/lab-09/kc.sh user-id lab9-user)
$ echo "$ID"
```

Keycloak knows every user by an ID, not by name; `$ID` is used below.

Log in to Grafana as the new user. `sso-login.sh` does what a browser does
and prints what Grafana makes of it:

```bash
$ labs/files/lab-09/sso-login.sh lab9-user 'Lab9-Pass1'
```

Do the same in a **private browser window**: open Grafana, choose **Sign in
with Keycloak**, log in as `lab9-user`.

**Question:** which Grafana role did the new user get, and where is that
decided? (Look for `role_attribute_path` in
`infra/platform/observability/grafana-keycloak-sso.yaml`.)

### B3. Give the user a Grafana role, through the realm

```bash
$ labs/files/lab-09/kc.sh add-roles -r platform --uusername lab9-user --rolename grafana-editor
$ labs/files/lab-09/kc.sh get "users/$ID/role-mappings/realm" -r platform --fields name
$ labs/files/lab-09/sso-login.sh lab9-user 'Lab9-Pass1'
```

The role is now `Editor`. Nothing was changed in Grafana.

**Questions:**

- In the browser window where `lab9-user` was already logged in, is the
  user an Editor yet? When does Grafana find out?
- You manage 12 applications. Why is "roles in the realm" better than
  "roles in each application"?

### B4. Reset a password

The user has forgotten their password:

```bash
$ labs/files/lab-09/kc.sh set-password -r platform --username lab9-user --new-password 'Lab9-Reset2'
$ labs/files/lab-09/sso-login.sh lab9-user 'Lab9-Pass1' || echo "the old password no longer works"
$ labs/files/lab-09/sso-login.sh lab9-user 'Lab9-Reset2'
```

In the console the same action is **Users → lab9-user → Credentials →
Reset password**. There you can tick **Temporary**: the user must then
choose a new password at the next login, so you never know it.

### B5. Follow a login through the logs

Switch on Keycloak's record of login events for the realm, then cause one
failed and one successful login:

```bash
$ labs/files/lab-09/kc.sh update events/config -r platform -s eventsEnabled=true
$ labs/files/lab-09/sso-login.sh lab9-user 'wrong-password' || echo "refused, as intended"
$ labs/files/lab-09/sso-login.sh lab9-user 'Lab9-Reset2'
$ labs/files/lab-09/kc.sh get events -r platform --fields type,error,clientId,ipAddress --limit 6
```

The same events are in the console under **Events → User events**. Failed
logins are also written to Keycloak's log, so they are in Loki (lab 7):

```bash
$ labs/files/lab-07/logql.sh '{namespace="keycloak"} |= "LOGIN_ERROR"'
$ kubectl -n monitoring logs deployment/kube-prometheus-stack-grafana -c grafana --since=10m | grep -i oauth || echo "(Grafana logged nothing about OAuth in the last 10 minutes)"
```

**Questions:**

- A successful login produces more than one event. Which types do you see,
  and which one matches step 5 of the comment in `sso-login.sh` (Grafana
  swapping the code for a token)?
- What does the failed login's `error` say? Does it tell an attacker
  whether the user exists?
- From which address (`ipAddress`) do the logins appear to come? Why is
  that not your workstation's address?

### B6. Disable the user

Someone leaves the team:

```bash
$ labs/files/lab-09/kc.sh update "users/$ID" -r platform -s enabled=false
$ labs/files/lab-09/kc.sh get users -r platform --fields username,enabled
$ labs/files/lab-09/sso-login.sh lab9-user 'Lab9-Reset2' || echo "the disabled user cannot log in"
```

**Questions:**

- The user can no longer log in **anywhere** that uses this realm. How
  many places would you have had to change without single sign-on?
- A browser window where the user was still logged in to Grafana keeps
  working for a while. Why? What would you do if it must stop now?
  (Console: **Users → lab9-user → Sessions**.)

### B7. Clean up

```bash
$ labs/files/lab-09/kc.sh delete "users/$ID" -r platform
$ labs/files/lab-09/kc.sh update events/config -r platform -s eventsEnabled=false
$ labs/files/lab-09/kc.sh get users -r platform --fields username,enabled
```

The user is gone from Keycloak, but not from Grafana. Grafana keeps its own
record of everyone who ever logged in, with the ID Keycloak gave them:

```bash
$ labs/files/lab-09/grafana-user.sh show lab9-user
$ labs/files/lab-09/grafana-user.sh delete lab9-user
$ infra/platform/verify.sh
```

**Questions:**

- The record cannot be used to log in: Keycloak no longer knows the user.
  Why remove it anyway? (Think of an audit: "who has access to Grafana?")
- Suppose you had left it, and next month created a new `lab9-user` in
  Keycloak for a new colleague. Keycloak gives the new user a new ID.
  Grafana would refuse the login: the name is taken by somebody else's
  identity. Is that a nuisance or a protection?

### Checkpoint B ✅

- [ ] You created a user and logged in to Grafana with it through Keycloak
- [ ] You changed the user's Grafana role without touching Grafana
- [ ] You reset the password and saw the old one refused
- [ ] You found a failed login in Keycloak's events and in Loki
- [ ] You disabled the user and saw the login refused
- [ ] `lab9-user` is deleted in Keycloak **and** in Grafana, and `verify.sh`
  ends with `0 failed`

## If you're stuck

- `kc.sh` answers "Session has expired" or "401": run
  `labs/files/lab-09/kc.sh login` again.
- `sso-login.sh` says "Keycloak accepted the user, but Grafana did not",
  and Grafana's log says "unable to create user": Grafana still has a
  `lab9-user` from an earlier attempt, with a different Keycloak ID.
  `labs/files/lab-09/grafana-user.sh delete lab9-user`, then log in again.
- `kc.sh create users` says "User exists with same username": the user is
  left over from an earlier attempt. Do B7 (set `ID` first, as in B2), then
  start again at B2.
- `keycloak-service` did not come back in A3: restart the operator with
  `kubectl -n keycloak rollout restart deployment/keycloak-operator`, wait
  a minute, look again.
- "HTTPS required" in the browser: the realm still demands TLS. Console:
  realm **platform** → **Realm settings** → **Require SSL** → *None* (⚠️
  lab only).
- Grafana shows "Login failed" after the Keycloak page: the Grafana pod
  cannot reach Keycloak, or the client secret differs. Run
  `infra/platform/verify.sh` and tell the instructor.
- Keycloak itself is broken: `infra/platform/deploy.sh keycloak`, then
  `infra/platform/verify.sh --wait 300`.

---

## ★ Build — install the operator, a database and Keycloak (bare start)

Do this part **first**. 25 minutes, much of it waiting for Keycloak's first
start. You do by hand what `infra/platform/deploy.sh keycloak` does, with
the same files and versions, and let the script finish the last two steps.

**The operator.** There is no Helm chart: the Keycloak project publishes
plain manifests, two CRDs and the operator's Deployment:

```bash
$ cd "$K8S_COURSE_HOME"
$ source infra/platform/lib.sh
$ detect_ingress_ip
$ BASE="https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/${KEYCLOAK_VERSION}/kubernetes"
$ kubectl create namespace keycloak
$ kubectl apply -f "$BASE/keycloaks.k8s.keycloak.org-v1.yml"
$ kubectl apply -f "$BASE/keycloakrealmimports.k8s.keycloak.org-v1.yml"
$ kubectl -n keycloak apply -f "$BASE/kubernetes.yml"
$ kubectl -n keycloak rollout status deployment/keycloak-operator --timeout=300s
$ kubectl get crds | grep keycloak
```

**The database.** Its password goes into a Secret first; `render` fills the
pinned PostgreSQL image into the manifest:

```bash
$ kubectl -n keycloak create secret generic keycloak-db --from-literal=username=keycloak --from-literal=password="$(lab_secret keycloak-db)"
$ render infra/platform/keycloak/postgres.yaml | kubectl apply -f -
$ kubectl -n keycloak rollout status statefulset/postgres --timeout=300s
```

**Keycloak.** Apply the custom resource and watch the operator work. The
first start takes two to four minutes:

```bash
$ render infra/platform/keycloak/keycloak.yaml | kubectl apply -f -
$ kubectl -n keycloak get keycloak,statefulsets,pods
$ wait_for keycloak keycloak/keycloak Ready 600 app=keycloak
$ kubectl -n keycloak get pods
```

**The realm and Grafana single sign-on.** Let the script do the rest. It
repeats what you did (nothing changes), then imports the realm `platform`
and connects Grafana to it:

```bash
$ infra/platform/deploy.sh keycloak
$ infra/platform/verify.sh
```

**Questions:**

- `keycloak.yaml` deliberately has no `image:` line. Read the comment in
  the file: what goes wrong if you add one?
- In `infra/platform/keycloak/realm-platform.yaml`, find the line marked
  LAB ONLY. What is the production value?

### Build checkpoint ✅

- [ ] `kubectl -n keycloak get keycloak` shows the instance, and its pod
  `keycloak-0` is `1/1`
- [ ] `verify.sh` shows the Keycloak lines green, including "Grafana login
  through Keycloak (SSO)", and ends with `0 failed`

---

## ★ Stretch

- **Force a logout.** Log in to Grafana as `ops-user` in a private browser
  window. In the Keycloak console: **Users → ops-user → Sessions → Sign
  out**. How long does Grafana keep working in that window?
- **A group instead of a role per user.** In the console create a group
  `platform-team`, give the **group** the role `grafana-editor`
  (**Groups → platform-team → Role mapping**) and add `ops-user` to it.
  Log in as `ops-user`. Remove the group afterwards.
- **Why the import did not change.** `kubectl -n keycloak get
  keycloakrealmimport platform -o yaml | less`. An import creates a realm
  that does not exist yet; it never updates one. What does that mean for
  "the realm is in git"?
- **What is in a token.** In the console: **Clients → grafana → Client
  scopes → Evaluate**, choose the user `ops-admin`, then **Generated ID
  token**. Find the `roles` claim that Grafana reads.
- **The operator's view.** `kubectl -n keycloak describe keycloak
  keycloak`, then `kubectl -n keycloak get events --sort-by=.lastTimestamp
  | tail`.
