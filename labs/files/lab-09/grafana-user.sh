#!/usr/bin/env bash
# Lab 9: look at, or delete, Grafana's own record of a user.
#
#   labs/files/lab-09/grafana-user.sh show <login>
#   labs/files/lab-09/grafana-user.sh delete <login>
#
# Grafana remembers everyone who ever logged in, together with the ID that
# Keycloak gave that person. If you delete a user in Keycloak and create a new
# one with the same name, Keycloak gives it a NEW ID. Grafana then sees a
# stranger who claims a name that is already taken, and refuses the login
# ("user sync failed"). Deleting Grafana's record clears that.
#
# Uses Grafana's local admin account (Secret grafana-admin, namespace monitoring).
set -euo pipefail

if [[ $# -ne 2 || ( "$1" != show && "$1" != delete ) ]]; then
  sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
fi
action=$1 login=$2

repo=$(cd "$(dirname "$0")/../../.." && pwd)
# shellcheck source=../../../infra/versions.env
source "$repo/infra/versions.env"
ip=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' | sed -E 's#https?://([^:/]+).*#\1#')
grafana="http://grafana.${ip}.${INGRESS_DOMAIN_SUFFIX}"
password=$(kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d)
api() { curl -sS --max-time 15 -u "admin:${password}" "$@"; }

found=$(api -G "$grafana/api/users/lookup" --data-urlencode "loginOrEmail=$login")
id=$(jq -r '.id // empty' <<<"$found")
if [[ -z "$id" ]]; then
  echo "Grafana has no user '$login'."
  exit 0
fi

if [[ "$action" == show ]]; then
  jq '{id, login, email, authLabels, isDisabled}' <<<"$found"
else
  api -X DELETE "$grafana/api/admin/users/$id" | jq -r '.message // .'
fi
