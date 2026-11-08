# Helm + ArgoCD homelab

Proxmox VMs (Terraform) → k3s (Ansible) → ArgoCD (Helm, then self-managed) → GitOps apps.

| Node | Proxmox | IP | Role |
|---|---|---|---|
| k3s-server | pve1 | 192.168.1.40 | control plane |
| k3s-agent1 | pve2 | 192.168.1.41 | agent |
| k3s-agent2 | pve2 | 192.168.1.42 | agent |
| k3s-agent3 | pve3 | 192.168.1.43 | agent (planned, pve3 offline) |

## Layout
```
terraform/            bpg/proxmox: one cloud-init VM per entry in var.nodes
ansible/k3s.yml       installs k3s server + agents, fetches kubeconfig
gitops/bootstrap/     root app-of-apps (applied once by hand)
gitops/apps/          one ArgoCD Application per app (root syncs this dir)
gitops/argocd/        Helm values for ArgoCD itself (resource limits, metrics)
gitops/monitoring/    Helm values + Grafana dashboards for kube-prometheus-stack
gitops/charts/        own charts (hello-web)
```

## What's deployed
| App | Source | Notes |
|---|---|---|
| `root` | `gitops/bootstrap/root-app.yaml` | app-of-apps; syncs `gitops/apps/` (applied once by hand) |
| `argocd` | argo-cd chart 10.11.7 + `gitops/argocd/values.yaml` | ArgoCD manages itself, with resource limits |
| `podinfo` | upstream chart | third-party chart example |
| `monitoring` | kube-prometheus-stack 93.1.0 + `gitops/monitoring/` | Prometheus + Grafana (`grafana.k3s.lan`), 7d retention on a `local-path` PVC, Alertmanager off |
| `hello-web-dev`, `hello-web-prod` | ApplicationSet `hello-web-envs` | one template, per-env replicas / image tag / host |

Environments (edit the list in `gitops/apps/hello-web-envs.yaml`):

| Env | Namespace | Replicas | Image | Host |
|---|---|---|---|---|
| dev | `hello-dev` | 2 | nginx:1.28 | dev.hello.k3s.lan |
| prod | `hello-prod` | 4 | nginx:1.27 | prod.hello.k3s.lan |

## Setup
```sh
brew install helm argocd

# 1. VMs
cd terraform
cp terraform.tfvars.example terraform.tfvars   # edit: endpoint, API token, nodes, IPs, gateway
terraform init && terraform apply
terraform output -raw ansible_inventory > ../ansible/inventory.ini

# 2. k3s
cd ../ansible
ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -i inventory.ini k3s.yml
export KUBECONFIG=$PWD/k3s.kubeconfig
kubectl get nodes

# 3. ArgoCD (first install via Helm; the "argocd" Application takes over after)
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd -n argocd --create-namespace --version 10.11.7
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
kubectl -n argocd port-forward svc/argocd-server 8080:443   # https://localhost:8080

# 4. GitOps: push this repo to GitHub, then
kubectl apply -f gitops/bootstrap/root-app.yaml
```

## Monitoring
Prometheus + Grafana (kube-prometheus-stack) scrape Kubernetes, ArgoCD, and any app with a ServiceMonitor.

- **First install only:** create the namespace and the Grafana admin Secret by hand (never in Git) before the `monitoring` app syncs:
  `kubectl create namespace monitoring`
  `kubectl -n monitoring create secret generic grafana-admin --from-literal=admin-user=admin --from-literal=admin-password="$(openssl rand -base64 18)"`
- **Grafana:** http://grafana.k3s.lan (needs the `*.k3s.lan` DNS record or an `/etc/hosts` entry), user `admin`. Password:
  `kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo`
- **Prometheus** (no ingress): `kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090`, then http://localhost:9090 (Status > Targets).
- **Monitor a new app:** expose `/metrics` on a named Service port and ship a ServiceMonitor selecting that Service, like
  `gitops/charts/hello-web/templates/servicemonitor.yaml`. Prometheus picks up ServiceMonitors in every namespace, no labels needed.
  hello-web shows the pattern for non-Prometheus apps (an nginx exporter sidecar, enabled with `metrics.enabled`).
- **Add a dashboard:** commit a ConfigMap labelled `grafana_dashboard: "1"` under `gitops/monitoring/dashboards/`.
- **Caveat:** Prometheus data lives on one node's `local-path` volume, so it is lost if that node is lost.

## Day-to-day
- **Deploy a change:** edit under `gitops/`, commit, push. ArgoCD polls about every 3 min; force it with
  `kubectl -n argocd annotate application <app> argocd.argoproj.io/refresh=hard --overwrite`.
- **ArgoCD admin (UI / CLI) via tunnel:** ArgoCD has no Ingress, so tunnel in with `kubectl port-forward`
  (needs cluster access: `~/.kube/config` context `homelab-k3s`, or `export KUBECONFIG=ansible/k3s.kubeconfig`).
  1. In its own terminal (it blocks; restart it if ArgoCD pods restart):
     `kubectl -n argocd port-forward svc/argocd-server 8080:443`
  2. Get the password (only exists until you delete the secret):
     `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo`
  3. UI: browse to https://localhost:8080 (accept the self-signed cert warning), log in as `admin`.
  4. CLI: `argocd login localhost:8080 --username admin --insecure --grpc-web` (then e.g. `argocd app list`).
  5. Optional: `argocd account update-password`, then `kubectl -n argocd delete secret argocd-initial-admin-secret`.
