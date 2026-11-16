#!/usr/bin/env bash
# Deploy platform layers onto a running RKE2 cluster.
# Each layer is idempotent and can be re-run, so this is also the
# "catch-up" script for attendees who fall behind.
#
#   ./deploy.sh <layer> [<layer> ...]
#   ./deploy.sh all
#
# Layers, in dependency order:
#   network        Hubble UI ingress (Cilium itself is installed by RKE2)
#   storage        local-path-provisioner (default StorageClass)          lab 6
#   observability  kube-prometheus-stack, Loki, Fluent Bit                lab 7
#   vault          Vault: install, init/unseal, configure                 lab 8
#   keycloak       Keycloak Operator, Postgres, Keycloak, realm, Grafana SSO   lab 9
#   redis          redis-lab chart with password from Vault               lab 10
#   kafka          Strimzi operator, Kafka cluster, topics                lab 11
#
# Not part of "all" (deployed in lab 15, on top of every layer above):
#   app            the capstone demo app: Keycloak client, Vault secret, pods   lab 15
set -Eeuo pipefail   # -E: ERR trap also fires inside functions
source "$(dirname "$0")/lib.sh"

ALL_LAYERS=(network storage observability vault keycloak redis kafka)

deploy_network() {
  log "network: Cilium status and Hubble UI ingress"
  kubectl -n kube-system rollout status ds/cilium --timeout=300s
  render "$PLATFORM_DIR/network/hubble-ui-ingress.yaml" | kubectl apply -f -
  ok "Hubble UI: http://hubble.${DOMAIN}"
}

deploy_storage() {
  log "storage: local-path-provisioner"
  helm_install local-path-provisioner containeroo/local-path-provisioner local-path-storage "$CHART_LOCAL_PATH" \
    -f "$PLATFORM_DIR/storage/local-path-values.yaml" --wait
  ok "default StorageClass: $(kubectl get sc -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}')"
}

deploy_observability() {
  log "observability: kube-prometheus-stack"
  ensure_ns monitoring
  kubectl -n monitoring create secret generic grafana-admin \
    --from-literal=admin-user=admin --from-literal=admin-password="$(lab_secret grafana-admin)" \
    --dry-run=client -o yaml | kubectl apply -f -
  local sso=()
  kubectl -n monitoring get secret grafana-oauth >/dev/null 2>&1 && \
    sso=(-f <(render "$PLATFORM_DIR/observability/grafana-keycloak-sso.yaml"))
  helm_install kube-prometheus-stack prometheus-community/kube-prometheus-stack monitoring "$CHART_KUBE_PROM_STACK" \
    -f <(render "$PLATFORM_DIR/observability/kube-prometheus-stack.yaml") "${sso[@]}" --wait --timeout 10m

  log "observability: Loki"
  helm_install loki grafana-community/loki logging "$CHART_LOKI" \
    -f "$PLATFORM_DIR/observability/loki.yaml" --wait --timeout 10m

  log "observability: Fluent Bit"
  helm_install fluent-bit fluent/fluent-bit logging "$CHART_FLUENT_BIT" \
    -f "$PLATFORM_DIR/observability/fluent-bit.yaml" --wait

  ok "Grafana: http://grafana.${DOMAIN}  (admin / $(lab_secret grafana-admin))"
}

deploy_vault() {
  log "vault: Helm install"
  # Client-side apply: the injector patches its own webhook caBundle at
  # runtime, which conflicts with Helm 4 server-side apply on upgrade.
  # (--force-conflicts would "fix" the error by blanking the caBundle, which
  # silently breaks secret injection, so don't use it here.)
  local csa=()
  read -r -a csa <<<"$(helm_csa_flag)"
  helm_install vault hashicorp/vault vault "$CHART_VAULT" "${csa[@]}" \
    -f <(render "$PLATFORM_DIR/vault/values.yaml")
  # Pods created while the injector restarts are admitted without the agent,
  # so the layers after this one must not start before it injects again.
  wait_for vault deployment/vault-agent-injector RolledOut 300 app.kubernetes.io/name=vault-agent-injector
  for _ in $(seq 1 24); do injector_works && break; sleep 5; done
  injector_works || die "the Vault Agent Injector does not inject (see: kubectl -n vault logs deploy/vault-agent-injector)"
  ok "Vault Agent Injector injects"
  "$PLATFORM_DIR/vault/init-unseal.sh"
  "$PLATFORM_DIR/vault/configure.sh"
  ok "Vault UI: http://vault.${DOMAIN}  (root token in $SECRETS_DIR/vault-init.json)"
}

