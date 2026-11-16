#!/usr/bin/env bash
# Lab 7: run one LogQL query against Loki and print the matching log lines
# (the last hour, newest at the bottom). It does what Grafana's Explore page
# does: an HTTP call to Loki's /loki/api/v1/query_range.
#
#   labs/files/lab-07/logql.sh '{namespace="lab7"} |= "failed"'
#   LIMIT=50 labs/files/lab-07/logql.sh '{namespace="lab7"}'
#
# Loki has no ingress of its own, so the call goes through the Kubernetes API
# server, which forwards it to the Service "loki" in the namespace "logging".
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 '<LogQL query>'    (put the query in single quotes)" >&2
  exit 2
fi

limit=${LIMIT:-10}
encoded=$(jq -rn --arg q "$1" '$q | @uri')
path="/api/v1/namespaces/logging/services/loki:3100/proxy/loki/api/v1/query_range?limit=${limit}&query=${encoded}"

# A line written a few seconds ago may still be on its way: look again for
# up to 30 seconds before saying that nothing matched.
for _ in 1 2 3 4 5 6; do
  if ! reply=$(kubectl get --raw "$path" 2>&1); then
    echo "Loki did not answer: $reply" >&2
    echo "Is it running?  kubectl -n logging get pods" >&2
    exit 1
  fi
  count=$(jq -r '.data.result | length' 2>/dev/null <<<"$reply" || echo 0)
  [[ "$count" -gt 0 ]] && break
  sleep 5
done

if [[ "$count" -eq 0 ]]; then
  echo "No log lines matched in the last hour." >&2
  exit 1
fi

jq -r '
  # Fluent Bit sends each line as JSON; the text the container wrote is in "log".
  def text: . as $line | try (fromjson | .log // $line) catch $line;
  def clock: (tonumber / 1000000000 | floor | strftime("%H:%M:%S"));
  .data
  | if .resultType == "streams" then
      [ .result[] | .stream as $s | .values[] | {t: .[0], pod: ($s.pod // "-"), line: (.[1] | text)} ]
      | sort_by(.t) | .[]
      | "\(.t | clock) UTC  \(.pod)  \(.line | rtrimstr("\n"))"
    else
      .result[] | "\(.values[-1][1])\t\(.metric)"
    end
' <<<"$reply"
