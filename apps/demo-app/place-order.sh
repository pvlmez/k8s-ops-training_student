#!/usr/bin/env bash
# Demo app: log in through Keycloak the way a browser does, place orders, and
# print the shop's counters. Used in lab 15 and by anyone who wants load.
#
#   apps/demo-app/place-order.sh <username> <password> [how-many] [item]
#
#   apps/demo-app/place-order.sh ops-user ChangeMe-User1            # one coffee
#   apps/demo-app/place-order.sh ops-user ChangeMe-User1 50 tea     # fifty teas
#
# The steps: ask the app to log in -> the app redirects to Keycloak's login
# form -> post user name and password there -> Keycloak redirects back to the
# app with a one-time code -> the app swaps it for a token and starts a session.
set -euo pipefail

if [[ $# -lt 2 ]]; then
  sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
fi
user=$1 password=$2 count=${3:-1} item=${4:-coffee}

if [[ -z "${APP_URL:-}" ]]; then
  repo=$(cd "$(dirname "$0")/../.." && pwd)
  # shellcheck source=../../infra/versions.env
  source "$repo/infra/versions.env"
  ip=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' | sed -E 's#https?://([^:/]+).*#\1#')
  APP_URL="http://demo.${ip}.${INGRESS_DOMAIN_SUFFIX}"
fi

jar=$(mktemp)
trap 'rm -f "$jar"' EXIT

page=$(curl -sS -L --max-time 20 -c "$jar" -b "$jar" "$APP_URL/login")
# Keycloak's login form:  <form id="kc-form-login" ... action="...">
action=$(grep -o 'action="[^"]*"' <<<"$page" | sed -n '1{s/^action="//;s/"$//;s/&amp;/\&/g;p;}')
if [[ -z "$action" ]]; then
  echo "No Keycloak login form came back from $APP_URL/login. Is the app running?  kubectl -n demo-app get pods" >&2
  exit 1
fi
curl -sS -L --max-time 30 -c "$jar" -b "$jar" -o /dev/null \
  --data-urlencode "username=$user" --data-urlencode "password=$password" --data-urlencode "credentialId=" "$action"

if ! grep -q demo_session "$jar"; then
  echo "LOGIN REFUSED for $user (wrong password, disabled user, or the app could not swap the code for a token)"
  exit 1
fi
echo "Logged in to $APP_URL as $user"

for ((i = 1; i <= count; i++)); do
  code=$(curl -sS --max-time 20 -b "$jar" -o /dev/null -w '%{http_code}' --data-urlencode "item=$item" "$APP_URL/order")
  if [[ "$code" != 303 ]]; then
    echo "Order $i was not accepted (HTTP $code)" >&2
    exit 1
  fi
done
echo "Placed $count order(s) for: $item"
curl -fsS --max-time 10 "$APP_URL/api/status" | jq -r '"placed: \(.placed)   processed: \(.processed)   waiting: \(.waiting)"'
