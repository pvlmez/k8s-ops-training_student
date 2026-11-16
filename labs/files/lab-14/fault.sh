#!/usr/bin/env bash
# Lab 14: break the platform in a known way, and check whether it is repaired.
#
#   fault.sh setup          create the namespace lab14 with a small, healthy "shop"
#   fault.sh inject <n>     cause fault n (1-6) and print the ticket a user would send
#   fault.sh check <n>      is fault n repaired?  (exit code 0 = yes)
#   fault.sh hint <n>       a nudge in the right direction; ask again for a stronger one
#   fault.sh status         check all six
#   fault.sh fix <n>        repair fault n for you (instructor, or when time is up)
#   fault.sh cleanup        repair everything and delete the namespace lab14
#   fault.sh selftest       instructor: inject, verify, fix and re-check faults 1-3, 5, 6
#   fault.sh selftest --all the same including fault 4, which seals Vault
#
# Faults 1-4 are the lab; 5 and 6 are the stretch goals. Fault 4 seals Vault and
# deletes the Redis replica pod; the others only touch the namespace lab14.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
# shellcheck source=../../../infra/versions.env
source "$repo/infra/versions.env"
ns=lab14
good_image=docker.io/library/nginx:1.27-alpine
hint_dir="${TMPDIR:-/tmp}/lab14-hints-$(id -u)"

ip() { kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' | sed -E 's#https?://([^:/]+).*#\1#'; }
shop_url() { echo "http://shop.$(ip).${INGRESS_DOMAIN_SUFFIX}"; }
k() { kubectl -n "$ns" "$@"; }
say() { printf '%s\n' "$*"; }
good() { printf '\033[1;32m  ✔ fault %s: %s\033[0m\n' "$1" "$2"; }
bad() { printf '\033[1;31m  ✘ fault %s: %s\033[0m\n' "$1" "$2"; }
need_number() {
  case "${1:-}" in 1 | 2 | 3 | 4 | 5 | 6) ;; *) say "Give a fault number from 1 to 6." >&2; exit 2 ;; esac
}
need_shop() {
  if ! k get deployment web >/dev/null 2>&1; then
    say "The shop is not there yet. Run:  labs/files/lab-14/fault.sh setup" >&2
    exit 1
  fi
}
ticket() {
  printf '\n\033[1;33m┌─ TICKET %s ─────────────────────────────────────────────\033[0m\n' "$1"
  shift
  printf '\033[1;33m│\033[0m %s\n' "$@"
  printf '\033[1;33m└────────────────────────────────────────────────────────\033[0m\n\n'
}
vault_as_root() {
  kubectl -n vault exec -i vault-0 -- env VAULT_TOKEN="$(jq -r .root_token "$repo/infra/platform/.secrets/vault-init.json")" vault "$@"
}
vault_sealed() {
  [[ "$(kubectl -n vault exec vault-0 -- vault status -format=json 2>/dev/null | jq -r .sealed)" != "false" ]]
}

setup() {
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  k apply -f "$here/shop.yaml"
  k get ingress shop >/dev/null 2>&1 ||
    k create ingress shop --class=traefik --rule="shop.$(ip).${INGRESS_DOMAIN_SUFFIX}/*=web:80"
  k rollout status deployment/web --timeout=180s
  k rollout status deployment/client --timeout=180s
  # The ingress route needs a few seconds before Traefik serves it.
  local try
  for try in $(seq 1 30); do
    curl -fsS -o /dev/null --max-time 5 "$(shop_url)/" && break
    sleep 2
  done
  say ""
  say "The shop is running in the namespace $ns:  $(shop_url)"
  say "From inside the cluster:  kubectl -n $ns exec deployment/client -- wget -qO- http://web | grep title"
}

# --- the faults ---------------------------------------------------------------

