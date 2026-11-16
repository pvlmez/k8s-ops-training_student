#!/usr/bin/env bash
# Health check for the whole platform. Prints one line per check.
# Instructors: run against each attendee cluster before a lab starts.
#
#   verify.sh              # check once
#   verify.sh --wait 180   # after a restart or a deploy: re-check every 15s until
#                          # everything is green or 180s have passed, then report
set -uo pipefail

if [[ "${1:-}" == "--wait" ]]; then
  limit=${2:-180}
  until bash "$0" >/dev/null 2>&1; do
    (( SECONDS >= limit )) && break
    printf '  not all green yet; checking again in 15s (waited %ss of %ss)\n' "$SECONDS" "$limit"
    sleep 15
  done
  exec bash "$0"
fi
source "$(dirname "$0")/lib.sh"
detect_ingress_ip

PASS=0; FAIL=0; SKIP=0
check() {  # description, command...
  local desc=$1; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; PASS=$((PASS+1)); else printf '\033[1;31m  ✘ %s\033[0m\n' "$desc"; FAIL=$((FAIL+1)); fi
}
installed() { kubectl get ns "$1" >/dev/null 2>&1; }
skip() { printf '\033[0;37m  - %s (not deployed yet: namespace missing)\033[0m\n' "$1"; SKIP=$((SKIP+1)); }

all_ready() {  # ns selector -> every matching pod Ready
  local out
  out=$(kubectl -n "$1" get pods -l "$2" -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}')
  [[ -n "$out" ]] && ! grep -qv True <<<"$out"
}
http_ok() { curl -fsS -o /dev/null --max-time 5 "$1"; }

# Log in to Grafana through Keycloak the way a browser does, with curl and a
# cookie jar: Grafana redirects to Keycloak's login form, we post the
# credentials, Keycloak redirects back and Grafana (inside its pod) exchanges
# the code for a token. Passes only if Grafana then knows us as that user.
# Tests from this machine: it says nothing about a browser somewhere else.
grafana_sso_login() {  # user password
  local jar page action rc=1
  jar=$(mktemp)
  page=$(curl -sS -L --max-time 20 -c "$jar" -b "$jar" "http://grafana.${DOMAIN}/login/generic_oauth")
  # The login form's target: <form id="kc-form-login" ... action="...">
  action=$(grep -o 'action="[^"]*"' <<<"$page" | sed -n '1{s/^action="//;s/"$//;s/&amp;/\&/g;p;}')
  if [[ -n "$action" ]]; then
    curl -sS -L --max-time 30 -c "$jar" -b "$jar" -o /dev/null \
      --data-urlencode "username=$1" --data-urlencode "password=$2" --data-urlencode "credentialId=" "$action"
    curl -fsS --max-time 10 -b "$jar" "http://grafana.${DOMAIN}/api/user" | jq -e --arg u "$1" '.login == $u' >/dev/null
    rc=$?
  fi
  rm -f "$jar"
  return $rc
}

log "Cluster"
check "API server reachable"                    kubectl get --raw /readyz
check "all nodes Ready"                         bash -c '! kubectl get nodes --no-headers | grep -vw Ready'
check "no pods stuck (Pending/CrashLoop/Error)" bash -c '! kubectl get pods -A --no-headers | grep -E "Pending|CrashLoopBackOff|Error|ImagePullBackOff"'

log "Networking (Cilium, CoreDNS, Traefik)"
check "Cilium agents Ready"                     all_ready kube-system k8s-app=cilium
check "cilium status OK"                        cilium status --wait-duration 10s
check "CoreDNS Ready"                           all_ready kube-system k8s-app=kube-dns
check "Traefik Ready"                           kubectl -n kube-system rollout status ds/rke2-traefik --timeout=5s
check "Hubble UI via ingress"                   http_ok "http://hubble.${DOMAIN}"

