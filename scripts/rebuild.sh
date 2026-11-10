#!/usr/bin/env bash
# Build, destroy or rebuild the homelab k3s cluster with no prompts.
#
#   scripts/rebuild.sh              build from nothing (VMs -> k3s -> ArgoCD -> GitOps apps)
#   scripts/rebuild.sh --destroy --yes     terraform destroy (all VMs and their data)
#   scripts/rebuild.sh --rebuild --yes     destroy, then build
#   scripts/rebuild.sh --check             prerequisite checks only (changes nothing)
#
# Safe to re-run after a failure: every step is idempotent.
# Env: GRAFANA_ADMIN_PASSWORD (default: random, saved to .rebuild/grafana-admin-password)
#      APPS_TIMEOUT_MIN (default 40), NODES_TIMEOUT_MIN (default 10)
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$ROOT/terraform"
ANS_DIR="$ROOT/ansible"
STATE_DIR="$ROOT/.rebuild"
export KUBECONFIG="$ANS_DIR/k3s.kubeconfig"
export ANSIBLE_HOST_KEY_CHECKING=False
APPS_TIMEOUT_MIN="${APPS_TIMEOUT_MIN:-40}"
NODES_TIMEOUT_MIN="${NODES_TIMEOUT_MIN:-10}"

MODE=build
YES=0
for arg in "$@"; do
  case "$arg" in
    --destroy) MODE=destroy ;;
    --rebuild) MODE=rebuild ;;
    --yes) YES=1 ;;
    --check) MODE=check ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