deploy_keycloak() {
  local base="https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/${KEYCLOAK_VERSION}/kubernetes"
  log "keycloak: operator ${KEYCLOAK_VERSION}"
  ensure_ns keycloak
  kubectl apply -f "$base/keycloaks.k8s.keycloak.org-v1.yml"
  kubectl apply -f "$base/keycloakrealmimports.k8s.keycloak.org-v1.yml"
  kubectl -n keycloak apply -f "$base/kubernetes.yml"
  wait_rollout keycloak deploy/keycloak-operator

  log "keycloak: secrets and PostgreSQL"
  kubectl -n keycloak create secret generic keycloak-db \
    --from-literal=username=keycloak --from-literal=password="$(lab_secret keycloak-db)" \
    --dry-run=client -o yaml | kubectl apply -f -
  for ns in keycloak monitoring; do
    ensure_ns "$ns"
    kubectl -n "$ns" create secret generic grafana-oauth \
      --from-literal=client-secret="$(lab_secret grafana-oauth)" \
      --dry-run=client -o yaml | kubectl apply -f -
  done
  render "$PLATFORM_DIR/keycloak/postgres.yaml" | kubectl apply -f -
  wait_rollout keycloak sts/postgres

  log "keycloak: Keycloak instance and 'platform' realm"
  render "$PLATFORM_DIR/keycloak/keycloak.yaml" | kubectl apply -f -
  # First start takes 2-4 minutes (Keycloak builds its config, then creates the DB schema)
  wait_for keycloak keycloak/keycloak Ready 600 app=keycloak
  render "$PLATFORM_DIR/keycloak/realm-platform.yaml" | kubectl apply -f -
  kubectl -n keycloak wait --for=condition=Done keycloakrealmimport/platform --timeout=300s || \
    warn "realm import not finished yet: kubectl -n keycloak get keycloakrealmimport platform -o yaml"

  if helm -n monitoring status kube-prometheus-stack >/dev/null 2>&1; then
    log "keycloak: enabling Grafana SSO"
    helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack -n monitoring \
      --reuse-values -f <(render "$PLATFORM_DIR/observability/grafana-keycloak-sso.yaml") --wait
  fi
  local pw
  pw=$(kubectl -n keycloak get secret keycloak-initial-admin -o jsonpath='{.data.password}' | base64 -d)
  ok "Keycloak: http://keycloak.${DOMAIN}  (temp-admin / ${pw})"
  ok "Realm 'platform' users: ops-admin / ChangeMe-Admin1, ops-user / ChangeMe-User1"
}

deploy_redis() {
  log "redis: redis-lab chart (password from Vault)"
  kubectl -n vault get pod vault-0 >/dev/null 2>&1 || die "deploy the vault layer first"
  # values-pinned.yaml (image digests) is written by infra/scripts/pin-versions.sh
  local pinned=()
  [[ -f "$PLATFORM_DIR/redis/values-pinned.yaml" ]] && pinned=(-f "$PLATFORM_DIR/redis/values-pinned.yaml")
  helm upgrade --install redis "$INFRA_DIR/charts/redis-lab" -n redis --create-namespace \
    -f "$PLATFORM_DIR/redis/values-vault.yaml" "${pinned[@]}"
  # Not "helm --wait": it waits silently. Not "pod/redis-0 Ready" either: right
  # after an upgrade that passes on the OLD pods, before they are replaced.
  wait_for redis statefulset/redis RolledOut 600 app.kubernetes.io/instance=redis
  ok "Redis: redis.redis.svc:6379"
}

