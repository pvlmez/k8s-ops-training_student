#!/usr/bin/env bash
# Lab 7: print the state of one alert rule, as Prometheus sees it.
#
#   labs/files/lab-07/alert-state.sh Lab7ReplicasMissing
#   labs/files/lab-07/alert-state.sh Lab7ReplicasMissing --wait firing 300
#
# States:
#   not loaded   Prometheus does not know the rule (yet)
#   inactive     the rule is loaded and its condition is false
#   pending      the condition is true, but not yet for as long as "for:" asks
#   firing       the alert has been sent to Alertmanager
#
# With --wait it prints the state every 10 seconds until it is the one you
# asked for, and fails if that takes longer than the number of seconds given.
set -euo pipefail

if [[ $# -ne 1 && $# -ne 4 ]] || [[ $# -eq 4 && "$2" != "--wait" ]]; then
  echo "usage: $0 <alert-name> [--wait <not loaded|inactive|pending|firing> <seconds>]" >&2
  exit 2
fi
name=$1 want=${3:-} limit=${4:-0}

repo=$(cd "$(dirname "$0")/../../.." && pwd)
# shellcheck source=../../../infra/versions.env
source "$repo/infra/versions.env"
ip=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' | sed -E 's#https?://([^:/]+).*#\1#')
url="http://prometheus.${ip}.${INGRESS_DOMAIN_SUFFIX}"

state() {
  local reply
  if ! reply=$(curl -sS --max-time 20 "$url/api/v1/rules?type=alert"); then
    echo "Cannot reach Prometheus at $url" >&2
    return 1
  fi
  jq -r --arg n "$name" '[.data.groups[].rules[] | select(.name == $n) | .state] | first // "not loaded"' <<<"$reply"
}

now=$(state)
if [[ -z "$want" ]]; then
  echo "$name: $now"
  exit 0
fi

while [[ "$now" != "$want" ]]; do
  if (( SECONDS >= limit )); then
    echo "$name: $now. Still not '$want' after ${limit}s." >&2
    exit 1
  fi
  printf '%4ss  %s: %s (waiting for: %s)\n' "$SECONDS" "$name" "$now" "$want"
  sleep 10
  now=$(state)
done
echo "$name: $now"
