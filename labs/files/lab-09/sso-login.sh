#!/usr/bin/env bash
# Lab 9: log in to Grafana through Keycloak the way a browser does, and say
# who Grafana thinks you are. The same steps as infra/platform/verify.sh:
#
#   1. ask Grafana for its "Sign in with Keycloak" address
#   2. Grafana redirects to Keycloak's login form
#   3. post the user name and password to Keycloak
#   4. Keycloak redirects back to Grafana with a one-time code
#   5. Grafana swaps the code for a token and reads the user's roles from it
#
#   labs/files/lab-09/sso-login.sh <username> <password>
#
# Prints the Grafana login name and role, or "LOGIN REFUSED" (exit code 1).
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <username> <password>" >&2
  exit 2
fi

repo=$(cd "$(dirname "$0")/../../.." && pwd)
# shellcheck source=../../../infra/versions.env
source "$repo/infra/versions.env"
ip=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' | sed -E 's#https?://([^:/]+).*#\1#')
grafana="http://grafana.${ip}.${INGRESS_DOMAIN_SUFFIX}"

jar=$(mktemp)
trap 'rm -f "$jar"' EXIT

page=$(curl -sS -L --max-time 20 -c "$jar" -b "$jar" "$grafana/login/generic_oauth")
# Keycloak's login form:  <form id="kc-form-login" ... action="...">
action=$(grep -o 'action="[^"]*"' <<<"$page" | sed -n '1{s/^action="//;s/"$//;s/&amp;/\&/g;p;}')
if [[ -z "$action" ]]; then
  echo "No Keycloak login form came back from $grafana/login/generic_oauth." >&2
  echo "Is Grafana single sign-on set up?  infra/platform/verify.sh" >&2
  exit 1
fi

reply=$(mktemp)
trap 'rm -f "$jar" "$reply"' EXIT
landed=$(curl -sS -L --max-time 30 -c "$jar" -b "$jar" -o "$reply" -w '%{url_effective}' \
  --data-urlencode "username=$1" --data-urlencode "password=$2" --data-urlencode "credentialId=" "$action")

if ! me=$(curl -fsS --max-time 10 -b "$jar" "$grafana/api/user" 2>/dev/null); then
  echo "LOGIN REFUSED for $1"
  # Say who refused, and why, as far as the pages tell us.
  title=$(tr '\n' ' ' <"$reply" | sed -n 's/.*<title>\([^<]*\)<\/title>.*/\1/p' | sed 's/^ *//;s/ *$//')
  if [[ "$landed" == *"/realms/"* ]]; then
    reason=$(tr '\n' ' ' <"$reply" | grep -o -E '(kc-feedback-text|input-error|alert-error)[^>]*>[^<]+' | sed 's/.*>//;s/^ *//;s/ *$//' | sed -n 1p || true)
    echo "  Keycloak did not finish the login. It showed the page: \"${title:-?}\""
    [[ -n "$reason" ]] && echo "  Keycloak's message: $reason"
  else
    echo "  Keycloak accepted the user, but Grafana did not (ended at ${landed%%\?*})."
    echo "  Grafana's log says:"
    lines=$(kubectl -n monitoring logs deployment/kube-prometheus-stack-grafana -c grafana --since=1m 2>/dev/null |
      grep -i -E 'oauth|login|error' | tail -n 3 || true)
    sed 's/^/    /' <<<"$lines"
    if grep -q 'unable to create user' <<<"$lines"; then
      echo "  Grafana already has a user with this name or e-mail address, under a different Keycloak ID"
      echo "  (a user that was deleted and created again). Remove Grafana's old record:"
      echo "    labs/files/lab-09/grafana-user.sh delete $1"
    fi
  fi
  exit 1
fi
role=$(curl -fsS --max-time 10 -b "$jar" "$grafana/api/user/orgs" | jq -r '.[0].role // "unknown"')
echo "Grafana login: $(jq -r .login <<<"$me")   role: $role"