deploy_kafka() {
  log "kafka: Strimzi operator"
  helm_install strimzi strimzi/strimzi-kafka-operator kafka "$CHART_STRIMZI" \
    -f "$PLATFORM_DIR/kafka/strimzi-values.yaml" --wait
  # Our manifests use the Strimzi v1 API (the only one from Strimzi 1.0 on;
  # first available in 0.49). Fail clearly if a pinned older operator lacks it.
  local served
  served=$(kubectl get crd kafkas.kafka.strimzi.io -o jsonpath='{.spec.versions[?(@.served==true)].name}')
  [[ " $served " == *" v1 "* ]] || \
    die "Strimzi CRDs serve only [$served]; the manifests need kafka.strimzi.io/v1 (Strimzi >= 0.49). Unpin or raise CHART_STRIMZI."
  log "kafka: cluster 'platform' (3 KRaft nodes; takes 3-5 minutes)"
  kubectl apply -f "$PLATFORM_DIR/kafka/kafka-cluster.yaml"
  wait_for kafka kafka/platform Ready 900 strimzi.io/cluster=platform
  kubectl apply -f "$PLATFORM_DIR/kafka/topics.yaml"
  load_strimzi_dashboards
  ok "Kafka bootstrap: platform-kafka-bootstrap.kafka.svc:9092"
}

# Strimzi publishes Grafana dashboards in its repo; load them as ConfigMaps
# that the Grafana sidecar picks up. Best effort: skipped if the download fails.
load_strimzi_dashboards() {
  local ver tmp
  ver=$(helm -n kafka list -f '^strimzi$' -o json | jq -r '.[0].app_version')
  tmp=$(mktemp -d)
  for d in strimzi-kafka strimzi-kafka-exporter strimzi-operators strimzi-kraft; do
    if curl -fsSL "https://raw.githubusercontent.com/strimzi/strimzi-kafka-operator/${ver}/packaging/examples/metrics/grafana-dashboards/${d}.json" -o "$tmp/$d.json"; then
      # Dashboards use a ${DS_PROMETHEUS} input; point it at the default datasource
      sed -i 's/\${DS_PROMETHEUS}/prometheus/g' "$tmp/$d.json"
      kubectl -n monitoring create configmap "dashboard-$d" --from-file="$d.json=$tmp/$d.json" \
        --dry-run=client -o yaml | kubectl label --local -f - grafana_dashboard=1 -o yaml | kubectl apply -f -
    else
      warn "could not download dashboard $d for Strimzi $ver (skipped)"
    fi
  done
  rm -rf "$tmp"
}

