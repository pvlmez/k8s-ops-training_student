# Lab 2 — RKE2 nodes: the control plane and the node service

Two parts, each with its own checkpoint:

- **Part A — Explore: find the control plane.** 30 min, follow along with the
  instructor. **You will:** find the control-plane pods and the files that
  start them, see what deleting one really does, and look underneath
  Kubernetes with `crictl`.
- **Part B — Operate an RKE2 node.** 45 min, on your own. **You will:** check
  the RKE2 service and its config, read its log, stop an agent and bring it
  back.

`$` = workstation · `node1$` = on node1 (`ssh node1` first) · `<something>` =
your own value · ★ = optional

> **Bare start?** Do **★ Build** at the end of this guide instead of parts A
> and B: you install the server by hand and join the agents with Ansible.

---

## Part A — Explore: find the control plane

### A1. Which node is the server?

```bash
$ kubectl get nodes -o wide
$ infra/scripts/lab-info.sh
```

The node with the roles `control-plane,etcd` is your RKE2 **server**, node1.
The others are **agents**.

### A2. The control plane is pods too

```bash
$ kubectl -n kube-system get pods -o wide | grep -E 'NAME|etcd|kube-apiserver|kube-scheduler|kube-controller-manager'
```

**Question:** on which node do all of them run? Why not on node2?

### A3. Static pods: started from files, not by the API

The kubelet on node1 starts these pods from manifest files on disk.

```bash
$ ssh node1
node1$ sudo ls -l /var/lib/rancher/rke2/agent/pod-manifests/
node1$ sudo grep -n 'etcd-servers' /var/lib/rancher/rke2/agent/pod-manifests/kube-apiserver.yaml
```

**Question:** the API server reaches etcd on `127.0.0.1`. What does that tell
you about where etcd runs?

Back on the workstation (open a second terminal and keep the node1 session),
compare who **owns** each pod:

```bash
$ kubectl -n kube-system get pods -o custom-columns=NAME:.metadata.name,OWNER:.metadata.ownerReferences[0].kind
```

Pods owned by a `ReplicaSet` or `DaemonSet` were created by a controller.
Pods owned by a `Node` are static pods.

### A4. Delete a control-plane pod

Note how long the scheduler has been running, then delete its pod:

```bash
$ kubectl -n kube-system get pods | grep -E 'NAME|kube-scheduler'
$ kubectl -n kube-system delete $(kubectl -n kube-system get pods -o name | grep kube-scheduler)
$ kubectl -n kube-system get pods | grep -E 'NAME|kube-scheduler'
```

The pod is back within seconds with a new AGE. Now look at the real container
on node1:

```bash
node1$ sudo -i crictl ps --name kube-scheduler
```

**Question:** look at the CREATED column. Was the scheduler container
restarted? What did `kubectl delete` actually remove?

> For a static pod the API only holds a **mirror** of what the kubelet runs.
> To really restart it you would move its manifest file away and back, or
> restart `rke2-server`.

### A5. Underneath Kubernetes: containerd

```bash
node1$ sudo -i crictl ps
node1$ sudo -i crictl pods --namespace kube-system
node1$ sudo -i crictl images
node1$ ps -ef | grep '[k]ube-apiserver' | cut -c1-160
```

`sudo -i` gives a root login shell, which knows where RKE2 keeps `crictl` and
its settings. The API server is an ordinary Linux process on node1.

### A6. etcd and the kubelet

```bash
$ kubectl get --raw='/readyz?verbose'
node1$ sudo ls -lh /var/lib/rancher/rke2/server/db/snapshots/
node1$ sudo tail -n 5 /var/lib/rancher/rke2/agent/logs/kubelet.log
```

`/readyz` lists the API server's own health checks; find the `etcd` line.
The snapshots are etcd backups, taken on a schedule (lab 13). Leave node1 with
`exit` when you are done.

### Checkpoint A ✅

- [ ] You can name the four control-plane components and the node they run on
- [ ] You know where the static pod manifests are on node1
- [ ] You can explain why deleting the scheduler pod did not restart the scheduler
- [ ] You listed the containers on a node with `crictl`

---

## Part B — Operate an RKE2 node

### B1. The service

RKE2 is one systemd service per node: `rke2-server` on the server,
`rke2-agent` on the agents.

```bash
$ ssh node1 systemctl status rke2-server --no-pager --lines=0
$ ssh node2 systemctl status rke2-agent --no-pager --lines=0
$ ssh node3 systemctl is-active rke2-agent
$ ssh node1 systemctl is-enabled rke2-server
```

**Question:** since when has each service been running? Does it start at boot?

