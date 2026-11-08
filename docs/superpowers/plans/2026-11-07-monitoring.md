# Monitoring (Prometheus + Grafana) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy kube-prometheus-stack via ArgoCD and scrape Kubernetes, ArgoCD, and hello-web metrics, with Grafana at `grafana.k3s.lan`.

**Architecture:** One ArgoCD Application (`monitoring`) installs kube-prometheus-stack from the prometheus-community Helm repo, with values and a dashboards directory from this repo (headlamp pattern). Apps are discovered through ServiceMonitors in any namespace. ArgoCD and hello-web ship their own ServiceMonitors.

**Tech Stack:** k3s, ArgoCD multi-source Applications, Helm, kube-prometheus-stack, nginx-prometheus-exporter.

**Spec:** `docs/superpowers/specs/2026-11-07-monitoring-design.md`

## Global Constraints

- Chart: `kube-prometheus-stack` from `https://prometheus-community.github.io/helm-charts`; pin the exact latest version found in Task 1 Step 1.
- Namespace `monitoring`; Secret `grafana-admin` with keys `admin-user`, `admin-password`, created by hand, never in Git.
- Prometheus: retention `7d`, size cap, PVC ~`10Gi` on `local-path`. Alertmanager off. Grafana stateless.
- Grafana host `grafana.k3s.lan`, `ingressClassName: traefik`.
- Disable scrapes of kube-scheduler, kube-controller-manager, kube-proxy, etcd (embedded in k3s).
- `ServerSideApply=true`, `prune: false` on the monitoring Application.
- Every component has resource requests and a memory limit.
- Repo remote is `https://github.com/sraeburn/homelab-k8s.git`, branch `main`; ArgoCD only sees pushed commits.
- **User rule: ask before every commit and push. Commit messages: imperative present tense, small commits.**
- Verification here is `helm template` / `helm lint` / `kubectl` (no unit-test framework).

## Review Focus

- Grafana pod crash-loops if `grafana-admin` is missing: Task 1 creates it before sync and checks the pod.
- A ServiceMonitor in a namespace or without Helm labels is silently ignored: Task 1 asserts the rendered Prometheus has empty-selector (select-all) monitor selectors.
- hello-web with `metrics.enabled=false` must render exactly as before (no sidecar, ConfigMap, or ServiceMonitor): Task 3 diffs the render.
- ServiceMonitor endpoint port name must equal the Service port name, or the target never appears: Task 3 asserts both are `metrics`.
- ArgoCD ServiceMonitors need the CRD from Task 1; applying Task 2 first leaves `argocd` OutOfSync: Task 2 gates on the CRD.

---

### Task 1: Monitoring Application and values

**Files:**
- Create: `gitops/apps/monitoring.yaml`
- Create: `gitops/monitoring/values.yaml`

**Interfaces:**
- Produces: namespace `monitoring`; ServiceMonitor/PodMonitor CRDs (`monitoring.coreos.com`); Prometheus selecting all monitors in all namespaces; Grafana sidecar loading ConfigMaps labelled `grafana_dashboard: "1"` from any namespace; Grafana at `http://grafana.k3s.lan`.

- [ ] **Step 1: Find the chart version.** Run `helm repo add prometheus-community https://prometheus-community.github.io/helm-charts && helm repo update && helm search repo prometheus-community/kube-prometheus-stack`. Record the version as `<VER>`. Expected: one row with a CHART VERSION.
- [ ] **Step 2: Write `gitops/monitoring/values.yaml`** with these keys (resource sizes: Prometheus requests 200m/1Gi, limit mem 1.5Gi; Grafana 50m/128Mi, limit 256Mi; operator, kube-state-metrics, node-exporter small requests with 128-256Mi limits):
  - `alertmanager.enabled: false`
  - `kubeScheduler.enabled`, `kubeControllerManager.enabled`, `kubeProxy.enabled`, `kubeEtcd.enabled`: all `false`
  - `prometheus.prometheusSpec`: `retention: 7d`, `retentionSize: 8GB`, `serviceMonitorSelectorNilUsesHelmValues`, `podMonitorSelectorNilUsesHelmValues`, `ruleSelectorNilUsesHelmValues`, `probeSelectorNilUsesHelmValues` all `false`, `storageSpec.volumeClaimTemplate.spec` with `storageClassName: local-path`, `ReadWriteOnce`, `10Gi`
  - `grafana`: `admin.existingSecret: grafana-admin`, `admin.userKey: admin-user`, `admin.passwordKey: admin-password`, `ingress` enabled with `ingressClassName: traefik`, `hosts: [grafana.k3s.lan]`, `path: /`; `sidecar.dashboards.enabled: true`, `searchNamespace: ALL`
