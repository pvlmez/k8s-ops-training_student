#!/usr/bin/env bash
# Lab 7: run one PromQL query against the cluster's Prometheus and print the
# result as text. It does what the Prometheus web page does: an HTTP call to
# /api/v1/query.
#
#   labs/files/lab-07/promql.sh 'up == 0'
#
# Each result line is:  value  {labels}
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 '<PromQL query>'    (put the query in single quotes)" >&2
  exit 2
fi

repo=$(cd "$(dirname "$0")/../../.." && pwd)
# shellcheck source=../../../infra/versions.env
source "$repo/infra/versions.env"
ip=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' | sed -E 's#https?://([^:/]+).*#\1#')
url="http://prometheus.${ip}.${INGRESS_DOMAIN_SUFFIX}"

if ! reply=$(curl -sS --max-time 20 -G "$url/api/v1/query" --data-urlencode "query=$1"); then
  echo "Cannot reach Prometheus at $url. Is the observability layer running? (infra/platform/verify.sh)" >&2
  exit 1
fi

if ! jq -e '.status == "success"' >/dev/null 2>&1 <<<"$reply"; then
  echo "Prometheus rejected the query: $(jq -r '.error // "no JSON in the reply"' 2>/dev/null <<<"$reply")" >&2
  exit 1
fi

jq -r '
  def labels: to_entries | map("\(.key)=\"\(.value)\"") | join(", ");
  .data
  | if .resultType == "vector" then
      (.result[] | "\(.value[1])\t{\(.metric | labels)}"),
      "(\(.result | length) series)"
    elif .resultType == "matrix" then
      (.result[] | "\(.values | length) samples, last \(.values[-1][1])\t{\(.metric | labels)}"),
      "(\(.result | length) series)"
    else
      "\(.result[1])"
    end
' <<<"$reply"
