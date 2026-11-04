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
gitops/argocd/        Helm values for ArgoCD itself (resource limits)
gitops/charts/        own charts (hello-web)
```

## What's deployed
| App | Source | Notes |
|---|---|---|
| `root` | `gitops/bootstrap/root-app.yaml` | app-of-apps; syncs `gitops/apps/` (applied once by hand) |
| `argocd` | argo-cd chart 10.11.7 + `gitops/argocd/values.yaml` | ArgoCD manages itself, with resource limits |
| `podinfo` | upstream chart | third-party chart example |
| `hello-web` | `gitops/charts/hello-web` | original app, namespace `hello-web`, catch-all Ingress |
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

## Day-to-day
- **Deploy a change:** edit under `gitops/`, commit, push. ArgoCD polls about every 3 min; force it with
  `kubectl -n argocd annotate application <app> argocd.argoproj.io/refresh=hard --overwrite`.
- **Open the ArgoCD UI:** run `kubectl -n argocd port-forward svc/argocd-server 8080:443` in its own terminal
  (it blocks; restart it if ArgoCD pods restart), then browse to https://localhost:8080 and log in as `admin`.
  Initial password: `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`
  (only valid until you change it).
- **Open hello-web:** http://192.168.1.40 (any node IP; the Ingress has no host rule).
- **Open dev / prod:** add the names to `/etc/hosts` (no wildcards there; needs sudo):
  `echo "192.168.1.40 dev.hello.k3s.lan prod.hello.k3s.lan" | sudo tee -a /etc/hosts`
  then browse to http://dev.hello.k3s.lan and http://prod.hello.k3s.lan.
- **Scale or re-version an env:** change `replicas` / `tag` in `gitops/apps/hello-web-envs.yaml`, push. Promote to prod by setting prod's `tag` to the version dev has been running; roll back with `git revert`.
- **Recreate an env's pods without a version change:** `kubectl -n hello-prod rollout restart deployment/hello-web-prod`
  (rolling, no downtime; ArgoCD does not revert it).
- **See where pods run:** `kubectl get pods -A -o wide`.
- **Add a node:** add an entry to `var.nodes` in `terraform.tfvars` (VMs are keyed by `vm_name`, so several can share a Proxmox node), `terraform apply`, regenerate the inventory, re-run the playbook. Existing nodes are skipped.
- **Upgrade ArgoCD:** bump `targetRevision` in `gitops/apps/argocd.yaml` and push.

## Gotchas learned
- **Don't interrupt `terraform apply`:** killing a hung apply leaves VMs in Proxmox that Terraform doesn't know about. A second VM with the same IP then breaks everything intermittently (flaky downloads, host-key changes). Check Proxmox for duplicates.
- **Guest agent:** Ubuntu cloud images have no `qemu-guest-agent`. The playbook installs it and `main.tf` sets `agent { enabled = true }`, so Proxmox shows real IP and memory (with the agent off, the memory bar can read over 100% because it counts the guest's page cache).
  New VMs get the package on first boot from a cloud-init vendor-data snippet (`proxmox_virtual_environment_file.vendor` in `main.tf`; needs the Snippets content type on the `local` storage). **Not yet tested on a new VM:** if the first new node (pve3's agent) hangs `terraform apply` for ~15 min, the snippet didn't run; check `/var/log/cloud-init.log` on the VM, and as a fallback set `enabled = false` for that apply, run the playbook, then set it back and apply with `-target` (drain first; the provider restarts the VM). The snippet is excluded from updates (`ignore_changes`), so existing VMs are never touched by it.
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
- **Bring pve3 back:** uncomment the `k3s-agent3` line in `terraform.tfvars`, `terraform apply`, regenerate the inventory, re-run the playbook. This is the first real test of the cloud-init guest-agent snippet (see the guest-agent gotcha).

## Teardown
`terraform destroy` in `terraform/`.
