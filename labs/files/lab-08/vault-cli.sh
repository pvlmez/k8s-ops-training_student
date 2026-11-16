# Lab 8: shortcuts for talking to Vault. Load them into your shell with
#
#   source labs/files/lab-08/vault-cli.sh
#
# (again in every new terminal). You then have:
#
#   v <vault arguments>     runs the vault command inside the pod vault-0, logged
#                           in with the root token.   Example:  v secrets list
#   unseal_key <0-4>        prints one of the five unseal keys
#
# LAB ONLY: both read infra/platform/.secrets/vault-init.json, where this lab
# keeps all five unseal keys and the root token in one file. In production the
# key shares are held by different people (or auto-unseal is used), the root
# token is revoked after setup, and you log in as yourself (OIDC, LDAP).
# shellcheck shell=bash

VAULT_INIT_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/infra/platform/.secrets/vault-init.json"

_vault_init_file() {
  if [[ ! -s "$VAULT_INIT_FILE" ]]; then
    echo "Missing $VAULT_INIT_FILE: this workstation did not initialise Vault. Ask the instructor." >&2
    return 1
  fi
}

v() {
  _vault_init_file || return 1
  kubectl -n vault exec -i vault-0 -- env VAULT_TOKEN="$(jq -r .root_token "$VAULT_INIT_FILE")" vault "$@"
}

unseal_key() {
  _vault_init_file || return 1
  jq -r ".unseal_keys_b64[${1:?give a key number from 0 to 4}]" "$VAULT_INIT_FILE"
}

echo "Loaded: v (vault as root, LAB ONLY) and unseal_key. Try:  v status"
