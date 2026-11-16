# Shared helpers for deploy.sh / verify.sh. Sourced, not executed.
# shellcheck shell=bash

PLATFORM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$PLATFORM_DIR")"
SECRETS_DIR="$PLATFORM_DIR/.secrets"      # git-ignored; lab-only credentials
# shellcheck source=../versions.env
source "$INFRA_DIR/versions.env"
export KEYCLOAK_VERSION POSTGRES_IMAGE

mkdir -p "$SECRETS_DIR" && chmod 700 "$SECRETS_DIR"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  ✔ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m  ! %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m  ✘ %s\033[0m\n' "$*" >&2; exit 1; }

require() {
  for b in "$@"; do command -v "$b" >/dev/null 2>&1 || die "missing tool: $b (run infra/scripts/install-tools.sh)"; done
}

# IP used in *.sslip.io ingress hostnames: the API server address from kubeconfig
# unless INGRESS_IP is already set.
detect_ingress_ip() {
  if [[ -z "${INGRESS_IP:-}" ]]; then
    INGRESS_IP=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' | sed -E 's#https?://([^:/]+).*#\1#')
  fi
  export INGRESS_IP
  export DOMAIN="${INGRESS_IP}.${INGRESS_DOMAIN_SUFFIX}"
}

# Render a template. Only the variables listed are substituted; any other
# ${VAR} (e.g. Keycloak realm placeholders) is left untouched.
# shellcheck disable=SC2016
render() { envsubst '${INGRESS_IP} ${DOMAIN} ${KEYCLOAK_VERSION} ${POSTGRES_IMAGE} ${KAFKA_IMAGE} ${CODE_SUM}' < "$1"; }

# Return a stored random secret, creating it on first use.
# Note: never pipe "tr </dev/urandom" into "head": head exits early, tr gets
# SIGPIPE (exit 141) and, with pipefail, that counts as a failure.
lab_secret() {
  local file="$SECRETS_DIR/$1" raw
  if [[ ! -s "$file" ]]; then
    raw=$(head -c 1024 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')
    printf '%s' "${raw:0:24}" > "$file"
    chmod 600 "$file"
  fi
  cat "$file"
}

ensure_ns() { kubectl create namespace "$1" --dry-run=client -o yaml | kubectl apply -f - >/dev/null; }

# helm upgrade --install with optional pinned version
helm_install() {
  local release=$1 chart=$2 ns=$3 version=$4; shift 4
  local vflag=()
  [[ -n "$version" ]] && vflag=(--version "$version")
  helm upgrade --install "$release" "$chart" -n "$ns" --create-namespace "${vflag[@]}" "$@"
}

# Helm 4 applies new releases with server-side apply (SSA): Helm then "owns"
# every field it renders. Some charts render a field that a controller in the
# cluster rewrites at runtime (e.g. the Vault injector fills in the webhook's
# caBundle), so every later `helm upgrade` fails with a field-manager conflict.
# For those charts use Helm 3-style client-side apply, which leaves fields the
# chart hasn't changed alone. Prints nothing on Helm 3 (where CSA is the only mode).
helm_csa_flag() {
  if helm version --template '{{.Version}}' 2>/dev/null | grep -q '^v4'; then
    echo "--server-side=false"
  fi
}

helm_repos() {
  helm repo add prometheus-community "$REPO_PROMETHEUS"        >/dev/null 2>&1 || true
  helm repo add grafana-community    "$REPO_GRAFANA_COMMUNITY" >/dev/null 2>&1 || true
  helm repo add fluent               "$REPO_FLUENT"            >/dev/null 2>&1 || true
  helm repo add hashicorp            "$REPO_HASHICORP"         >/dev/null 2>&1 || true
  helm repo add strimzi              "$REPO_STRIMZI"           >/dev/null 2>&1 || true
  helm repo add containeroo          "$REPO_LOCAL_PATH"        >/dev/null 2>&1 || true
  helm repo update >/dev/null
}

# StatefulSet "forced rollback" problem: if a pod crashed with an old (bad)
# spec, fixing the spec does NOT replace it; the StatefulSet waits forever
# for the broken pod to become Ready. Delete pods that are not Ready and
# whose revision differs from the StatefulSet's current updateRevision.
replace_stale_sts_pods() {  # ns selector
  local ns=$1 sel=$2 pod sts rev want ready
  for pod in $(kubectl -n "$ns" get pods -l "$sel" -o name 2>/dev/null); do
    sts=$(kubectl -n "$ns" get "$pod" -o jsonpath='{.metadata.ownerReferences[?(@.kind=="StatefulSet")].name}')
    [[ -n "$sts" ]] || continue
    ready=$(kubectl -n "$ns" get "$pod" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
    rev=$(kubectl -n "$ns" get "$pod" -o jsonpath='{.metadata.labels.controller-revision-hash}')
    want=$(kubectl -n "$ns" get sts "$sts" -o jsonpath='{.status.updateRevision}')
    if [[ "$ready" != "True" && -n "$want" && "$rev" != "$want" ]]; then
      warn "$pod is not Ready and runs an outdated spec ($rev, want $want): deleting it so the StatefulSet recreates it"
      kubectl -n "$ns" delete "$pod" --wait=false
    fi
  done
}

# Does the Vault Agent Injector inject right now? A server-side dry run of an
# annotated pod goes through the mutating webhook but creates nothing.
injector_works() {
  kubectl -n vault create --dry-run=server -f - -o jsonpath='{.spec.initContainers[*].name}' 2>/dev/null <<'EOF' | grep -qw vault-agent-init
apiVersion: v1
kind: Pod
metadata:
  name: injector-check
  annotations:
    vault.hashicorp.com/agent-inject: "true"
    vault.hashicorp.com/role: "redis"
    vault.hashicorp.com/agent-inject-secret-check: "secret/data/platform/redis"
spec:
  containers:
    - name: check
      image: docker.io/library/busybox:1.37
      command: ["true"]
EOF
}

# Pods that asked for the Vault agent but were created while the injector did
# not answer (a drain, an injector upgrade): the webhook's failurePolicy is
# Ignore, so they were admitted WITHOUT the agent and never get it. Once the
# injector works again, delete them so their controller recreates them.
uninjected_pods() {  # [kubectl get options, e.g. -A or -n ns -l sel] -> "namespace name" per line
  kubectl get pods "$@" -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{.metadata.annotations.vault\.hashicorp\.com/agent-inject}{"|"}{.metadata.annotations.vault\.hashicorp\.com/agent-inject-status}{"\n"}{end}' 2>/dev/null \
    | awk -F'|' '$3 == "true" && $4 != "injected" {print $1, $2}' || true
}
no_uninjected_pods() { [[ -z "$(uninjected_pods -A)" ]]; }

replace_uninjected_pods() {  # ns selector
  local pods ns pod
  pods=$(uninjected_pods -n "$1" -l "$2")
  [[ -n "$pods" ]] && injector_works || return 0
  while read -r ns pod; do
    warn "pod/$pod was created without the Vault agent (injector was not answering): deleting it so it is recreated"
    kubectl -n "$ns" delete pod "$pod" --wait=false || true
  done <<<"$pods"
}

# Is a Deployment or StatefulSet completely rolled out: every pod on the
# newest spec and Ready? (Checking "pod X is Ready" right after an upgrade
# passes on the OLD pod, before the controller has replaced it.)
rolled_out() {  # ns kind/name
  local f
  case "$2" in
    statefulset/*)
      IFS='|' read -r -a f <<<"$(kubectl -n "$1" get "$2" -o jsonpath='{.metadata.generation}|{.status.observedGeneration}|{.spec.replicas}|{.status.readyReplicas}|{.status.updatedReplicas}|{.status.currentRevision}|{.status.updateRevision}' 2>/dev/null)"
      [[ -n "${f[6]:-}" && "${f[0]}" == "${f[1]}" && "${f[3]}" == "${f[2]}" && "${f[4]}" == "${f[2]}" && "${f[5]}" == "${f[6]}" ]] ;;
    deployment/*)
      IFS='|' read -r -a f <<<"$(kubectl -n "$1" get "$2" -o jsonpath='{.metadata.generation}|{.status.observedGeneration}|{.spec.replicas}|{.status.replicas}|{.status.updatedReplicas}|{.status.availableReplicas}' 2>/dev/null)"
      [[ -n "${f[5]:-}" && "${f[0]}" == "${f[1]}" && "${f[3]}" == "${f[2]}" && "${f[4]}" == "${f[2]}" && "${f[5]}" == "${f[2]}" ]] ;;
    *) return 1 ;;
  esac
}

# One check of wait_for, taking up to 30s.
condition_met() {  # ns kind/name condition
  if [[ "$3" == "RolledOut" ]]; then
    for _ in 1 2 3 4 5 6; do
      rolled_out "$1" "$2" && return 0
      sleep 5
    done
    return 1
  fi
  kubectl -n "$1" wait "$2" --for=condition="$3" --timeout=30s >/dev/null 2>&1
}

# Wait for a condition on a resource, printing pod status every 30s so a
# slow start is visible. On timeout, print diagnostics and fail.
#   wait_for <ns> <kind/name> <condition> <timeout-seconds> <pod-label-selector>
# <condition> is a status condition (Ready, Available, ...) or RolledOut
# (Deployment/StatefulSet: every pod on the newest spec and Ready).
wait_for() {
  local ns=$1 res=$2 cond=$3 timeout=$4 sel=$5 waited=0 start
  printf '  waiting up to %ss for %s (%s)' "$timeout" "$res" "$cond"
  while start=$SECONDS; ! condition_met "$ns" "$res" "$cond"; do
    # "kubectl wait" returns at once if the object doesn't exist yet; keep a 30s rhythm
    (( SECONDS - start < 30 )) && sleep $((30 - (SECONDS - start)))
    waited=$((waited + 30))
    replace_stale_sts_pods "$ns" "$sel"
    replace_uninjected_pods "$ns" "$sel"
    printf '\n  [%3ss] ' "$waited"
    kubectl -n "$ns" get pods -l "$sel" --no-headers 2>/dev/null \
      | awk '{printf "%s %s %s restarts=%s; ", $1, $2, $3, $4}'
    if (( waited >= timeout )); then
      printf '\n'
      warn "timed out waiting for $res. Diagnostics:"
      kubectl -n "$ns" get pods -l "$sel" -o wide || true
      kubectl -n "$ns" get "$res" -o jsonpath='{range .status.conditions[*]}{.type}={.status}: {.message}{"\n"}{end}' || true
      echo "--- why pods are not scheduled (empty if all are)"
      kubectl -n "$ns" get pods -l "$sel" -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.status.conditions[?(@.type=="PodScheduled")].message}{"\n"}{end}' 2>/dev/null \
        | grep -v ': $' || true
      for p in $(kubectl -n "$ns" get pods -l "$sel" -o name 2>/dev/null); do
        echo "--- last log lines of $p"
        kubectl -n "$ns" logs "$p" --tail=25 --all-containers 2>/dev/null \
          || kubectl -n "$ns" logs "$p" --tail=25 --previous --all-containers 2>/dev/null || true
      done
      echo "--- recent events"
      # "kubectl events", not "get events --sort-by=.lastTimestamp": scheduler
      # events (FailedScheduling) have no lastTimestamp and would be cut off.
      kubectl -n "$ns" events 2>/dev/null | tail -15 || true
      return 1
    fi
  done
  printf '\n'; ok "$res is $cond"
}

wait_rollout() {  # ns kind/name [timeout]
  kubectl -n "$1" rollout status "$2" --timeout="${3:-300s}"
}
