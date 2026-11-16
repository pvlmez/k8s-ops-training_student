#!/usr/bin/env bash
# Initialise (first run only) and unseal Vault.
# LAB ONLY: the unseal keys and root token are written to
# infra/platform/.secrets/vault-init.json. In production the 5 key shares go
# to 5 different people, or auto-unseal is used, and the root token is revoked.
set -euo pipefail
source "$(dirname "$0")/../lib.sh"

NS=vault
INIT_FILE="$SECRETS_DIR/vault-init.json"
vexec() { kubectl -n "$NS" exec vault-0 -- "$@"; }

log "Waiting for vault-0 to be running"
kubectl -n "$NS" wait --for=jsonpath='{.status.phase}'=Running pod/vault-0 --timeout=300s

STATUS=$(vexec vault status -format=json 2>/dev/null || true)
if [[ "$(jq -r .initialized <<<"$STATUS")" != "true" ]]; then
  log "Initialising Vault (5 key shares, threshold 3)"
  vexec vault operator init -key-shares=5 -key-threshold=3 -format=json > "$INIT_FILE"
  chmod 600 "$INIT_FILE"
  ok "keys saved to $INIT_FILE"
  STATUS=$(vexec vault status -format=json 2>/dev/null || true)
fi

[[ -s "$INIT_FILE" ]] || die "Vault is initialised but $INIT_FILE is missing; unseal by hand with the keys you saved."

for pod in $(kubectl -n "$NS" get pods -l app.kubernetes.io/name=vault,component=server -o name); do
  if [[ "$(kubectl -n "$NS" exec "${pod#pod/}" -- vault status -format=json 2>/dev/null | jq -r .sealed)" == "true" ]]; then
    log "Unsealing ${pod#pod/}"
    for i in 0 1 2; do
      key=$(jq -r ".unseal_keys_b64[$i]" "$INIT_FILE")
      kubectl -n "$NS" exec "${pod#pod/}" -- vault operator unseal "$key" >/dev/null
    done
  fi
  ok "${pod#pod/} unsealed"
done