inject() {
  need_shop
  case "$1" in
    1)
      k patch service web --type merge -p '{"spec":{"selector":{"app":"shop-wbe"}}}' >/dev/null
      ticket 1 "From: web team" \
        "\"The shop at $(shop_url) has been down for ten minutes." \
        "Our pods are all Running and we did not deploy anything." \
        "Somebody tidied up the Service definitions a few hours ago.\""
      ;;
    2)
      k patch deployment web --type json -p '[{"op":"add","path":"/spec/template/spec/containers/0/command","value":["nginx","-c","/etc/nginx/shop.conf","-g","daemon off;"]}]' >/dev/null
      ticket 2 "From: monitoring" \
        "\"Deployment web in namespace $ns: a rollout started 20 minutes ago and" \
        "has not finished. One pod keeps restarting. The shop itself still answers," \
        "for now. The change was described as 'use our own nginx config'.\""
      ;;
    3)
      k apply -f "$here/fault-3-policy.yaml" >/dev/null
      ticket 3 "From: batch team" \
        "\"Our client pod in namespace $ns cannot reach the shop any more:" \
        "  kubectl -n $ns exec deployment/client -- wget -qO- http://web" \
        "says 'bad address'. The shop works fine from a browser. Security applied" \
        "change CHG-2041 yesterday and says it explicitly allows us to call the shop.\""
      ;;
    4)
      if [[ ! -s "$repo/infra/platform/.secrets/vault-init.json" ]]; then
        say "This workstation has no Vault keys file, so it could not unseal afterwards. Not injecting fault 4." >&2
        exit 1
      fi
      vault_as_root operator seal >/dev/null
      kubectl -n redis delete pod redis-1 --wait=false >/dev/null
      ticket 4 "From: cache team" \
        "\"We restarted our Redis replica (redis-1 in namespace redis) for a routine" \
        "check and it does not come back. redis-0 is fine. We changed nothing." \
        "Also, the platform health check has a red line.\""
      ;;
    5)
      k apply -f "$here/fault-5-ledger.yaml" >/dev/null
      sleep 20
      k set image statefulset/ledger "ledger=$good_image" >/dev/null
      ticket 5 "From: finance team   (★ stretch)" \
        "\"Our StatefulSet ledger in namespace $ns had a typo in the image name." \
        "We corrected it an hour ago; 'kubectl -n $ns get statefulset ledger -o yaml'" \
        "shows the right image. It is still not running. Is the cluster broken?\""
      ;;
    6)
      k apply -f "$here/fault-6-reports.yaml" >/dev/null
      ticket 6 "From: reporting team   (★ stretch)" \
        "\"We deployed our new service 'reports' in namespace $ns from" \
        "labs/files/lab-14/fault-6-reports.yaml. The pod has been Pending ever since." \
        "The same file works on our other cluster.\""
      ;;
  esac
  rm -f "$hint_dir/$1"
  say "When you think it is repaired:  labs/files/lab-14/fault.sh check $1"
}

check() {  # prints one line, returns 0 when healthy
  case "$1" in
    1)
      if curl -fsS -o /dev/null --max-time 5 "$(shop_url)/"; then good 1 "the shop answers at $(shop_url)"
      else bad 1 "the shop does not answer at $(shop_url)"; return 1; fi
      ;;
    2)
      if k rollout status deployment/web --timeout=5s >/dev/null 2>&1 &&
        ! k get pods -l app=shop-web --no-headers 2>/dev/null | grep -Ev ' Running ' | grep -q .; then
        good 2 "the rollout of deployment web is complete and every pod is Running"
      else bad 2 "deployment web has not finished rolling out, or a pod is not Running"; return 1; fi
      ;;
    3)
      if k exec deployment/client -- timeout 5 wget -q -O /dev/null http://web >/dev/null 2>&1; then
        good 3 "the client pod reaches http://web"
      else bad 3 "the client pod cannot reach http://web"; return 1; fi
      ;;
    4)
      if vault_sealed; then bad 4 "Vault is sealed"; return 1; fi
      if kubectl -n redis wait --for=condition=Ready pod/redis-1 --timeout=5s >/dev/null 2>&1; then
        good 4 "Vault is unsealed and redis-1 is Ready"
      else bad 4 "Vault is unsealed, but redis-1 is not Ready (yet)"; return 1; fi
      ;;
    5)
      if ! k get statefulset ledger >/dev/null 2>&1; then good 5 "not injected (no StatefulSet ledger)"; return 0; fi
      if [[ "$(k get statefulset ledger -o jsonpath='{.status.readyReplicas}')" == "2" ]]; then
        good 5 "StatefulSet ledger has 2 of 2 pods Ready"
      else bad 5 "StatefulSet ledger does not have 2 pods Ready"; return 1; fi
      ;;
    6)
      if ! k get deployment reports >/dev/null 2>&1; then good 6 "not injected (no deployment reports)"; return 0; fi
      if k rollout status deployment/reports --timeout=5s >/dev/null 2>&1; then
        good 6 "deployment reports is running"
      else bad 6 "deployment reports is not running"; return 1; fi
      ;;
  esac
}

