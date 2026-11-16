#!/usr/bin/env bash
# Show the facts about your lab that the lab guides refer to: your nodes
# (name, address, Kubernetes node name) and the web UI addresses.
#
#   infra/scripts/lab-info.sh                # print them
#   infra/scripts/lab-info.sh --ssh-config   # also add node1, node2 … to ~/.ssh/config,
#                                            # so "ssh node1" works
#
# Reads the Ansible inventory (infra/ansible/inventory/hosts.ini) and, if the
# cluster answers, the Kubernetes API. Changes nothing in the cluster.
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
ANSIBLE_DIR="$REPO_DIR/infra/ansible"
BEGIN='# >>> k8s-training nodes >>>'
END='# <<< k8s-training nodes <<<'

die() { printf '\033[1;31m  ✘ %s\033[0m\n' "$*" >&2; exit 1; }
head1() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

for tool in ansible-inventory jq; do
  command -v "$tool" >/dev/null 2>&1 || die "missing tool: $tool (run infra/scripts/install-tools.sh)"
done
[[ -f "$ANSIBLE_DIR/inventory/hosts.ini" ]] || die "no inventory yet: copy infra/ansible/inventory/hosts.example.ini to hosts.ini and put your node addresses in"

# One line per host: name, address, ssh user, role, address inside the cluster
hosts=$(cd "$ANSIBLE_DIR" && ansible-inventory --list | jq -r '
  . as $inv
  | ($inv.rke2_servers.hosts // []) as $servers
  | ($inv.rke2_agents.hosts // []) as $agents
  | $inv._meta.hostvars | to_entries | sort_by(.key)[]
  | [ .key,
      .value.ansible_host,
      (.value.ansible_user // "ubuntu"),
      (if (.key | IN($servers[])) then "server" elif (.key | IN($agents[])) then "agent" else "spare" end),
      (.value.node_ip // .value.ansible_host)
    ] | @tsv')
[[ -n "$hosts" ]] || die "the inventory has no hosts"

# Kubernetes node name for an address, if the cluster answers
k8s_nodes=""
if command -v kubectl >/dev/null 2>&1; then
  k8s_nodes=$(kubectl get nodes --request-timeout=5s \
    -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\t"}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
fi

head1 "Your nodes"
printf '  %-7s %-16s %-8s %-28s %s\n' NAME ADDRESS ROLE "KUBERNETES NODE NAME" LOGIN
while IFS=$'\t' read -r name addr user role node_ip; do
  kname=$(awk -F'\t' -v a="$node_ip" '$1 == a { print $2 }' <<<"$k8s_nodes")
  printf '  %-7s %-16s %-8s %-28s %s\n' "$name" "$addr" "$role" "${kname:-(not in the cluster)}" "ssh $user@$addr"
done <<<"$hosts"

if [[ "${1:-}" == "--ssh-config" ]]; then
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  cfg="$HOME/.ssh/config"; touch "$cfg"; tmp=$(mktemp)
  # Drop our previous block, keep everything else
  awk -v b="$BEGIN" -v e="$END" '$0 == b { skip = 1 } !skip { print } $0 == e { skip = 0 }' "$cfg" > "$tmp"
  {
    echo "$BEGIN"
    while IFS=$'\t' read -r name addr user role node_ip; do
      printf 'Host %s\n  HostName %s\n  User %s\n  StrictHostKeyChecking accept-new\n' "$name" "$addr" "$user"
    done <<<"$hosts"
    echo "$END"
  } >> "$tmp"
  cat "$tmp" > "$cfg" && rm -f "$tmp" && chmod 600 "$cfg"
  printf '\n  Added the nodes to %s: you can now type "ssh node1".\n' "$cfg"
elif ! grep -qF "$BEGIN" "$HOME/.ssh/config" 2>/dev/null; then
  printf '\n  Tip: run this script with --ssh-config once, then "ssh node1" works.\n'
fi

head1 "Your web UIs"
uis=""
if command -v kubectl >/dev/null 2>&1; then
  uis=$(kubectl get ingress -A --request-timeout=5s \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.spec.rules[0].host}{"\n"}{end}' 2>/dev/null || true)
fi
if [[ -n "$uis" ]]; then
  while IFS=$'\t' read -r ns host; do
    printf '  %-20s http://%s\n' "$ns" "$host"
  done <<<"$uis"
else
  echo "  (none yet, or the cluster does not answer)"
fi
