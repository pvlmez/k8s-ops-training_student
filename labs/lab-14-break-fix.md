# Lab 14 — Break and fix

**Time:** 60 min · **Mode:** fault 1 together with the
instructor, then in teams of two or three · **You will:** receive four
tickets, find the cause of each with the top-down method, repair it, and
write down what you found.

`$` = workstation · `<something>` = your own value · ★ = optional

A script breaks things for you and tells you when they are repaired:
`labs/files/lab-14/fault.sh`. Most faults live in a small "shop" in the
namespace `lab14`. Fault 4 touches the platform itself.

**The rules**

- Diagnose **before** you change anything. Write down the evidence.
- Work top-down: **node → pod → network → application**. Stop at the first
  layer that is not healthy.
- Do not read the fault script. Ask it for a hint instead:
  `labs/files/lab-14/fault.sh hint <n>` (three levels, each one stronger).
- One fault at a time. Repair it and get a green check before the next.

---

## The method

For every ticket, in this order:

| Step | Question | Typical commands |
|---|---|---|
| 1 | **What exactly is the symptom?** Reproduce it | The command or address from the ticket |
| 2 | **Nodes** healthy? | `kubectl get nodes`, `kubectl top nodes` |
| 3 | **Pods** healthy? | `kubectl -n <ns> get pods -o wide`, `describe pod`, `logs`, `logs --previous` |
| 4 | **Network**: can the request get there? | `get service,endpointslices,ingress,networkpolicies`, `hubble observe --verdict DROPPED` |
| 5 | **Application and what it depends on** | Its logs; `infra/platform/verify.sh` for Vault, Keycloak, Redis, Kafka |
| 6 | **What changed?** | `kubectl -n <ns> get events --sort-by=.lastTimestamp`, `rollout history`, `helm history` |
| 7 | Repair, **verify**, write it down | `fault.sh check <n>` |

Use this worksheet for each fault:

| | Fault 1 | Fault 2 | Fault 3 | Fault 4 |
|---|---|---|---|---|
| Symptom, reproduced | | | | |
| First unhealthy layer | | | | |
| The evidence (one line) | | | | |
| Cause | | | | |
| Repair | | | | |
| How to prevent or detect it sooner | | | | |

---

## Set up

```bash
$ cd "$K8S_COURSE_HOME"
$ infra/platform/verify.sh
$ labs/files/lab-14/fault.sh setup
$ labs/files/lab-14/fault.sh status
$ kubectl -n lab14 get deployments,services,ingress
$ kubectl -n lab14 exec deployment/client -- wget -qO- http://web | grep title
```

Everything is green. Open the shop's address (printed by `setup`) in your
browser, so you know what healthy looks like.

---

## Fault 1 — together with the instructor

<!-- smoke: skip (injects a fault that you repair by hand) -->
```bash
$ labs/files/lab-14/fault.sh inject 1
```

Read the ticket aloud. The instructor works through the method on the
projector; you type along and fill in the first column of the worksheet.

<!-- smoke: skip (after your repair) -->
```bash
$ labs/files/lab-14/fault.sh check 1
```

---

## Faults 2, 3 and 4 — in teams

Take them in order. About 12 minutes each.

<!-- smoke: skip (injects a fault that you repair by hand) -->
```bash
$ labs/files/lab-14/fault.sh inject 2
```

<!-- smoke: skip (after your repair) -->
```bash
$ labs/files/lab-14/fault.sh check 2
```

<!-- smoke: skip (injects a fault that you repair by hand) -->
```bash
$ labs/files/lab-14/fault.sh inject 3
```

<!-- smoke: skip (after your repair) -->
```bash
$ labs/files/lab-14/fault.sh check 3
```

Fault 4 affects the platform, not the shop:

<!-- smoke: skip (injects a fault that you repair by hand) -->
```bash
$ labs/files/lab-14/fault.sh inject 4
```

<!-- smoke: skip (after your repair) -->
```bash
$ labs/files/lab-14/fault.sh check 4
$ infra/platform/verify.sh --wait 180
```

Stuck for more than five minutes? Ask for a hint, then a stronger one:

<!-- smoke: skip (only when you are stuck) -->
```bash
$ labs/files/lab-14/fault.sh hint 2
```

Out of time on a fault? Let the script repair it, and read what it did
afterwards:

<!-- smoke: skip (only when time is up) -->
```bash
$ labs/files/lab-14/fault.sh fix 2
```

---

## Debrief

For each fault, one team tells the room:

- Which layer was the first unhealthy one, and which **one** command
  showed it?
- Was the first idea right? What sent you the wrong way?
- Which of these four have you met for real?
- What would have caught it **before** a user wrote a ticket: an alert, a
  dashboard, a line in `verify.sh`, a review of the change?

## Clean up

```bash
$ labs/files/lab-14/fault.sh status
$ labs/files/lab-14/fault.sh cleanup
$ infra/platform/verify.sh --wait 180
```

---

## Checkpoint ✅

- [ ] `fault.sh check` was green for faults 1 to 4
- [ ] Your worksheet has a cause and a piece of evidence for each fault
- [ ] You can describe the top-down order without looking it up
- [ ] The namespace `lab14` is gone and `verify.sh` ends with `0 failed`

## If you're stuck

- You changed several things and no longer know the state:
  `labs/files/lab-14/fault.sh status` shows which faults are still open;
  `labs/files/lab-14/fault.sh fix <n>` repairs one.
- The shop itself is damaged beyond the fault: `labs/files/lab-14/fault.sh
  cleanup`, then `setup` again.
- Vault stays sealed: `infra/platform/vault/init-unseal.sh`.
- The platform is unhealthy after the lab:
  `infra/platform/deploy.sh all`, then `infra/platform/verify.sh --wait 300`.

## ★ Stretch

Two more tickets, for teams that finish early:

- `labs/files/lab-14/fault.sh inject 5`: a StatefulSet that was "fixed an
  hour ago" and is still down.
- `labs/files/lab-14/fault.sh inject 6`: a new service that has been
  `Pending` since it was deployed.

And for the debrief:

- Write a seventh ticket for the team next to you: break something in the
  namespace `lab14` with one `kubectl` command, and hand them only the
  symptom.
- For fault 3, find the dropped packets in the Hubble UI. Which verdict and
  which destination port do you see?
