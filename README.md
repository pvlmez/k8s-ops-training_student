# Kubernetes Platform Operations: course material

Everything you need for the labs, and to keep as reference afterwards. Put
this directory anywhere on your workstation and run
`infra/scripts/install-tools.sh` from it once: that records the location in
the shell variable `K8S_COURSE_HOME`. The lab guides start with
`cd "$K8S_COURSE_HOME"` and run every command from there. Moved the
directory? Run the script again and open a new terminal.

| Where | What |
|---|---|
| `labs/lab-NN-*.md` | Lab guides. Start with `labs/lab-01-first-contact.md` |
| `labs/files/lab-NN/` | Manifests and helper scripts the labs use |
| `slides/*.pdf` | The slide decks, numbered in teaching order |
| `docs/cheatsheets/part-N.md` | One-page command reference per part of the course |
| `docs/environment.md` | Your lab environment: nodes, sizes, addresses, ports |
| `infra/` | The automation that built your cluster: Ansible playbooks, `platform/deploy.sh`, the `redis-lab` chart, version pins |
| `apps/demo-app/` | The demo application of the capstone lab |

## The three commands to remember

```bash
infra/scripts/lab-info.sh           # your nodes and the addresses of the web UIs
infra/platform/verify.sh            # is my cluster healthy? Every line should be green
infra/platform/deploy.sh <layer>    # catch up: (re)install one layer; safe to run again
```

Layers: `network storage observability vault keycloak redis kafka`, or `all`.

## How to read a lab guide

- `$` is a command on your workstation; `node1$` is a command on that node
  (`ssh node1` first).
- Each lab has an **Explore** part, an **Operate** part and an optional
  **★ Build** part, and ends with a **Checkpoint ✅** list.
- ⚠️ marks a shortcut that is fine in the lab and wrong in production; the
  text names what production does instead.
- Stuck? Every lab has an "If you're stuck" section with the catch-up command.

`infra/platform/.secrets/` and `infra/ansible/credentials/` appear on your
workstation once the cluster is built. They hold the lab's passwords, the
Vault unseal keys and the join token: never copy them anywhere else.
