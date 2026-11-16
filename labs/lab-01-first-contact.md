# Lab 1 — First contact with your cluster

**Time:** 30 min · **Mode:** follow along with the instructor ·
**You will:** tour your workstation, see your nodes and pods, look around with
k9s, open the web UIs and run the platform health check.

Conventions used in all labs:

- `$` = run on your **workstation**
- `node1$` = run on node1 (`ssh node1` first)
- `<something>` = replace with your own value
- ★ = optional part

> **Which parts do I do?** Your cluster is already built: do **Explore** and
> **Operate**. If you chose the **bare** start (empty nodes), do **★ Build**
> at the end of this guide instead.

---

## Explore

### 1. Your workstation

Open a terminal. Your shell knows where the course material is: the variable
`K8S_COURSE_HOME` holds its directory. Every lab starts by going there.

```bash
$ cd "$K8S_COURSE_HOME"
$ ls
$ infra/scripts/lab-info.sh --ssh-config
```

> **`ls` does not show `labs/` and `infra/`?** Then `K8S_COURSE_HOME` is not
> set in this terminal. Go to the course directory yourself, run
> `infra/scripts/install-tools.sh` (it records the location) and open a new
> terminal. Do the same if you ever move the directory.

`lab-info.sh` prints your nodes and your web UI addresses. With
`--ssh-config` it also teaches SSH the names `node1`, `node2`, `node3`.
You can run it again at any time.

```bash
$ ssh node1 hostname
$ ssh node2 uptime
```

**Question:** node1 has a second name, in the column KUBERNETES NODE NAME.
Where do you think that name comes from?

### 2. Your tools

```bash
$ kubectl version
$ helm version --short
$ cilium version --client
$ vault version
$ ansible --version
```

`kubectl version` prints two versions: the client (your workstation) and the
server (your cluster).

| Tool | What it is for | Where you use it most |
|---|---|---|
| `kubectl` | Talk to the Kubernetes API | every lab |
| `k9s` | Terminal UI for the same API | every lab |
| `helm` | Install and upgrade packaged apps | lab 6 |
| `cilium`, `hubble` | Network status and traffic flows | lab 5 |
| `stern` | Follow the logs of many pods at once | whenever you follow logs |
| `vault` | Secrets | lab 8 |
| `jq`, `yq` | Pick values out of JSON and YAML | many labs |
| `ansible` | Build and change the nodes | labs 2 and 12 |

### 3. Your cluster

```bash
$ kubectl get nodes -o wide
$ kubectl get namespaces
$ kubectl get pods -A
$ kubectl get pods -A --no-headers | wc -l
```

**Questions:**

- How many nodes do you have, and which one has the role `control-plane`?
- Roughly how many pods are running? Which namespace names do you recognise
  from the platform map?

### 4. Look around with k9s

<!-- smoke: skip (interactive) -->
```bash
$ k9s
```

| Type | To |
|---|---|
| `:nodes` then Enter | list the nodes |
| `:pods` then Enter | list pods |
| `0` | show all namespaces |
| `/graf` then Enter | filter on "graf" |
| `d` | describe the selected object |
| `l` | show its logs |
| `Esc` | go back |
| `:q` then Enter | quit |

Find the Grafana pod. Which node does it run on?

### 5. The web UIs

`lab-info.sh` printed your addresses. Open these two in the browser:

- **Hubble** (`http://hubble.<node1-ip>.sslip.io`): choose the namespace
  `kube-system` and watch the traffic between pods.
- **Grafana** (`http://grafana.<node1-ip>.sslip.io`): the user is `admin`.
  The password is stored in the cluster:

```bash
$ kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

In Grafana open **Dashboards → Kubernetes / Compute Resources / Cluster**.

**Question:** you just read a password with one command. What does that tell
you about Kubernetes Secrets? (We come back to this with Secrets and with Vault.)

> ⚠️ **Lab shortcut:** everyone here is cluster administrator, and the UIs
> use plain HTTP. In production you log in through Keycloak and everything is
> behind TLS.

---

## Operate

### 6. Run the health check

```bash
$ infra/platform/verify.sh
```

Every line should be green. This script is the instructor's "is this cluster
healthy?" check; in lab 13 you will do by hand what each line does.

**Question:** pick two lines of the output. Which platform component does
each one check?

---

## Checkpoint ✅

- [ ] `ssh node1` works without typing an address
- [ ] `kubectl get nodes` shows 3 nodes, all `Ready`
- [ ] You found the Grafana pod in k9s
- [ ] Hubble and Grafana open in your browser
- [ ] `verify.sh` ends with `0 failed`

## If you're stuck

- `kubectl` cannot reach the cluster: ask the instructor to run
  `ansible-playbook infra/ansible/playbooks/kubeconfig.yml`.
- A red line in `verify.sh`: tell the instructor which one. The repair is
  `infra/platform/deploy.sh <layer>`.

---

## ★ Build — set up the workstation yourself (bare start)

Do this part **instead of** Explore and Operate. 30 minutes.

### B1. Install the tools

Go to the directory where you put the course material, then:

```bash
$ cd <course-directory>
$ ./infra/scripts/install-tools.sh
$ source ~/.bashrc
$ echo "$K8S_COURSE_HOME"
```

The script installs [arkade](https://github.com/alexellis/arkade) and uses it
to fetch the CLIs. Open the script and read the list of tools. It also records
where the course material is in `K8S_COURSE_HOME`; from here on every lab
starts with `cd "$K8S_COURSE_HOME"`.

```bash
$ kubectl version --client
$ helm version --short
$ k9s version --short
$ cilium version --client
$ vault version
$ ansible --version
```

> **What is arkade?** A downloader for cloud-native CLIs: `arkade get <tool>`
> fetches the right binary for your OS and CPU into `~/.arkade/bin`.

### B2. SSH access to your nodes

Your desk card lists your node addresses. Copy your key to each node (the
script created `~/.ssh/id_ed25519` if you had none):

<!-- smoke: skip (asks for a password) -->
```bash
$ for ip in <node1-ip> <node2-ip> <node3-ip>; do ssh-copy-id ubuntu@$ip; done
```

### B3. Ansible inventory

<!-- smoke: skip (editor) -->
```bash
$ cp infra/ansible/inventory/hosts.example.ini infra/ansible/inventory/hosts.ini
$ vim infra/ansible/inventory/hosts.ini
```

Put your node addresses in, then:

```bash
$ cd "$K8S_COURSE_HOME/infra/ansible"
$ ansible cluster -m ping
$ ansible cluster -m shell -a 'free -h | grep Mem; swapon --show'
$ cd "$K8S_COURSE_HOME"
$ infra/scripts/lab-info.sh --ssh-config
$ ssh node1 hostname
```

Expected: `"ping": "pong"` from every node, about 8 GB of memory each. Swap
should be empty; if not, the playbook disables it, because Kubernetes expects
no swap by default.

### Build checkpoint ✅

- [ ] All tools print a version
- [ ] `ansible cluster -m ping` succeeds for every node
- [ ] `ssh node1` works

---

## ★ Stretch

- `arkade get --help | less`: find two tools you would like to try later
  (`popeye` and `kubectl-neat` are worth a look)
- In k9s, type `:helm` and Enter. What is listed there?
