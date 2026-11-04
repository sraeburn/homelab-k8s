# Helm + ArgoCD homelab

3 Proxmox nodes → 3 VMs → k3s (1 server, 2 agents) → ArgoCD (via Helm) → GitOps apps.

## Setup
```sh
brew install helm argocd

# 1. VMs
cd terraform
cp terraform.tfvars.example terraform.tfvars   # edit: endpoint, token, node names, IPs
terraform init && terraform apply
terraform output -raw ansible_inventory > ../ansible/inventory.ini

# 2. k3s
cd ../ansible
ansible-playbook -i inventory.ini k3s.yml
export KUBECONFIG=$PWD/k3s.kubeconfig
kubectl get nodes

# 3. ArgoCD
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd -n argocd --create-namespace
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
kubectl -n argocd port-forward svc/argocd-server 8080:443   # https://localhost:8080

# 4. GitOps: push this repo to GitHub, then
kubectl apply -f gitops/bootstrap/root-app.yaml
```

## Exercises
- `helm lint|template gitops/charts/hello-web`; change `replicaCount`, push, watch ArgoCD sync.
- `kubectl edit` a deployment → self-heal reverts it.
- Override podinfo values in `gitops/apps/podinfo.yaml`.
- Add hooks, sync waves, an ApplicationSet; roll back with `git revert`.

## Teardown
`terraform destroy` in `terraform/`.
