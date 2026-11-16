#!/usr/bin/env bash
# Print the latest available chart/app versions so the instructor can pin
# them in infra/versions.env before a class.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=../versions.env
source versions.env

helm repo add prometheus-community "$REPO_PROMETHEUS"      >/dev/null 2>&1 || true
helm repo add grafana-community    "$REPO_GRAFANA_COMMUNITY" >/dev/null 2>&1 || true
helm repo add fluent               "$REPO_FLUENT"           >/dev/null 2>&1 || true
helm repo add hashicorp            "$REPO_HASHICORP"        >/dev/null 2>&1 || true
helm repo add strimzi              "$REPO_STRIMZI"          >/dev/null 2>&1 || true
helm repo add containeroo          "$REPO_LOCAL_PATH"       >/dev/null 2>&1 || true
helm repo update >/dev/null

printf '%-48s %-14s %s\n' CHART "CHART VER" "APP VER"
for c in containeroo/local-path-provisioner prometheus-community/kube-prometheus-stack \
         grafana-community/loki fluent/fluent-bit hashicorp/vault strimzi/strimzi-kafka-operator; do
  helm search repo "$c" --output json | jq -r --arg c "$c" \
    '.[] | select(.name==$c) | "\(.name) \(.version) \(.app_version)"' |
    awk '{printf "%-48s %-14s %s\n", $1, $2, $3}'
done

echo
echo "RKE2 releases in channel ${RKE2_CHANNEL}:"
curl -fsSL "https://update.rke2.io/v1-release/channels/${RKE2_CHANNEL}" -o /dev/null -w '  latest -> %{redirect_url}\n' || true
echo "Keycloak: check https://github.com/keycloak/keycloak/releases (currently pinned ${KEYCLOAK_VERSION})"
