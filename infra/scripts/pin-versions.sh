#!/usr/bin/env bash
# Pin every version to what is running on the current cluster, so the next
# build (another attendee, the next class) is identical to a build you have
# tested.
#
#   ./infra/scripts/pin-versions.sh --dry-run   # show what would change
#   ./infra/scripts/pin-versions.sh             # write the pins
#
# Reads from the cluster in your current kubeconfig context:
#   - Helm chart versions of the platform releases      -> infra/versions.env
#   - RKE2 version of the nodes                         -> infra/versions.env + Ansible group_vars
#   - Keycloak Operator version                         -> infra/versions.env
#   - PostgreSQL image digest                           -> infra/versions.env
#   - Redis + redis_exporter image digests              -> infra/platform/redis/values-pinned.yaml
# Cilium, Traefik and CoreDNS come bundled with RKE2, so pinning RKE2 pins them.
# Kafka's version is the Strimzi operator's default, so pinning the Strimzi chart pins it.
#
# Files are backed up as *.bak before they are changed. Review with `git diff`.
set -euo pipefail

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSIONS_ENV="$INFRA_DIR/versions.env"
GROUP_VARS="$INFRA_DIR/ansible/inventory/group_vars/all.yml"
REDIS_PINNED="$INFRA_DIR/platform/redis/values-pinned.yaml"

DRY_RUN=false
case "${1:-}" in
  --dry-run|-n) DRY_RUN=true ;;
  --help|-h)    sed -n '2,21p' "$0"; exit 0 ;;
  "")           ;;
  *)            echo "unknown option: $1 (use --dry-run or --help)" >&2; exit 2 ;;
esac

warn() { printf '\033[1;33m  ! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m  ✘ %s\033[0m\n' "$*" >&2; exit 1; }
for b in kubectl helm jq; do command -v "$b" >/dev/null || die "missing tool: $b"; done
kubectl get --raw /readyz >/dev/null 2>&1 || die "cannot reach the cluster (check ~/.kube/config)"

CLUSTER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CHANGES=()      # "file|key|old|new" for the summary

# Current value of KEY="..." in versions.env
env_get() { sed -nE "s|^$1=\"([^\"]*)\".*|\1|p" "$VERSIONS_ENV"; }

# Record a change of KEY in versions.env (applied at the end)
pin_env() {  # KEY NEW-VALUE
  local key=$1 new=$2 old
  [[ -n "$new" ]] || { warn "no value found for $key; left unchanged"; return; }
  old=$(env_get "$key")
  [[ "$old" == "$new" ]] || CHANGES+=("versions.env|$key|$old|$new")
}

# Digest of the image a running container actually uses: "<image-as-specified>@sha256:..."
running_image() {  # ns pod container
  local spec id
  spec=$(kubectl -n "$1" get pod "$2" -o jsonpath="{.spec.containers[?(@.name==\"$3\")].image}" 2>/dev/null) || return 0
  id=$(kubectl -n "$1" get pod "$2" -o jsonpath="{.status.containerStatuses[?(@.name==\"$3\")].imageID}" 2>/dev/null) || return 0
  [[ -n "$spec" && "$id" == *@sha256:* ]] || return 0
  echo "${spec%@*}@${id##*@}"     # strip any digest already in the spec, add the running one
}

echo "Reading versions from cluster $CLUSTER"

# --- Helm charts --------------------------------------------------------------
declare -A CHART_VAR=(
  [local-path-provisioner]=CHART_LOCAL_PATH
  [kube-prometheus-stack]=CHART_KUBE_PROM_STACK
  [loki]=CHART_LOKI
  [fluent-bit]=CHART_FLUENT_BIT
  [vault]=CHART_VAULT
  [strimzi]=CHART_STRIMZI
)
RELEASES=$(helm list -A -o json)
for rel in "${!CHART_VAR[@]}"; do
  ns=$(jq -r --arg r "$rel" '.[] | select(.name==$r) | .namespace' <<<"$RELEASES" | head -1)
  if [[ -z "$ns" ]]; then
    warn "Helm release '$rel' not found; ${CHART_VAR[$rel]} left unchanged"
    continue
  fi
  status=$(jq -r --arg r "$rel" '.[] | select(.name==$r) | .status' <<<"$RELEASES" | head -1)
  [[ "$status" == "deployed" ]] || warn "release '$rel' is '$status', not 'deployed'; pinning it anyway"
  # "helm list" only shows "<chart>-<version>" (chart names contain dashes), so ask for the version itself
  ver=$(helm get metadata "$rel" -n "$ns" -o json | jq -r '.version')
  pin_env "${CHART_VAR[$rel]}" "$ver"
done

