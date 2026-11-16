#!/usr/bin/env bash
# Lab 5: who can reach the backend right now, and does DNS work?
# Each check gives up after 5 seconds, so a blocked connection does not hang.
ns=lab5

# Without the lab's pods every check below would fail and look like "BLOCKED".
for who in frontend intruder backend; do
  if ! kubectl -n "$ns" rollout status "deployment/$who" --timeout=5s >/dev/null 2>&1; then
    echo "Cannot test: deployment '$who' in namespace '$ns' is missing or not ready." >&2
    echo "Look with:   kubectl -n $ns get deployments,pods     (lab step A1 creates them)" >&2
    exit 1
  fi
done

for who in frontend intruder; do
  if kubectl -n "$ns" exec "deployment/$who" -- timeout 5 wget -q -O /dev/null http://backend >/dev/null 2>&1; then
    echo "$who -> backend (HTTP):  ALLOWED"
  else
    echo "$who -> backend (HTTP):  BLOCKED"
  fi
done

# Judge the lookup by its answer, not its exit code: the nslookup in this image
# can exit 1 even when it found the address.
answer=$(kubectl -n "$ns" exec deployment/frontend -- timeout 5 nslookup "backend.$ns.svc.cluster.local" 2>&1)
if grep -q '^Name:' <<<"$answer"; then
  echo "frontend DNS lookup:        WORKS"
else
  echo "frontend DNS lookup:        FAILS"
fi