log()  { printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
trap 'printf "\nFAILED at line %s: %s\n(re-run the script; completed steps are skipped)\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

# retry <attempts> <delay-seconds> <command...>
retry() {
  local n=$1 d=$2 i; shift 2
  for ((i = 1; i <= n; i++)); do
    "$@" && return 0
    echo "  attempt $i/$n failed: $*" >&2
    sleep "$d"
  done
  return 1
}

# wait_until <timeout-seconds> <description> <command...>
wait_until() {
  local limit=$1 what=$2 start; shift 2
  start=$(date +%s)
  until "$@" >/dev/null 2>&1; do
    (( $(date +%s) - start > limit )) && die "timed out after ${limit}s waiting for: $what"
    sleep 10
  done
}

FAILS=""
fail() { FAILS="${FAILS}  - $*"$'\n'; }

# tfvar <name> <default>: value of `name = "value"` in terraform.tfvars, else the default.
tfvar() {
  local v
  v=$(sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$TF_DIR/terraform.tfvars" | head -1)
  printf '%s' "${v:-$2}"
}

# reach <url>: the URL answers (ranged GET; HEAD is rejected by some hosts).
reach() { curl -fsL --max-time 20 -o /dev/null -r 0-0 "$1" >/dev/null 2>&1; }

# pve_api <path>: authenticated Proxmox API GET, prints the JSON body.
pve_api() {
  curl -fs --max-time 20 ${PVE_INSECURE:+-k} -H "Authorization: PVEAPIToken=$PVE_TOKEN" "${PVE_ENDPOINT%/}/api2/json$1"
}

ping_ok() {
  if [[ "$(uname)" == Darwin ]]; then ping -c1 -t2 "$1" >/dev/null 2>&1; else ping -c1 -W2 "$1" >/dev/null 2>&1; fi
}

preflight_report() {
  if [[ -n "$FAILS" ]]; then
    printf '\nPreflight FAILED. Nothing was changed. Fix these and re-run:\n%s' "$FAILS" >&2
    exit 1
  fi
}

preflight() {
  log "Preflight (nothing is changed until every check passes)"
  local tool
  for tool in terraform ansible ansible-playbook helm kubectl ssh ssh-keygen openssl curl awk python3 ping; do
    command -v "$tool" >/dev/null || fail "missing tool: $tool"
  done
  preflight_report   # later checks need these tools

  [[ -f "$TF_DIR/terraform.tfvars" ]] || { fail "terraform/terraform.tfvars not found (copy terraform.tfvars.example)"; preflight_report; }

  ssh-add -l >/dev/null 2>&1 || fail "ssh-agent has no key loaded (ssh-add); the Proxmox provider needs root SSH to each node"
  local pubkey
  pubkey=$(tfvar ssh_public_key_file "~/.ssh/id_ed25519.pub"); pubkey="${pubkey/#\~/$HOME}"
  if [[ "$MODE" != destroy ]]; then
    [[ -f "$pubkey" ]] || fail "VM login public key not found: $pubkey (ssh_public_key_file)"
  fi

  # --- Proxmox API: endpoint, token, nodes online, SSH, storage content types
  PVE_ENDPOINT=$(tfvar pve_endpoint ""); PVE_TOKEN=$(tfvar pve_api_token "")
  PVE_INSECURE=1
  grep -Eq '^[[:space:]]*pve_insecure[[:space:]]*=[[:space:]]*false' "$TF_DIR/terraform.tfvars" && PVE_INSECURE=""
  [[ -n "$PVE_ENDPOINT" && -n "$PVE_TOKEN" ]] || fail "pve_endpoint / pve_api_token missing from terraform.tfvars"
  local node_names node_ips iso_ds snip_ds vm_ds ssh_user
  node_names=$(sed -n 's/.*name[[:space:]]*=[[:space:]]*"\(pve[^"]*\)".*vm_name.*/\1/p' "$TF_DIR/terraform.tfvars" | sort -u)
  node_ips=$(sed -n 's/.*vm_name.*ip[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$TF_DIR/terraform.tfvars")
  [[ -n "$node_names" && -n "$node_ips" ]] || fail "no nodes found in terraform.tfvars"
  iso_ds=$(tfvar iso_datastore local); snip_ds=$(tfvar snippets_datastore local); vm_ds=$(tfvar vm_datastore local-lvm)
  ssh_user=$(tfvar pve_ssh_user root)

  if [[ -n "$PVE_ENDPOINT" && -n "$PVE_TOKEN" ]]; then
    if ! pve_api /version >/dev/null; then
      fail "Proxmox API unreachable or token rejected: $PVE_ENDPOINT"
    else
      local cluster n addr st want
      cluster=$(pve_api /cluster/status || true)
      for n in $node_names; do
        addr=$(printf '%s' "$cluster" | N="$n" python3 -I -c "
import json,os,sys
for x in json.load(sys.stdin).get('data',[]):
    if x.get('type')=='node' and x.get('name')==os.environ['N'] and x.get('online',0)==1:
        print(x.get('ip',''))" 2>/dev/null || true)
        if [[ -z "$addr" ]]; then
          fail "Proxmox node $n is not online"
          continue
        fi
        ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new "$ssh_user@$addr" true >/dev/null 2>&1 \
          || fail "cannot SSH as $ssh_user@$addr ($n); the Proxmox provider needs it to import disks"
        if [[ "$MODE" != destroy ]]; then
          st=$(pve_api "/nodes/$n/storage?enabled=1" || true)
          for want in "$iso_ds:iso" "$snip_ds:snippets" "$vm_ds:images"; do
            printf '%s' "$st" | DS="${want%%:*}" CT="${want##*:}" python3 -I -c "
import json,os,sys
for x in json.load(sys.stdin).get('data',[]):
    if x.get('storage')==os.environ['DS'] and os.environ['CT'] in x.get('content','').split(','):
        sys.exit(0)
sys.exit(1)" 2>/dev/null || fail "$n: storage '${want%%:*}' is missing or lacks the '${want##*:}' content type"
          done
        fi
      done
    fi
  fi

  if [[ "$MODE" != destroy ]]; then
    # --- Network: IPs must be free on a fresh build (duplicate IPs break everything); gateway up
    local ip gw
    if [[ -z "$(cd "$TF_DIR" && terraform state list 2>/dev/null)" ]]; then
      for ip in $node_ips; do
        if ping_ok "$ip"; then fail "$ip already answers ping but Terraform has no state: another host or an orphan VM holds it"; fi
      done
    fi
    gw=$(tfvar gateway "")
    if [[ -n "$gw" ]] && ! ping_ok "$gw"; then fail "gateway $gw does not answer ping"; fi

    # --- Internet: everything the build downloads
    local url
    for url in \
      "https://get.k3s.io" \
      "https://github.com/k3s-io/k3s/releases/download/v1.37.2%2Bk3s1/sha256sum-amd64.txt" \
      "https://argoproj.github.io/argo-helm/index.yaml" \
      "https://github.com/sraeburn/homelab-k8s.git/info/refs?service=git-upload-pack" \
      "$(tfvar image_url "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img")"; do
      reach "$url" || fail "cannot reach $url"
    done
  fi

  preflight_report
  mkdir -p "$STATE_DIR"
}

do_destroy() {
  (( YES )) || die "destroy needs --yes (it deletes every VM and all volume data)"
  log "Terraform destroy"
  (cd "$TF_DIR" && terraform init -input=false >/dev/null && terraform destroy -auto-approve -input=false)
  rm -f "$ANS_DIR/inventory.ini" "$ANS_DIR/k3s.kubeconfig"
  log "Destroyed. Check Proxmox for leftover VMs on every node."
}

build_vms() {
  log "Terraform: create VMs"
  cd "$TF_DIR"
  terraform init -input=false >/dev/null
  # A failed apply is safe to repeat; never interrupt one (orphans VMs).
  retry 2 30 terraform apply -auto-approve -input=false
  terraform output -raw ansible_inventory > "$ANS_DIR/inventory.ini"
  cd "$ROOT"

  # Fresh VMs reuse old IPs: drop stale host keys so ssh/ansible don't refuse.
  awk -F'ansible_host=' '/ansible_host=/{print $2}' "$ANS_DIR/inventory.ini" | while read -r ip; do
    ssh-keygen -R "$ip" >/dev/null 2>&1 || true
  done
}

build_k3s() {
  log "Ansible: wait for SSH"
  cd "$ANS_DIR"
  retry 5 20 ansible all -i inventory.ini -m ansible.builtin.wait_for_connection -a "timeout=300" >/dev/null
  log "Ansible: install k3s"
  # cloud-init may still hold the apt lock right after boot, so retry the whole play.
  retry 3 30 ansible-playbook -i inventory.ini k3s.yml
  cd "$ROOT"

  local want
  want=$(grep -c 'ansible_host=' "$ANS_DIR/inventory.ini")
  log "Wait for $want nodes Ready"
  nodes_ready() {
    [[ "$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready')" -ge "$want" ]]
  }
  wait_until $((NODES_TIMEOUT_MIN * 60)) "$want nodes Ready" nodes_ready
  kubectl get nodes -o wide
}

build_argocd() {
  log "Helm: install ArgoCD"
  # Once the "argocd" Application exists, ArgoCD manages itself; a Helm upgrade would fight it.
  if kubectl -n argocd get application argocd >/dev/null 2>&1; then
    echo "  ArgoCD already self-managed, skipping the Helm install"
    return
  fi
  local ver
  ver=$(awk '/chart: argo-cd/{f=1} f && /targetRevision:/{print $2; exit}' "$ROOT/gitops/apps/argocd.yaml")
  [[ -n "$ver" ]] || die "could not read the argo-cd version from gitops/apps/argocd.yaml"
  helm repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null
  retry 3 20 helm repo update argo >/dev/null
  retry 3 30 helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace \
    --version "$ver" --wait --timeout 10m
  wait_until 300 "argocd-initial-admin-secret" kubectl -n argocd get secret argocd-initial-admin-secret
}

build_secrets() {
  log "Create the Grafana admin secret (the only secret not in Git)"
  kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  if kubectl -n monitoring get secret grafana-admin >/dev/null 2>&1; then
    echo "  grafana-admin already exists, leaving it alone"
    return
  fi
  local pw="${GRAFANA_ADMIN_PASSWORD:-$(openssl rand -base64 18)}"
  kubectl -n monitoring create secret generic grafana-admin \
    --from-literal=admin-user=admin --from-literal=admin-password="$pw"
  umask 077
  printf '%s\n' "$pw" > "$STATE_DIR/grafana-admin-password"
}

build_gitops() {
  log "Apply the root app-of-apps"
  retry 5 15 kubectl apply -f "$ROOT/gitops/bootstrap/root-app.yaml"

  local expect
  expect=$(find "$ROOT/gitops/apps" -name '*.yaml' | wc -l | tr -d ' ')
  log "Wait for ArgoCD apps to be Synced and Healthy (up to ${APPS_TIMEOUT_MIN} min)"
  local start now bad total
  start=$(date +%s)
  while :; do
    # Nudge the root app so it doesn't wait for the 3 min poll.
    kubectl -n argocd annotate application root argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
    local list
    list=$(kubectl -n argocd get applications.argoproj.io \
      -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.sync.status}{" "}{.status.health.status}{"\n"}{end}' 2>/dev/null || true)
    total=$(printf '%s\n' "$list" | grep -c . || true)
    bad=$(printf '%s\n' "$list" | awk 'NF && !($2=="Synced" && $3=="Healthy"){print "    " $1 " sync=" $2 " health=" $3}')
    if (( total >= expect )) && [[ -z "$bad" ]]; then
      echo "  all $total apps Synced and Healthy"
      break
    fi
    now=$(date +%s)
    if (( now - start > APPS_TIMEOUT_MIN * 60 )); then
      printf '  %s apps seen (want >= %s); not ready:\n%s\n' "$total" "$expect" "$bad" >&2
      die "ArgoCD apps did not settle in ${APPS_TIMEOUT_MIN} min"
    fi
    echo "  [$(( (now - start) / 60 ))m] $total apps, not ready: $(printf '%s\n' "$bad" | grep -c . || true)"
    sleep 30
  done
}

summary() {
  log "Done"
  local argo_pw graf_pw
  argo_pw=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
  graf_pw=$(kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d)
  cat <<EOF
ArgoCD  http://argocd.k3s.lan   admin / $argo_pw
Grafana http://grafana.k3s.lan  admin / $graf_pw
Ingress VIP 192.168.1.45 (point *.k3s.lan at it)
Kubeconfig: $KUBECONFIG
  Your ~/.kube/config (context homelab-k3s) now has stale credentials; refresh it from the file above.
EOF
}

case "$MODE" in
  check)   preflight; log "All prerequisites met" ;;
  destroy) preflight; do_destroy ;;
  rebuild) preflight; do_destroy; build_vms; build_k3s; build_argocd; build_secrets; build_gitops; summary ;;
  build)   preflight; build_vms; build_k3s; build_argocd; build_secrets; build_gitops; summary ;;
esac
