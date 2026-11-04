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
- **Open hello-web:** http://192.168.1.40 (any node IP; the Ingress has no host rule).
- **Add a node:** add an entry to `var.nodes` in `terraform.tfvars` (VMs are keyed by `vm_name`, so several can share a Proxmox node), `terraform apply`, regenerate the inventory, re-run the playbook. Existing nodes are skipped.
- **Upgrade ArgoCD:** bump `targetRevision` in `gitops/apps/argocd.yaml` and push.

## Gotchas learned
- **Don't interrupt `terraform apply`:** killing a hung apply leaves VMs in Proxmox that Terraform doesn't know about. A second VM with the same IP then breaks everything intermittently (flaky downloads, host-key changes). Check Proxmox for duplicates.
- **Guest agent:** Ubuntu cloud images have no `qemu-guest-agent`, so the VM resource sets `agent { enabled = false }`; otherwise apply waits 15 min.
- **Image storage is per node:** `local` storage isn't shared, so the cloud image is downloaded once per Proxmox node.
- **SSH to Proxmox:** the bpg provider needs root SSH to each PVE node (key loaded in ssh-agent) to import disks.
- **k3s installer downloads are flaky:** the playbook retries the install 3 times; it's guarded by `creates:`, so re-running is safe.
- **Self-heal:** `kubectl scale` or `kubectl edit` on managed apps is reverted within seconds. Change Git instead.
- **Don't `helm uninstall argocd`:** the original Helm release record still exists, but ArgoCD owns the resources now.
- **Secrets:** `terraform.tfvars` (API token) and `*.kubeconfig` are gitignored. Keep it that way.

## Exercises
- `helm lint|template gitops/charts/hello-web`; change `replicaCount`, push, watch the sync.
- Delete a pod and see where it lands (`kubectl get pods -o wide`); the chart spreads replicas with `topologySpreadConstraints`.
- Override podinfo values in `gitops/apps/podinfo.yaml`.
- Roll back with `git revert`.
- Next: an ApplicationSet (dev/prod), sync waves and hooks, ingress with TLS.

## Teardown
`terraform destroy` in `terraform/`.