# The capstone demo app (apps/demo-app). Needs vault, keycloak, redis and kafka.
deploy_app() {
  local ns=demo-app app_dir="$INFRA_DIR/../apps/demo-app" layer
  log "app: checking the layers it depends on"
  for layer in vault keycloak redis kafka; do
    kubectl get ns "$layer" >/dev/null 2>&1 || die "the demo app needs the '$layer' layer: $0 $layer"
  done

  log "app: client secret into Vault (secret/demo-app/config)"
  local root_token oidc_secret
  root_token=$(jq -r .root_token "$SECRETS_DIR/vault-init.json")
  oidc_secret=$(lab_secret demo-oidc)
  kubectl -n vault exec -i vault-0 -- env VAULT_TOKEN="$root_token" \
    vault kv patch secret/demo-app/config oidc_client_secret="$oidc_secret" >/dev/null

  log "app: Keycloak client 'demo-app' in realm 'platform'"
  # A realm import never updates an existing realm, so the client is added with
  # Keycloak's admin tool, the same way lab 9 adds a user.
  local kc_user kc_pass
  kc_user=$(kubectl -n keycloak get secret keycloak-initial-admin -o jsonpath='{.data.username}' | base64 -d)
  kc_pass=$(kubectl -n keycloak get secret keycloak-initial-admin -o jsonpath='{.data.password}' | base64 -d)
  kcadm() { kubectl -n keycloak exec keycloak-0 -- /opt/keycloak/bin/kcadm.sh "$@" --config /tmp/kcadm-deploy.config; }
  kcadm config credentials --server http://localhost:8080 --realm master --user "$kc_user" --password "$kc_pass"
  if [[ -z "$(kcadm get clients -r platform -q clientId=demo-app --fields id --format csv --noquotes)" ]]; then
    kcadm create clients -r platform -s clientId=demo-app -s 'name=Demo app' -s enabled=true \
      -s protocol=openid-connect -s publicClient=false -s "secret=$oidc_secret" \
      -s standardFlowEnabled=true -s directAccessGrantsEnabled=false \
      -s "rootUrl=http://demo.${DOMAIN}" \
      -s "redirectUris=[\"http://demo.${DOMAIN}/callback\"]" \
      -s "webOrigins=[\"http://demo.${DOMAIN}\"]"
  else
    ok "client demo-app already exists"
  fi

  log "app: code (ConfigMap) and workloads"
  ensure_ns "$ns"
  kubectl -n "$ns" create configmap demo-app-code --from-file="$app_dir/app" \
    --dry-run=client -o yaml | kubectl apply -f -
  # The sidecars run Kafka's console tools from the image the brokers use.
  KAFKA_IMAGE=$(kubectl -n kafka get pods -l strimzi.io/broker-role=true \
    -o jsonpath='{.items[0].spec.containers[0].image}')
  [[ -n "$KAFKA_IMAGE" ]] || die "no Kafka broker pod found: $0 kafka"
  CODE_SUM=$(cat "$app_dir"/app/*.py | sha256sum | cut -c1-16)
  export KAFKA_IMAGE CODE_SUM
  render "$app_dir/manifests.yaml" | kubectl apply -f -
  wait_for "$ns" deployment/web Available 300 app.kubernetes.io/name=demo-app
  wait_for "$ns" deployment/worker Available 300 app.kubernetes.io/name=demo-app
  ok "Demo app: http://demo.${DOMAIN}  (log in as ops-user / ChangeMe-User1)"
}

on_error() {
  local rc=$?
  # Only report from the main shell: with set -E the trap is inherited by
  # $(...) and (...) subshells, whose failures don't necessarily stop us.
  [[ $BASH_SUBSHELL -eq 0 && -n "${CURRENT_LAYER:-}" ]] || return 0
  printf '\n\033[1;31m✘ Command failed (exit %s): %s\033[0m\n' "$rc" "$BASH_COMMAND" >&2
  printf '\n\033[1;31m✘ Layer "%s" failed. Later layers were NOT deployed.\033[0m\n' "$CURRENT_LAYER" >&2
  printf '  Fix the error above, then resume with:  %s %s\n' "$0" "$REMAINING_LAYERS" >&2
}
trap on_error ERR

main() {
  [[ $# -ge 1 ]] || { sed -n '2,20p' "$0"; exit 1; }
  require kubectl helm jq envsubst curl
  kubectl get nodes >/dev/null || die "cannot reach the cluster (check ~/.kube/config)"
  detect_ingress_ip
  helm_repos

  local layers=("$@")
  [[ "$1" == "all" ]] && layers=("${ALL_LAYERS[@]}")
  local i
  for i in "${!layers[@]}"; do
    declare -F "deploy_${layers[$i]}" >/dev/null || die "unknown layer: ${layers[$i]} (choose from: ${ALL_LAYERS[*]} app)"
  done
  for i in "${!layers[@]}"; do
    CURRENT_LAYER=${layers[$i]}
    REMAINING_LAYERS="${layers[*]:$i}"
    "deploy_$CURRENT_LAYER"
  done
  log "Done: ${layers[*]}"
}

main "$@"