### B2. The config file

Everything RKE2 needs to know is in one file. It contains the join token, so
leave that line out when you print it:

```bash
$ ssh node1 "sudo grep -v '^token' /etc/rancher/rke2/config.yaml"
$ ssh node2 "sudo grep -v '^token' /etc/rancher/rke2/config.yaml"
```

**Questions:**

- Which line on node1 makes this cluster use Cilium? Which line means there
  are no `kube-proxy` pods?
- How does node2 know where the server is? Which port does it use?

### B3. The add-ons RKE2 installed for you

```bash
$ ssh node1 sudo ls /var/lib/rancher/rke2/server/manifests/
$ kubectl -n kube-system get helmcharts
$ kubectl -n kube-system get helmchartconfig rke2-cilium -o yaml | yq '.spec.valuesContent'
```

RKE2 applies every file in `server/manifests/` by itself. The
`HelmChartConfig` is how we changed the settings of the bundled Cilium chart.

**Question:** is Hubble enabled? Where would you change that: with
`helm upgrade`, or in this file? (See the RKE2 slides.)

### B4. The service log

The first place to look when a node misbehaves:

```bash
$ ssh node1 "sudo journalctl -u rke2-server --since '15 min ago' --no-pager | tail -n 20"
$ ssh node2 "sudo journalctl -u rke2-agent --no-pager -n 20"
```

**Question:** find one line you understand and one you do not. Ask about the
second one.

### B5. Stop an agent and bring it back

You will stop the RKE2 service on **node3** for about two minutes. Read the
whole step first.

> ⚠️ Start the service again **within 5 minutes**. After that Kubernetes
> starts to remove the pods of an unreachable node, and the clean-up takes
> much longer than the lab.

Terminal 1, watch the nodes (stop watching with `Ctrl-C` at the end):

<!-- smoke: skip (watch) -->
```bash
$ kubectl get nodes -w
```

Terminal 2:

<!-- smoke: disruptive -->
```bash
$ ssh node3 sudo systemctl stop rke2-agent
$ ssh node3 "systemctl is-active rke2-agent || true"
```

Wait until node3 shows `NotReady` in terminal 1 (up to a minute). Then, while
it is `NotReady`:

<!-- smoke: disruptive -->
```bash
$ kubectl get pods -A -o wide | grep -c Running
$ ssh node3 "ps -ef | grep -c '[c]ontainerd-shim'"
```

**Questions:**

- The pods on node3 still show `Running`. Is that true? The second command
  counts the container processes on node3.
- So what does `NotReady` really mean: "the containers are down" or "nobody
  is reporting"?

Bring it back and wait for `Ready`:

<!-- smoke: disruptive -->
```bash
$ ssh node3 sudo systemctl start rke2-agent
$ kubectl wait --for=condition=Ready nodes --all --timeout=180s
```

### B6. Leave it healthy

A node that was away needs a minute before everything reports healthy again:
Prometheus, for example, only notices on its next scrape. `--wait` repeats the
check until every line is green, for at most 3 minutes.

```bash
$ infra/platform/verify.sh --wait 180
```

### Checkpoint B ✅

- [ ] You know which systemd service runs on a server and which on an agent
- [ ] You can show a node's RKE2 config without showing the token
- [ ] You found the RKE2 service log on a server and on an agent
- [ ] node3 went `NotReady` and came back `Ready`
- [ ] `verify.sh` ends with `0 failed`

## If you're stuck

- node3 stays `NotReady`: `ssh node3 sudo systemctl restart rke2-agent`, then
  `ssh node3 "sudo journalctl -u rke2-agent --no-pager -n 30"`.
- `verify.sh --wait 180` still ends with red lines: note which ones and call
  the instructor (repair: `infra/platform/deploy.sh all`).

---

## ★ Build — install RKE2 yourself (bare start)

Do this part **instead of** parts A and B. 75 minutes. You install the server
by hand, so you see every step, then join the agents with Ansible.

### Build 1. Prepare node1

```bash
$ ssh node1
node1$ sudo swapoff -a && sudo sed -i '/\sswap\s/ s/^/#/' /etc/fstab
node1$ sudo mkdir -p /etc/rancher/rke2 /var/lib/rancher/rke2/server/manifests
```

### Build 2. Write the RKE2 config

Generate a join token. Any long random string works.

```bash
node1$ TOKEN=$(openssl rand -hex 24); echo $TOKEN
node1$ IP=$(hostname -I | awk '{print $1}'); echo $IP
```