- [ ] **Step 3: Write `gitops/apps/monitoring.yaml`** copying `gitops/apps/headlamp.yaml`'s structure: name `monitoring`, chart `kube-prometheus-stack` at `<VER>`, `releaseName: monitoring`, values from `$values/gitops/monitoring/values.yaml`, destination namespace `monitoring`, automated `selfHeal: true` and `prune: false`, syncOptions `CreateNamespace=true` and `ServerSideApply=true`.
- [ ] **Step 4: Verify the render.** Run `helm template monitoring prometheus-community/kube-prometheus-stack --version <VER> -n monitoring -f gitops/monitoring/values.yaml > $TMPDIR/mon.yaml`. Expected: exit 0. Then `grep -A1 serviceMonitorSelector $TMPDIR/mon.yaml` shows `{}` (select-all), and `grep -c "kind: Alertmanager" $TMPDIR/mon.yaml` prints `0`.
- [ ] **Step 5: Create namespace and Secret by hand.** `kubectl create namespace monitoring` then `kubectl -n monitoring create secret generic grafana-admin --from-literal=admin-user=admin --from-literal=admin-password="$(openssl rand -base64 18)"`. Retrieve later with `kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d`. Expected: `secret/grafana-admin created`.
- [ ] **Step 6: Ask the user, then commit and push** `gitops/apps/monitoring.yaml gitops/monitoring/values.yaml` as "Add kube-prometheus-stack monitoring app".
- [ ] **Step 7: Verify the rollout.** `kubectl -n argocd annotate application root argocd.argoproj.io/refresh=hard --overwrite`, then wait. Expected: `kubectl -n argocd get application monitoring` shows `Synced`/`Healthy`; `kubectl -n monitoring get pods` all Running (check node memory with `kubectl top nodes` if any are Pending/OOMKilled); `kubectl get crd servicemonitors.monitoring.coreos.com` exists; `curl -s -o /dev/null -w '%{http_code}' -H 'Host: grafana.k3s.lan' http://192.168.1.40/` prints `302` or `200`.

### Task 2: ArgoCD metrics and dashboard

**Gate:** Task 1 Step 7 passed (ServiceMonitor CRD exists).

**Files:**
- Modify: `gitops/argocd/values.yaml`
- Modify: `gitops/apps/monitoring.yaml` (add third source)
- Create: `gitops/monitoring/dashboards/argocd-dashboard.yaml`

**Interfaces:**
- Consumes: Prometheus selecting all ServiceMonitors; Grafana dashboard sidecar (Task 1).
- Produces: ServiceMonitors for argocd controller, server, repo-server, applicationset; an "ArgoCD" Grafana dashboard.

- [ ] **Step 1: Edit `gitops/argocd/values.yaml`.** Under each of `controller`, `server`, `repoServer`, `applicationSet` add `metrics: { enabled: true, serviceMonitor: { enabled: true } }`.
- [ ] **Step 2: Verify the render.** `helm template argocd argo/argo-cd --version 10.11.7 -n argocd -f gitops/argocd/values.yaml | grep -c "kind: ServiceMonitor"`. Expected: `4`.
- [ ] **Step 3: Create the dashboard ConfigMap.** Download `https://raw.githubusercontent.com/argoproj/argo-cd/master/examples/dashboard.json` into the scratchpad, then `kubectl create configmap argocd-dashboard --from-file=argocd.json=<file> -n monitoring --dry-run=client -o yaml`, add label `grafana_dashboard: "1"`, and save as `gitops/monitoring/dashboards/argocd-dashboard.yaml`. If the dashboard's datasource is a variable it needs no change; if it names a hard-coded datasource, replace it with `Prometheus`.
- [ ] **Step 4: Add a third source to `gitops/apps/monitoring.yaml`:** `repoURL` the repo, `targetRevision: main`, `path: gitops/monitoring/dashboards`.
- [ ] **Step 5: Ask the user, then commit and push** as "Scrape ArgoCD metrics and add ArgoCD dashboard".
- [ ] **Step 6: Verify.** Hard-refresh `argocd` and `monitoring` apps; both `Synced`. `kubectl -n argocd get servicemonitor` lists 4. In Prometheus (`kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090`) Status > Targets shows the 4 ArgoCD targets UP. The ArgoCD dashboard appears in Grafana with data.

### Task 3: hello-web metrics

**Gate:** Task 1 Step 7 passed.

