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
gitops/metallb/       MetalLB address pool (the ingress VIP)
gitops/traefik/       HelmChartConfig: Traefik replicas + VIP pin
gitops/charts/        own charts (hello-web)
```

## What's deployed
| App | Source | Notes |
|---|---|---|
| `root` | `gitops/bootstrap/root-app.yaml` | app-of-apps; syncs `gitops/apps/` (applied once by hand) |
| `argocd` | argo-cd chart 10.11.7 + `gitops/argocd/values.yaml` | ArgoCD manages itself, with resource limits |
| `podinfo` | upstream chart | third-party chart example |
| `metallb`, `metallb-config` | metallb chart 0.16.2 + `gitops/metallb/` | L2 virtual IP `192.168.1.45` for Traefik (k3s ServiceLB disabled in `ansible/k3s.yml`) |
| `traefik-config` | `gitops/traefik/` | k3s HelmChartConfig: Traefik at 2 replicas, pinned to the VIP |
| `monitoring` | kube-prometheus-stack 93.1.0 + `gitops/monitoring/` | Prometheus + Grafana (`grafana.k3s.lan`), 7d retention on a `local-path` PVC, Alertmanager off |
| `loki`, `alloy` | grafana charts 7.5.0 / 1.15.0 + `gitops/loki/`, `gitops/alloy/` | Loki (single binary, 7d retention, 5Gi `local-path` PVC) + Alloy DaemonSet shipping all pod logs; see Logging |
| `tempo` | grafana-community tempo chart 3.2.1 + `gitops/tempo/` | Tempo (single binary, 7d retention, 5Gi `local-path` PVC) in the `tracing` namespace, OTLP on 4317/4318; see Tracing |
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
kubectl -n argocd port-forward svc/argocd-server 8080:443   # https://localhost:8080 (before the Traefik ingress exists)

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

## Logging
Alloy (one pod per node) tails every pod's logs through the Kubernetes API and pushes them to Loki in the `logging` namespace. Logs only: no journald or node syslog, so k3s control-plane logs are not collected.

- **Query:** Grafana (http://grafana.k3s.lan) > Explore > Loki datasource, e.g. `{namespace="todo"}` or `{namespace="argocd", app="argocd-server"}`.
- **Labels:** `namespace`, `pod`, `container`, `app`. `app` comes from `app.kubernetes.io/name` or `app`, so pods that only set `k8s-app` (e.g. coredns) have none.
- **Retention:** 7d, 5Gi `local-path` volume. That volume cannot be resized in place, and it is lost with its node.

## Tracing
Traefik and the todo app (0.4.0+) send OTLP traces straight to Tempo (`http://tempo.tracing:4318`). A request to `todo.k3s.lan` becomes one trace: Traefik > the todo HTTP span > its JDBC `connection` / `query` spans. Sampling is 100%. Actuator requests (Prometheus scrapes, probes) are not traced.

- **Find traces:** Grafana (http://grafana.k3s.lan) > Explore > Tempo, then Search (service `traefik` or `todo`) or TraceQL, e.g. `{ name = "http post /api/todos" } >> { name = "query" }`.
- **Logs <-> traces:** the todo JSON logs carry `traceId`. In Explore > Loki the `TraceID` link opens the trace; in a trace, the logs button runs `{namespace=~".+"} |= "<traceId>"` against Loki.
- **Service map:** Tempo's metrics generator turns spans into `traces_service_graph_*` metrics and remote-writes them to Prometheus (which accepts remote-write). Grafana draws the graph (user > traefik > todo > database) in Explore > Tempo > Service Graph and in the "OpenTelemetry for HTTP services" dashboard (grafana.com 21587). The dashboard's HTTP request panels read OTel-named metrics (`http_server_request_duration_seconds_*`). The todo app (0.4.3+) pushes those over OTLP to Prometheus's OTLP receiver (`/api/v1/otlp/v1/metrics`, job `todo/todo`), renaming Micrometer's `http_server_requests_seconds_*` on the OTLP side only; Prometheus still scrapes the Micrometer names for the Spring Boot dashboard. Set `tracing.metricsEndpoint` in the todo chart to change the target, or empty it to disable the push.
- **Turn tracing off for the app:** set `tracing.enabled: false` in `gitops/charts/todo/values.yaml` (the app then exports nothing and keeps serving requests; it also keeps working while Tempo is down).
- **Demo services:** `notify` and `audit` (namespace `demo`, chart `gitops/charts/demo-service`, image from github.com/sraeburn/demo-service) exist only to make traces interesting. Todo (0.5.0+) calls `notify` on create (which calls `audit`) and `audit` on complete and delete, so a request becomes traefik > todo > notify > audit. Each service sleeps a random time and fails a few percent of requests (set `chaos.*` in `gitops/apps/notify.yaml` and `audit.yaml`); `curl 'http://notify.demo/api/work?fail=true&delayMs=500'` from inside the cluster forces either. A failed call is logged by todo and never fails the todo request.
- **Trace another app:** export OTLP/HTTP to `http://tempo.tracing:4318/v1/traces` with a `service.name`; Traefik already forwards the W3C `traceparent` header.
- **Caveat:** the 5Gi `local-path` volume cannot be resized in place and is lost with its node.

## Day-to-day
- **Deploy a change:** edit under `gitops/`, commit, push. ArgoCD polls about every 3 min; force it with
  `kubectl -n argocd annotate application <app> argocd.argoproj.io/refresh=hard --overwrite`.
- **ArgoCD admin (UI / CLI):** served by Traefik at http://argocd.k3s.lan (plain HTTP, `server.insecure`; needs the
  `*.k3s.lan` DNS record or an `/etc/hosts` entry).
  1. Get the password (only exists until you delete the secret; needs cluster access, `~/.kube/config` context `homelab-k3s`):
     `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo`
  2. UI: browse to http://argocd.k3s.lan and log in as `admin`.
  3. CLI: `argocd login argocd.k3s.lan --username admin --plaintext --grpc-web` (then e.g. `argocd app list`).
  4. Recommended: `argocd account update-password`, then `kubectl -n argocd delete secret argocd-initial-admin-secret`.
  Fallback if DNS or Traefik is down: `kubectl -n argocd port-forward svc/argocd-server 8080:80`, then http://localhost:8080.
- **Open dev / prod:** add the names to `/etc/hosts` (no wildcards there; needs sudo):
  `echo "192.168.1.45 dev.hello.k3s.lan prod.hello.k3s.lan" | sudo tee -a /etc/hosts`
  then browse to http://dev.hello.k3s.lan and http://prod.hello.k3s.lan.
- **Network-wide names:** the nodes are on the Default VLAN (192.168.1.0/24), so clients there need no firewall change.
  Add a local DNS record on the Cloud Gateway Max for `*.k3s.lan` -> 192.168.1.45, the ingress VIP (or one A record per name) instead of editing every `/etc/hosts`.
  192.168.1.45 is a MetalLB L2 virtual IP held by whichever node is healthy, so it survives a single node failing.
  Rollback to per-node ServiceLB: remove `disable: servicelb` from `/etc/rancher/k3s/config.yaml` on the server and restart k3s.
  Other VLANs (Homelab, Guest, IOT) need a firewall rule for TCP 80 to 192.168.1.45 if access is wanted.
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
