#!/usr/bin/env bash
# Configure Vault for the platform (the end state of lab 8):
#   - KV v2 secrets engine at secret/
#   - Kubernetes auth method
#   - policies + roles for redis and the demo app
#   - seed secrets
# Idempotent: re-running keeps existing secret values.
set -euo pipefail
source "$(dirname "$0")/../lib.sh"

NS=vault
ROOT_TOKEN=$(jq -r .root_token "$SECRETS_DIR/vault-init.json")
v() { kubectl -n "$NS" exec -i vault-0 -- env VAULT_TOKEN="$ROOT_TOKEN" vault "$@"; }

log "Secrets engine: kv-v2 at secret/"
v secrets list -format=json | jq -e '."secret/"' >/dev/null 2>&1 || v secrets enable -path=secret kv-v2

log "Auth method: kubernetes"
v auth list -format=json | jq -e '."kubernetes/"' >/dev/null 2>&1 || v auth enable kubernetes
# Inside the pod Vault uses its own service account token to call the
# TokenReview API, so only the API address is needed.
v write auth/kubernetes/config kubernetes_host="https://kubernetes.default.svc:443"

log "Policies"
v policy write redis - <<'EOF'
path "secret/data/platform/redis" { capabilities = ["read"] }
EOF
v policy write demo-app - <<'EOF'
path "secret/data/platform/redis"   { capabilities = ["read"] }
path "secret/data/demo-app/*"       { capabilities = ["read"] }
EOF

log "Kubernetes auth roles (service account + namespace -> policy)"
v write auth/kubernetes/role/redis \
  bound_service_account_names=redis bound_service_account_namespaces=redis \
  policies=redis ttl=1h
v write auth/kubernetes/role/demo-app \
  bound_service_account_names=demo-app bound_service_account_namespaces=demo-app \
  policies=demo-app ttl=1h

log "Seed secrets"
if ! v kv get secret/platform/redis >/dev/null 2>&1; then
  v kv put secret/platform/redis password="$(lab_secret redis-password)"
fi
if ! v kv get secret/demo-app/config >/dev/null 2>&1; then
  v kv put secret/demo-app/config api_key="$(lab_secret demo-api-key)" greeting="Hello from Vault"
fi
ok "Vault configured"
