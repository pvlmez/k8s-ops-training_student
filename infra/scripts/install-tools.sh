#!/usr/bin/env bash
# Workstation setup (lab 1). Installs the CLI tools used in the course.
# Kubernetes CLIs come from arkade; Ansible comes from pipx (arkade does not ship it).
# Safe to re-run: arkade overwrites with the latest version.
set -euo pipefail

ARKADE_TOOLS=(
  kubectl     # Kubernetes CLI
  helm        # package manager
  k9s         # terminal UI
  cilium      # Cilium CLI (status, connectivity test)
  hubble      # Hubble CLI (network flows)
  vault       # HashiCorp Vault CLI
  jq          # JSON processor
  yq          # YAML processor
  stern       # multi-pod log tailing
  kubectx     # switch contexts
  kubens      # switch namespaces
  kustomize   # manifest overlays
)

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

log "Installing OS packages (git, curl, pipx, bash-completion)"
sudo apt-get update -qq
sudo apt-get install -y -qq git curl pipx bash-completion openssh-client python3-venv gettext-base

if ! command -v arkade >/dev/null 2>&1; then
  log "Installing arkade"
  curl -sLS https://get.arkade.dev | sudo sh
fi

log "Installing CLI tools with arkade: ${ARKADE_TOOLS[*]}"
for tool in "${ARKADE_TOOLS[@]}"; do
  arkade get --quiet "$tool"
done

log "Installing Ansible with pipx"
pipx install --include-deps ansible >/dev/null 2>&1 || pipx upgrade --include-deps ansible
pipx ensurepath >/dev/null

log "Installing Ansible collections"
"$HOME/.local/bin/ansible-galaxy" collection install -r "$(dirname "$0")/../ansible/requirements.yml" >/dev/null

log "Configuring shell (PATH, completion, aliases)"
# K8S_COURSE_HOME is where this copy of the course material lives; the lab guides
# use it instead of a fixed path. Re-run this script after moving the directory.
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASHRC_BLOCK='# >>> k8s-training >>>
export K8S_COURSE_HOME='"$(printf '%q' "$REPO_DIR")"'
export PATH="$HOME/.arkade/bin:$HOME/.local/bin:$PATH"
source <(kubectl completion bash)
source <(helm completion bash)
alias k=kubectl
complete -o default -F __start_kubectl k
export KUBE_EDITOR=vim
# <<< k8s-training <<<'
# Replace an existing block instead of keeping it, so a re-run picks up a new location.
touch "$HOME/.bashrc"
bashrc_tmp=$(mktemp)
awk '/^# >>> k8s-training >>>$/ {skip=1}
     !skip {print}
     /^# <<< k8s-training <<<$/ {skip=0}' "$HOME/.bashrc" > "$bashrc_tmp"
if [ -s "$bashrc_tmp" ] && [ -n "$(tail -n 1 "$bashrc_tmp")" ]; then
  echo >> "$bashrc_tmp"
fi
printf '%s\n' "$BASHRC_BLOCK" >> "$bashrc_tmp"
cat "$bashrc_tmp" > "$HOME/.bashrc"   # keeps the file's owner, mode and any symlink
rm -f "$bashrc_tmp"

if [ ! -f "$HOME/.ssh/id_ed25519" ]; then
  log "Creating an SSH key for Ansible (copy it to the nodes with ssh-copy-id)"
  ssh-keygen -t ed25519 -N '' -f "$HOME/.ssh/id_ed25519" -q
fi

export PATH="$HOME/.arkade/bin:$HOME/.local/bin:$PATH"
log "Installed versions"
kubectl version --client 2>/dev/null | head -1
helm version --short
cilium version --client 2>/dev/null | head -1 || true
hubble version 2>/dev/null || true
vault version
ansible --version | head -1

echo
echo "Done. Open a new terminal (or: source ~/.bashrc) to pick up PATH, aliases and"
echo "K8S_COURSE_HOME=$REPO_DIR"