# --- RKE2 ---------------------------------------------------------------------
mapfile -t RKE2_VERSIONS < <(kubectl get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.kubeletVersion}{"\n"}{end}' | sort -u)
if (( ${#RKE2_VERSIONS[@]} > 1 )); then
  warn "nodes run different versions (${RKE2_VERSIONS[*]}); RKE2 not pinned. Finish the upgrade first."
  RKE2_NEW=""
else
  RKE2_NEW=${RKE2_VERSIONS[0]}
  pin_env RKE2_VERSION "$RKE2_NEW"
  old=$(sed -nE 's|^rke2_version: "([^"]*)".*|\1|p' "$GROUP_VARS")
  [[ "$old" == "$RKE2_NEW" ]] || CHANGES+=("group_vars/all.yml|rke2_version|$old|$RKE2_NEW")
fi

# --- Keycloak Operator ---------------------------------------------------------
kc_img=$(kubectl -n keycloak get deploy keycloak-operator -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
if [[ -n "$kc_img" ]]; then
  kc_ver=${kc_img##*:}; kc_ver=${kc_ver%@*}
  pin_env KEYCLOAK_VERSION "$kc_ver"
  srv_img=$(kubectl -n keycloak get pod keycloak-0 -o jsonpath='{.spec.containers[0].image}' 2>/dev/null || true)
  [[ -z "$srv_img" || "$srv_img" == *":$kc_ver"* ]] || warn "Keycloak server runs $srv_img, operator is $kc_ver"
else
  warn "Keycloak Operator not found; KEYCLOAK_VERSION left unchanged"
fi

# --- Images with moving tags ------------------------------------------------------
pin_env POSTGRES_IMAGE "$(running_image keycloak postgres-0 postgres)"

REDIS_IMG=$(running_image redis redis-0 redis)
EXPORTER_IMG=$(running_image redis redis-0 exporter)
REDIS_TAG=""
if [[ -n "$REDIS_IMG" ]]; then
  REDIS_TAG=${REDIS_IMG##*/}; REDIS_TAG=${REDIS_TAG#*:}     # "8-alpine@sha256:..."
  REDIS_REPO=${REDIS_IMG%%:*}
  old=$( [[ -f "$REDIS_PINNED" ]] && sed -nE 's|^  tag: "([^"]*)"|\1|p' "$REDIS_PINNED" || true)
  [[ "$old" == "$REDIS_TAG" ]] || CHANGES+=("redis/values-pinned.yaml|image.tag|$old|$REDIS_TAG")
  old=$( [[ -f "$REDIS_PINNED" ]] && sed -nE 's|^  image: "([^"]*)"|\1|p' "$REDIS_PINNED" || true)
  [[ -z "$EXPORTER_IMG" || "$old" == "$EXPORTER_IMG" ]] || CHANGES+=("redis/values-pinned.yaml|metrics.image|$old|$EXPORTER_IMG")
else
  warn "redis-0 not running; Redis images not pinned"
fi

# --- Report ------------------------------------------------------------------------
echo
if (( ${#CHANGES[@]} == 0 )); then
  echo "Everything is already pinned to what the cluster runs. Nothing to do."
  exit 0
fi
printf '%-26s %-22s %-28s %s\n' FILE SETTING OLD NEW
for c in "${CHANGES[@]}"; do
  IFS='|' read -r f k o n <<<"$c"
  printf '%-26s %-22s %-28s %s\n' "$f" "$k" "${o:-(unpinned)}" "$n"
done

if $DRY_RUN; then
  echo; echo "Dry run: no files changed. Re-run without --dry-run to write these pins."
  exit 0
fi

# --- Write -----------------------------------------------------------------------
cp "$VERSIONS_ENV" "$VERSIONS_ENV.bak"
cp "$GROUP_VARS" "$GROUP_VARS.bak"
[[ -f "$REDIS_PINNED" ]] && cp "$REDIS_PINNED" "$REDIS_PINNED.bak"

for c in "${CHANGES[@]}"; do
  IFS='|' read -r f k o n <<<"$c"
  case "$f" in
    versions.env)       sed -i -E "s|^($k=)\"[^\"]*\"|\1\"$n\"|" "$VERSIONS_ENV" ;;
    group_vars/all.yml) sed -i -E "s|^($k: )\"[^\"]*\"|\1\"$n\"|" "$GROUP_VARS" ;;
  esac
done

STAMP="# Last pinned from cluster $CLUSTER on $(date -u +%Y-%m-%dT%H:%MZ) by infra/scripts/pin-versions.sh"
if grep -q '^# Last pinned from cluster' "$VERSIONS_ENV"; then
  sed -i "s|^# Last pinned from cluster.*|$STAMP|" "$VERSIONS_ENV"
else
  sed -i "5a $STAMP" "$VERSIONS_ENV"
fi

if [[ -n "$REDIS_TAG" ]]; then
  cat > "$REDIS_PINNED" <<EOF
# Generated by infra/scripts/pin-versions.sh. Do not edit by hand; re-run the script.
# Pins the Redis and redis_exporter images to the exact digests tested on
# $CLUSTER. deploy.sh adds this file after values-vault.yaml when it exists.
image:
  repository: "$REDIS_REPO"
  tag: "$REDIS_TAG"
EOF
  [[ -n "$EXPORTER_IMG" ]] && cat >> "$REDIS_PINNED" <<EOF
metrics:
  image: "$EXPORTER_IMG"
EOF
fi

cat <<EOF

Pins written (backups: *.bak). Next:
  git diff infra/
  Rebuild once from scratch with these pins before the class (reset.yml, site.yml, deploy.sh all).
Note: pinning an image to a digest changes the pod spec, so the next ./deploy.sh
restarts PostgreSQL and Redis once. Their data is on persistent volumes and is kept.
EOF