```bash
node1$ sudo tee /etc/rancher/rke2/config.yaml <<EOF
token: ${TOKEN}
node-ip: ${IP}
tls-san:
  - ${IP}
  - $(hostname)
write-kubeconfig-mode: "0600"
cni: cilium
disable-kube-proxy: true
ingress-controller: traefik
etcd-snapshot-schedule-cron: "0 */6 * * *"
etcd-snapshot-retention: 10
etcd-expose-metrics: true
kube-controller-manager-arg: [bind-address=0.0.0.0]
kube-scheduler-arg: [bind-address=0.0.0.0]
EOF
```

**Question:** which line makes this cluster use Cilium? Which line means
there will be no `kube-proxy` pods?

### Build 3. Tell RKE2 how to configure Cilium

RKE2 applies every manifest in `server/manifests/` at start-up. This
`HelmChartConfig` overrides values of the Cilium chart that RKE2 ships.

```bash
node1$ sudo tee /var/lib/rancher/rke2/server/manifests/rke2-cilium-config.yaml <<'EOF'
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: rke2-cilium
  namespace: kube-system
spec:
  valuesContent: |-
    kubeProxyReplacement: true
    k8sServiceHost: "localhost"
    k8sServicePort: "6443"
    operator:
      replicas: 1
    prometheus:
      enabled: true
    hubble:
      enabled: true
      relay:
        enabled: true
      ui:
        enabled: true
      metrics:
        enabled: [dns, drop, tcp, flow, icmp, "httpV2"]
EOF
```

### Build 4. Install and start

Use the same RKE2 version as the rest of the class. It is the value of
`RKE2_VERSION` in `infra/versions.env` on your workstation:

```bash
$ grep RKE2_VERSION "$K8S_COURSE_HOME/infra/versions.env"
node1$ curl -sfL https://get.rke2.io | sudo INSTALL_RKE2_VERSION='<rke2-version>' sh -
node1$ sudo systemctl enable --now rke2-server
```

The command returns once the service has started. In a **second terminal**,
watch it come up (2–5 minutes):

```bash
node1$ sudo journalctl -u rke2-server -f
```

Look for: `etcd` starting, `kube-apiserver` becoming ready, `Applying
manifest … rke2-cilium`, and finally `Node controller sync successful`.

### Build 5. Use the bundled kubectl on the node

RKE2 ships its own `kubectl`, and the admin kubeconfig is readable only by root:

```bash
node1$ alias k='sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml'
node1$ k get nodes -o wide
node1$ k get pods -A
```

Wait until the node is `Ready` and the `cilium-*` pods are `Running`.

**Question:** the node was `NotReady` for a while at first. Why? (Hint: what
does a node need before pods can get an IP?)

### Build 6. Join the agents with Ansible

The playbook reads the join token from node1, installs `rke2-agent` on every
host in `[rke2_agents]`, and copies the admin kubeconfig to your workstation.

```bash
$ cd "$K8S_COURSE_HOME/infra/ansible"
$ ansible-galaxy collection install -r requirements.yml
$ ansible-playbook playbooks/join-agents.yml
```

While it runs, open `roles/rke2_agent/tasks/main.yml` and
`roles/rke2_agent/templates/config.yaml.j2`. Match each task to what you
did by hand on node1.

### Build 7. Health checks

```bash
$ cd "$K8S_COURSE_HOME"
$ kubectl get nodes -o wide
$ cilium status --wait
$ kubectl -n kube-system get helmcharts
$ infra/platform/deploy.sh network
$ infra/platform/verify.sh
```

`deploy.sh network` publishes the Hubble UI. `verify.sh` checks what is
installed so far and skips the layers you have not built yet.

### Build checkpoint ✅

- [ ] `kubectl get nodes` from your **workstation** shows 3 `Ready` nodes
- [ ] `cilium status` is all OK
- [ ] `verify.sh` ends with `0 failed` (later layers are skipped)
- [ ] You can explain what the `token` and `server:` lines in the agent config do

If the build does not come up, the instructor can rebuild your cluster with
the automated path. This **wipes the nodes**:

```bash
$ cd "$K8S_COURSE_HOME/infra/ansible"
$ ansible-playbook playbooks/reset.yml -e confirm=yes
$ ansible-playbook playbooks/site.yml
```

---

## ★ Stretch

- `node1$ sudo less /var/lib/rancher/rke2/agent/pod-manifests/kube-apiserver.yaml`:
  find three flags you can explain.
- Run `cilium connectivity test` (about 5 minutes; it creates and removes a
  test namespace).
- With the instructor's agreement only: on node1, move
  `kube-scheduler.yaml` out of `pod-manifests/` for a minute and watch
  `kubectl -n kube-system get pods -w`. Move it back.