log "Storage"
if installed local-path-storage; then
  check "default StorageClass exists"           bash -c 'kubectl get sc -o json | jq -e ".items[] | select(.metadata.annotations[\"storageclass.kubernetes.io/is-default-class\"]==\"true\")"'
else skip "local-path-provisioner"; fi

log "Observability"
if installed monitoring; then
  check "Prometheus Ready"                      all_ready monitoring app.kubernetes.io/name=prometheus
  check "Grafana Ready"                         all_ready monitoring app.kubernetes.io/name=grafana
  check "Grafana via ingress"                   http_ok "http://grafana.${DOMAIN}/api/health"
  check "Prometheus has no down targets"        bash -c "curl -fsS http://prometheus.${DOMAIN}/api/v1/targets | jq -e '[.data.activeTargets[] | select(.health==\"down\")] | length == 0'"
else skip "kube-prometheus-stack"; fi
if installed logging; then
  check "Loki Ready"                            all_ready logging app.kubernetes.io/name=loki
  check "Fluent Bit Ready on every node"        all_ready logging app.kubernetes.io/name=fluent-bit
else skip "Loki / Fluent Bit"; fi

log "Vault"
if installed vault; then
  check "vault-0 unsealed"                      bash -c 'kubectl -n vault exec vault-0 -- vault status -format=json | jq -e ".sealed==false"'
  check "Agent Injector Ready"                  all_ready vault app.kubernetes.io/name=vault-agent-injector
  check "Agent Injector injects (dry-run pod)"  injector_works
  # A pod created while the injector did not answer runs without its secrets.
  check "every pod that asks for the agent has it" no_uninjected_pods
else skip "Vault"; fi

log "Keycloak"
if installed keycloak; then
  check "PostgreSQL Ready"                      all_ready keycloak app.kubernetes.io/name=postgres
  check "Keycloak CR Ready"                     kubectl -n keycloak wait --for=condition=Ready keycloak/keycloak --timeout=5s
  check "realm 'platform' reachable"            http_ok "http://keycloak.${DOMAIN}/realms/platform/.well-known/openid-configuration"
  # Uses the realm user that deploy.sh creates. Fails if that password was changed.
  if installed monitoring && kubectl -n monitoring get secret grafana-oauth >/dev/null 2>&1; then
    check "Grafana login through Keycloak (SSO)" grafana_sso_login ops-admin ChangeMe-Admin1
  fi
else skip "Keycloak"; fi

log "Redis"
if installed redis; then
  check "Redis pods Ready"                      all_ready redis app.kubernetes.io/name=redis-lab
  # A pod created while the Vault injector was down runs without the password
  # file. Without a password, redis-cli gets NOAUTH; anything else means trouble.
  check "Redis primary requires a password"     bash -c 'kubectl -n redis exec redis-0 -c redis -- redis-cli -h 127.0.0.1 ping 2>&1 | grep -q NOAUTH'
  check "Redis replication link up"            bash -c 'kubectl -n redis exec redis-1 -c redis -- sh -c ". /scripts/password.sh; redis-cli info replication" | grep -q "master_link_status:up"'
else skip "Redis"; fi

log "Kafka"
if installed kafka; then
  check "Kafka CR Ready"                        kubectl -n kafka wait --for=condition=Ready kafka/platform --timeout=5s
  check "all KafkaTopics Ready"                 bash -c '! kubectl -n kafka get kafkatopics -o jsonpath="{range .items[*]}{.status.conditions[0].type}{\"\n\"}{end}" | grep -v Ready'
else skip "Kafka"; fi

log "Demo app (lab 15)"
if installed demo-app; then
  check "web and worker pods Ready"             all_ready demo-app app.kubernetes.io/name=demo-app
  check "demo app via ingress"                  http_ok "http://demo.${DOMAIN}/readyz"
else skip "Demo app"; fi

echo
printf 'Result: \033[1;32m%d passed\033[0m, \033[1;31m%d failed\033[0m, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[[ $FAIL -eq 0 ]]
