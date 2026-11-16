#!/usr/bin/env bash
# Lab 9: run Keycloak's admin command line tool (kcadm.sh) inside the
# Keycloak pod. Everything you can click in the admin console can be done
# with it, which is how changes are scripted.
#
#   labs/files/lab-09/kc.sh login                       log in as the admin (do this first)
#   labs/files/lab-09/kc.sh user-id <username>          print the internal ID of a user in realm "platform"
#   labs/files/lab-09/kc.sh <any kcadm arguments>       for example:  get users -r platform
#
# LAB ONLY: "login" uses the bootstrap admin account from the Secret
# keycloak-initial-admin. In production that account is replaced by named
# administrators, and automation uses a service account with limited roles.
set -euo pipefail

ns=keycloak
pod=keycloak-0
config=/tmp/kcadm.config      # inside the pod: where kcadm keeps its login

kc() { kubectl -n "$ns" exec "$pod" -- /opt/keycloak/bin/kcadm.sh "$@" --config "$config"; }

case "${1:-}" in
  "" | -h | --help)
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
  login)
    user=$(kubectl -n "$ns" get secret keycloak-initial-admin -o jsonpath='{.data.username}' | base64 -d)
    pass=$(kubectl -n "$ns" get secret keycloak-initial-admin -o jsonpath='{.data.password}' | base64 -d)
    kc config credentials --server http://localhost:8080 --realm master --user "$user" --password "$pass"
    echo "Logged in to Keycloak as $user."
    ;;
  user-id)
    id=$(kc get users -r platform -q "username=${2:?give a username}" -q exact=true --fields id --format csv --noquotes)
    if [[ -z "$id" ]]; then
      echo "No user '$2' in realm platform." >&2
      exit 1
    fi
    echo "$id"
    ;;
  *)
    kc "$@"
    ;;
esac