hint() {
  mkdir -p "$hint_dir"
  local level=1
  [[ -f "$hint_dir/$1" ]] && level=$(($(cat "$hint_dir/$1") + 1))
  ((level > 3)) && level=3
  echo "$level" >"$hint_dir/$1"
  local -a h
  case "$1" in
    1) h=("Work top-down: is the node fine? the pods? Then follow the request: Ingress -> Service -> pods. Where does it stop?"
      "A Service finds its pods through a label selector. What does 'kubectl -n $ns get endpointslices' show?"
      "Compare 'kubectl -n $ns get service web -o yaml' (selector) with 'kubectl -n $ns get pods --show-labels'.") ;;
    2) h=("Which pod is unhappy, and what state is it in? 'kubectl -n $ns get pods'."
      "A container that starts and dies has usually said why. 'kubectl -n $ns logs <pod>' (add --previous if needed)."
      "The new pods are started with a different command than the old ones. 'kubectl -n $ns rollout history deployment/web', and remember lab 4: a rollout can be undone.") ;;
    3) h=("'bad address' is not 'connection refused'. Which step of reaching http://web fails first?"
      "What applies to the client pod? 'kubectl -n $ns get networkpolicies', then read the policy. Hubble shows drops: 'hubble observe --namespace $ns --verdict DROPPED'."
      "The policy allows the client to call the shop on port 80. What does a pod have to do BEFORE it can call a name? (Lab 5, step B4.)") ;;
    4) h=("Start with the health check: 'infra/platform/verify.sh'. Which line is red?"
      "Look at the stuck pod: 'kubectl -n redis get pods' and 'kubectl -n redis logs redis-1 -c vault-agent-init --tail=5'."
      "'kubectl -n vault exec vault-0 -- vault status'. Lab 8, step A7.") ;;
    5) h=("Believe the team: the StatefulSet's spec is right. So look at the pod, not the StatefulSet."
      "Which image is the POD using? 'kubectl -n $ns get pod ledger-0 -o jsonpath={.spec.containers[0].image}'."
      "A StatefulSet does not replace a pod that never became Ready (lab 6, step B6). What do you have to do yourself?") ;;
    6) h=("Why is a pod Pending? The scheduler says so: 'kubectl -n $ns describe pod -l app=reports', Events."
      "The pod waits for its volume. 'kubectl -n $ns get pvc' and 'kubectl -n $ns describe pvc reports-data'. Then 'kubectl get storageclass'."
      "The class name of an existing claim cannot be changed. Delete what the file created, correct a copy of the file, apply the copy.") ;;
  esac
  say "Hint $level of 3 for fault $1:"
  say "  ${h[$((level - 1))]}"
}

fix() {
  case "$1" in
    1) k patch service web --type merge -p '{"spec":{"selector":{"app":"shop-web"}}}' >/dev/null ;;
    2)
      k patch deployment web --type json -p '[{"op":"remove","path":"/spec/template/spec/containers/0/command"}]' >/dev/null 2>&1 || true
      k rollout status deployment/web --timeout=180s >/dev/null
      ;;
    3) k delete networkpolicy hardening --ignore-not-found >/dev/null ;;
    4)
      "$repo/infra/platform/vault/init-unseal.sh" >/dev/null
      kubectl -n redis rollout status statefulset/redis --timeout=300s >/dev/null
      ;;
    5)
      k delete pod ledger-0 --ignore-not-found >/dev/null
      k rollout status statefulset/ledger --timeout=180s >/dev/null
      ;;
    6)
      k delete -f "$here/fault-6-reports.yaml" --ignore-not-found >/dev/null
      sed 's/storageClassName: fast-ssd/storageClassName: local-path/' "$here/fault-6-reports.yaml" | k apply -f - >/dev/null
      k rollout status deployment/reports --timeout=180s >/dev/null
      ;;
  esac
  say "Fault $1 repaired by the script."
}

status() {
  local n rc=0
  for n in 1 2 3 4 5 6; do check "$n" || rc=1; done
  return $rc
}

cleanup() {
  if vault_sealed && [[ -s "$repo/infra/platform/.secrets/vault-init.json" ]]; then
    say "Vault is sealed: unsealing it."
    fix 4
  fi
  kubectl delete namespace "$ns" --ignore-not-found
  rm -rf "$hint_dir"
  say "Namespace $ns removed. Check the platform:  infra/platform/verify.sh --wait 180"
}

selftest() {
  local faults=(1 2 3 5 6) n rc=0
  [[ "${1:-}" == "--all" ]] && faults=(1 2 3 4 5 6)
  setup >/dev/null || { say "setup failed"; return 1; }
  for n in "${faults[@]}"; do
    inject "$n" >/dev/null
    sleep 30          # give the fault time to show
    if check "$n" >/dev/null 2>&1; then
      bad "$n" "SELFTEST: injected, but the check still says healthy"
      rc=1
    fi
    fix "$n" >/dev/null
    sleep 10
    if check "$n" >/dev/null 2>&1; then
      good "$n" "SELFTEST: breaks when injected, healthy again after the fix"
    else
      bad "$n" "SELFTEST: still broken after the scripted fix"
      rc=1
    fi
  done
  return $rc
}

case "${1:-}" in
  setup) setup ;;
  inject) need_number "${2:-}"; inject "$2" ;;
  check) need_number "${2:-}"; check "$2" ;;
  hint) need_number "${2:-}"; hint "$2" ;;
  fix) need_number "${2:-}"; fix "$2" ;;
  status) status ;;
  cleanup) cleanup ;;
  selftest) selftest "${2:-}" ;;
  *)
    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