- **Open dev / prod:** add the names to `/etc/hosts` (no wildcards there; needs sudo):
  `echo "192.168.1.40 dev.hello.k3s.lan prod.hello.k3s.lan" | sudo tee -a /etc/hosts`
  then browse to http://dev.hello.k3s.lan and http://prod.hello.k3s.lan.
- **Network-wide names:** the nodes are on the Default VLAN (192.168.1.0/24), so clients there need no firewall change.
  Add a local DNS record on the Cloud Gateway Max for `*.k3s.lan` -> 192.168.1.40 (or one A record per name) instead of editing every `/etc/hosts`.
  Note this targets one node; a VIP would remove that single point of failure.
  Other VLANs (Homelab, Guest, IOT) need a firewall rule for TCP 80 to 192.168.1.40-43 if access is wanted.
- **Scale or re-version an env:** change `replicas` / `tag` in `gitops/apps/hello-web-envs.yaml`, push. Promote to prod by setting prod's `tag` to the version dev has been running; roll back with `git revert`.
- **Recreate an env's pods without a version change:** `kubectl -n hello-prod rollout restart deployment/hello-web-prod`
  (rolling, no downtime; ArgoCD does not revert it).
- **See where pods run:** `kubectl get pods -A -o wide`.
- **Add a node:** add an entry to `var.nodes` in `terraform.tfvars` (VMs are keyed by `vm_name`, so several can share a Proxmox node), `terraform apply`, regenerate the inventory, re-run the playbook. Existing nodes are skipped.
- **Upgrade ArgoCD:** bump `targetRevision` in `gitops/apps/argocd.yaml` and push.

## Gotchas learned
- **Don't interrupt `terraform apply`:** killing a hung apply leaves VMs in Proxmox that Terraform doesn't know about. A second VM with the same IP then breaks everything intermittently (flaky downloads, host-key changes). Check Proxmox for duplicates.
- **Guest agent:** Ubuntu cloud images have no `qemu-guest-agent`. The playbook installs it and `main.tf` sets `agent { enabled = true }`, so Proxmox shows real IP and memory (with the agent off, the memory bar can read over 100% because it counts the guest's page cache).
  New VMs get the package on first boot from a cloud-init vendor-data snippet (`proxmox_virtual_environment_file.vendor` in `main.tf`; needs the Snippets content type on the `local` storage). Verified on a throwaway VM (apply took 45 s and the provider read the VM's IP via the agent). If a new node ever hangs `terraform apply` for ~15 min, the snippet didn't run; check `/var/log/cloud-init.log` on the VM, and as a fallback set `enabled = false` for that apply, run the playbook, then set it back and apply with `-target` (drain first; the provider restarts the VM). The snippet is excluded from updates (`ignore_changes`), so existing VMs are never touched by it.
- **Image storage is per node:** `local` storage isn't shared, so the cloud image is downloaded once per Proxmox node.
- **SSH to Proxmox:** the bpg provider needs root SSH to each PVE node (key loaded in ssh-agent) to import disks.
- **k3s installer downloads are flaky:** the playbook retries the install 3 times; it's guarded by `creates:`, so re-running is safe.
- **Self-heal:** `kubectl scale` or `kubectl edit` on managed apps is reverted within seconds. Change Git instead.
- **Don't `helm uninstall argocd`:** the original Helm release record still exists, but ArgoCD owns the resources now.
- **Secrets:** `terraform.tfvars` (API token) and `*.kubeconfig` are gitignored. Keep it that way.
- **Deleting an app file doesn't delete its resources:** the Applications have no deletion finalizer, so `root` prunes the Application but its workloads keep running. Add `resources-finalizer.argocd.argoproj.io` to `metadata.finalizers` first for a clean uninstall.
- **Old ReplicaSets with 0 pods are normal:** they're Deployment rollout history (`revisionHistoryLimit`, default 10).
- **Plain `kubectl` uses `~/.kube/config`:** it now points at this cluster (context `homelab-k3s`; the old config is backed up as `~/.kube/config.bak-20261103`).
- **Both agents are on pve2:** Kubernetes spreads pods across nodes, not Proxmox hosts. A pve2 outage takes most of prod down until `k3s-agent3` exists on pve3.

## Exercises
- `helm lint|template gitops/charts/hello-web`; change `replicaCount`, push, watch the sync.
- Delete a pod and see where it lands (`kubectl get pods -o wide`); the chart spreads replicas with `topologySpreadConstraints`.
- Override podinfo values in `gitops/apps/podinfo.yaml`.
- Roll back with `git revert`.
- Promote a new nginx tag dev → prod through Git.
- Later: sync waves and hooks, ingress with TLS, wildcard DNS for `*.k3s.lan`.

## Next session
- **Try Argo Rollouts** (canary / blue-green deploys). Plan:
  1. Add an Application for the `argo/argo-rollouts` Helm chart in `gitops/apps/`.
  2. `brew install argoproj/tap/kubectl-argo-rollouts` for the plugin and dashboard.
  3. Add a chart flag so `hello-web` can render a `Rollout` (canary strategy) instead of a `Deployment`, and try it in **dev** first.
  4. Optional: manual sync gate for prod (remove `automated` from prod's sync policy in the ApplicationSet).
- **Bring pve3 back:** uncomment the `k3s-agent3` line in `terraform.tfvars`, `terraform apply`, regenerate the inventory, re-run the playbook. New VMs get the guest agent automatically from cloud-init (see the guest-agent gotcha).

## Teardown
`terraform destroy` in `terraform/`.