**Files:**
- Modify: `gitops/charts/hello-web/values.yaml`
- Modify: `gitops/charts/hello-web/templates/deployment.yaml`
- Modify: `gitops/charts/hello-web/templates/service.yaml`
- Create: `gitops/charts/hello-web/templates/nginx-configmap.yaml`
- Create: `gitops/charts/hello-web/templates/servicemonitor.yaml`
- Modify: `gitops/apps/hello-web-envs.yaml`

**Interfaces:**
- Produces: values `metrics.enabled` (bool, default `false`), `metrics.exporter.image` (default `nginx/nginx-prometheus-exporter:1.4.0`; confirm the tag exists on Docker Hub), `metrics.exporter.port` (default `9113`). When enabled: nginx ConfigMap, exporter sidecar, Service port named `metrics`, ServiceMonitor.

- [ ] **Step 1: Capture the baseline.** `helm template hw gitops/charts/hello-web > $TMPDIR/before.yaml`.
- [ ] **Step 2: Add `metrics` values** (enabled `false`, exporter image and port, exporter resources requests 10m/16Mi, limit mem 32Mi).
- [ ] **Step 3: `nginx-configmap.yaml`**, gated on `metrics.enabled`: a ConfigMap `<fullname>-nginx` with `default.conf` holding two servers: port 80 serving `/usr/share/nginx/html` as the stock image does, and port 8081 exposing `location = /stub_status { stub_status; allow 127.0.0.1; deny all; }`.
- [ ] **Step 4: Edit the Deployment**, gated on `metrics.enabled`: mount the ConfigMap's `default.conf` over `/etc/nginx/conf.d/default.conf` (subPath) in the `web` container; add container `exporter` running the exporter image with arg `--nginx.scrape-uri=http://127.0.0.1:8081/stub_status` and `containerPort` `9113` named `metrics`.
- [ ] **Step 5: Edit the Service:** name the existing port `http`; when enabled add port `metrics` (`.Values.metrics.exporter.port`, targetPort `metrics`).
- [ ] **Step 6: `servicemonitor.yaml`**, gated on `metrics.enabled`: `ServiceMonitor` with the chart labels, `selector.matchLabels` = selector labels, one endpoint `port: metrics`, `interval: 30s`.
- [ ] **Step 7: Verify defaults are unchanged.** `helm template hw gitops/charts/hello-web | diff $TMPDIR/before.yaml -`. Expected: only the Service port gains `name: http`; no sidecar, ConfigMap, or ServiceMonitor.
- [ ] **Step 8: Verify enabled render.** `helm template hw gitops/charts/hello-web --set metrics.enabled=true` renders without error; it contains one `ServiceMonitor`, and the Service port name and the ServiceMonitor endpoint port are both `metrics` (`grep -n "name: metrics\|port: metrics"`). Also run `helm lint gitops/charts/hello-web --set metrics.enabled=true`.
- [ ] **Step 9: Enable per environment.** In `gitops/apps/hello-web-envs.yaml` add helm parameter `metrics.enabled` with value `'true'` to the template.
- [ ] **Step 10: Ask the user, then commit and push** as "Add nginx exporter and ServiceMonitor to hello-web".
- [ ] **Step 11: Verify.** `kubectl -n hello-dev get pods` shows 2/2 containers ready; `kubectl -n hello-dev get servicemonitor` exists; Prometheus targets show hello-web dev and prod UP; query `nginx_connections_active` returns series for both namespaces; `curl -H 'Host: dev.hello.k3s.lan' http://192.168.1.40/` still returns the nginx page.

### Task 4: README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add a row** to the "What's deployed" table for `monitoring` (kube-prometheus-stack `<VER>`, Prometheus + Grafana, Alertmanager off, `local-path` PVC).
- [ ] **Step 2: Add a "Monitoring" section** covering: creating namespace and `grafana-admin` Secret before first sync (command from Task 1 Step 5); Grafana at `http://grafana.k3s.lan` (needs the `*.k3s.lan` DNS record or an `/etc/hosts` entry) with the password-retrieval command; Prometheus via `kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090`; how to monitor a new app (`/metrics` on a named Service port plus a ServiceMonitor like `gitops/charts/hello-web/templates/servicemonitor.yaml`); how to add a dashboard (ConfigMap labelled `grafana_dashboard: "1"` under `gitops/monitoring/dashboards/`); the caveat that Prometheus data lives on one node's local-path volume.
- [ ] **Step 3: Update the Layout block** to list `gitops/monitoring/`.
- [ ] **Step 4: Ask the user, then commit and push** as "Document monitoring stack".
