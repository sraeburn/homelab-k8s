# Monitoring: Prometheus + Grafana

## Goal

Run Prometheus and Grafana in the k3s cluster, deployed via ArgoCD like every other app. Collect:

- Kubernetes metrics (nodes, kubelet, cAdvisor, kube-state-metrics)
- ArgoCD metrics
- Metrics from the user's test apps, which publish Prometheus metrics

## Decisions

| Question | Decision |
|---|---|
| Persistence | Prometheus on a `local-path` PVC (~10Gi), 7d retention with a size cap. Grafana stateless; dashboards and datasources provisioned from Git. |
| Stack | `kube-prometheus-stack` (prometheus-community), single ArgoCD Application. |
| App discovery | `ServiceMonitor` / `PodMonitor` per app. Prometheus selects them in all namespaces. |
| Grafana access | Traefik Ingress at `grafana.k3s.lan`. Admin password in a hand-created Secret, never in Git. |
| Prometheus access | Internal only; `kubectl port-forward` when needed. |
| Alertmanager | Off (no alerting requested). |

## Components

### `gitops/apps/monitoring.yaml` (new)
ArgoCD Application following the headlamp pattern:
- Chart `kube-prometheus-stack`, version pinned at implementation time.
- Values from `gitops/monitoring/values.yaml` via a second `ref: values` source.
- Destination namespace `monitoring`; `CreateNamespace=true`, automated sync, `selfHeal: true`.
- `ServerSideApply=true` (large CRDs). `prune: false` initially, as with ArgoCD.

### `gitops/monitoring/values.yaml` (new)
- Prometheus: retention 7d + size cap, `local-path` PVC ~10Gi, resource requests/limits, `serviceMonitorSelectorNilUsesHelmValues: false` and the PodMonitor/rule/probe equivalents so all namespaces' monitors are picked up.
- Grafana: `admin.existingSecret: grafana-admin`, Traefik Ingress for `grafana.k3s.lan`, sidecar enabled for dashboards (ConfigMaps labelled `grafana_dashboard: "1"`, any namespace), resource limits.
- node-exporter and kube-state-metrics enabled.
- Alertmanager disabled.
- k3s: disable scrapes of kube-scheduler, kube-controller-manager, kube-proxy, and etcd (embedded in k3s, so targets would be permanently down).

### ArgoCD metrics (edit `gitops/argocd/values.yaml`)
Enable `metrics.enabled` and `metrics.serviceMonitor.enabled` for controller, server, repoServer, and applicationSet. Add the community ArgoCD Grafana dashboard as a labelled ConfigMap in Git.

### hello-web chart (edit `gitops/charts/hello-web`)
Optional `metrics` block in `values.yaml`:
- `nginx-prometheus-exporter` sidecar in the Deployment.
- Metrics port on the Service.
- `ServiceMonitor` template, gated on `metrics.enabled`, reusing the chart's selector labels.
- Enabled for dev and prod. This is the working end-to-end demo and the copy-paste template for other test apps.

Test apps need only: `/metrics` on a named Service port plus a ServiceMonitor like hello-web's.

## Rollout order

1. By hand: create namespace `monitoring` and Secret `grafana-admin` (`admin-user`, `admin-password`).
2. Commit 1: monitoring Application + values. ArgoCD installs CRDs and the stack.
3. Commit 2 (after the stack is healthy): ArgoCD metrics values, dashboard ConfigMap, hello-web changes. These need the ServiceMonitor CRD to exist first.

## Verification

- `kubectl -n monitoring get pods` all Running.
- Prometheus (port-forward) Status > Targets shows UP: ArgoCD (4 components), hello-web dev and prod, node-exporter, kube-state-metrics, kubelet, cAdvisor.
- Grafana loads at `http://grafana.k3s.lan`; k8s and ArgoCD dashboards show data.

## Risks

- **Memory:** stack is roughly 1-1.5GB; check node RAM before sizing and set limits on every component.
- **local-path PVC:** pins Prometheus to one node; data is lost if the node is lost. Accepted.
- **DNS:** `grafana.k3s.lan` needs the existing `*.k3s.lan` record or an `/etc/hosts` entry.

## README updates

- Monitoring row in the deployed-apps table.
- Section covering the Secret command, the Grafana URL, adding a ServiceMonitor to a new app, and adding a dashboard.
