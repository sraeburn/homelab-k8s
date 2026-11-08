# Loki log aggregation design

## Goal

Aggregate container logs from every pod in the cluster into Loki and query them in the existing Grafana (`grafana.k3s.lan`). Deployed GitOps-style through Argo CD, following the `monitoring` app pattern.

## Scope

- **In:** pod/container logs from all namespaces on all 3 nodes (todo, argocd, kube-system, traefik, metallb-system, monitoring, and the rest).
- **Out:** k3s journald units, Kubernetes events, node syslog, alerting rules, log dashboards. Each can be added later.

## Cluster constraints

- 3 nodes (k3s-server, k3s-agent1, k3s-agent2), no taints, so no tolerations are needed.
- Only storage class is `local-path` (node-pinned, reclaim Delete). Prometheus already uses a 10Gi PVC.
- k3s-server memory is ~66% used, so resource limits stay tight.

## Architecture

Two new Argo CD Applications in a new `logging` namespace (`CreateNamespace=true`), each multi-source like `gitops/apps/monitoring.yaml` (Helm chart + `$values` ref to this repo):

| File | Chart | Values |
|---|---|---|
| `gitops/apps/loki.yaml` | `grafana/loki` | `gitops/loki/values.yaml` |
| `gitops/apps/alloy.yaml` | `grafana/alloy` | `gitops/alloy/values.yaml` |

Chart versions are pinned at plan time. Sync policy matches `monitoring`: automated, `prune: false`, `selfHeal: true`.

### Loki

- `SingleBinary` deployment mode, 1 replica, auth disabled.
- Filesystem storage, TSDB schema (v13).
- 5Gi PVC on `local-path`.
- Compactor with retention enabled, `retention_period: 168h` (7d).
- Gateway, caches, canary, and self-monitoring disabled.
- Resources: request 256Mi, limit 512Mi memory.
- Service reachable in-cluster at `http://loki.logging:3100`.

### Alloy

- DaemonSet, one pod per node.
- Pipeline: `discovery.kubernetes` (pods) -> `discovery.relabel` -> `loki.source.kubernetes` (tails via the Kubernetes API, no host mounts) -> `loki.write` to Loki.
- Labels: `namespace`, `pod`, `container`, `app` (from `app.kubernetes.io/name`, falling back to `app`). Kept low-cardinality.
- Resources: memory limit ~128Mi.
- ClusterRole for pod discovery and `pods/log` access (provided by the chart).

### Grafana

Loki added as a datasource via `grafana.additionalDataSources` in `gitops/monitoring/values.yaml`, URL `http://loki.logging:3100`. Existing dashboards are untouched.

## Verification

1. `loki` and `alloy` Applications are Synced and Healthy; Loki and Alloy pods Running on all expected nodes.
2. Loki `/ready` returns `ready`.
3. In Grafana Explore, LogQL queries return recent lines for `{namespace="todo"}`, `{namespace="argocd"}`, and `{namespace="kube-system"}`.
4. Node memory stays within headroom (check `kubectl top nodes`).

## Risks

- Retention (7d) and PVC size (5Gi) are estimates. Check actual ingest after ~1 day and resize if needed.
- The `local-path` PVC pins Loki to one node; if that node dies Loki is down until it returns (same as Prometheus today). Acceptable for a homelab.
- Resizing a `local-path` PVC is not supported (`ALLOWVOLUMEEXPANSION` false); a resize means recreating the PVC and losing existing logs.
