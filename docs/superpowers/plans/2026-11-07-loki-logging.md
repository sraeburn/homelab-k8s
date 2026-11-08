# Loki Log Aggregation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Collect all pod logs into Loki and query them from the existing Grafana.

**Architecture:** Two Argo CD apps in a new `logging` namespace: `loki` (single binary, filesystem on a `local-path` PVC) and `alloy` (DaemonSet tailing pod logs via the Kubernetes API). Grafana gets a Loki datasource through the `monitoring` chart values.

**Tech Stack:** grafana/loki chart 7.5.0, grafana/alloy chart 1.15.0, kube-prometheus-stack 93.1.0 (existing), Argo CD.

**Spec:** `docs/superpowers/specs/2026-11-07-loki-logging-design.md`

## Global Constraints

- Namespace `logging`; Loki reachable at `http://loki.logging:3100`; charts pinned to `7.5.0` (loki) and `1.15.0` (alloy), repo `https://grafana.github.io/helm-charts`.
- Loki: `SingleBinary`, 1 replica, `auth_enabled: false`, filesystem + TSDB v13, 5Gi `local-path` PVC, `retention_period: 168h`, memory request 256Mi / limit 512Mi.
- Alloy: DaemonSet, memory limit 128Mi, labels `namespace`, `pod`, `container`, `app` only.
- Sync policy as `monitoring`: automated, `prune: false`, `selfHeal: true`, `CreateNamespace=true`.
- **Ask before every commit and push.** Imperative commit messages, small commits.
- Verification uses `helm template`, `kubectl --dry-run=server`, `kubectl`, and Grafana's datasource proxy API.

## Review Focus

- Loki must not start crash-looping or Pending on the PVC (Task 1 checks pod Ready and PVC Bound).
- Alloy must run on all 3 nodes, including k3s-server (Task 2 checks 3 Ready pods).
- Logs from `todo`, `argocd`, and `kube-system` must all be queryable, not just one namespace (Task 3).
- The `app` label must be non-empty for pods that only have `app.kubernetes.io/name` and for pods that only have `app` (Task 2 query).
- Adding the datasource must not break Grafana or existing dashboards (Task 3 checks Grafana Ready and the Prometheus datasource still present).
- Node memory must stay in headroom (Task 3 checks `kubectl top nodes`).

---

### Task 1: Loki

**Files:** Create `gitops/apps/loki.yaml`, `gitops/loki/values.yaml`.

- [ ] **Step 1:** `gitops/loki/values.yaml` with this content (rendered clean with `helm template`):

```yaml
deploymentMode: SingleBinary
loki:
  auth_enabled: false
  commonConfig:
    replication_factor: 1
  storage:
    type: filesystem
  schemaConfig:
    configs:
      - from: "2024-04-01"
        store: tsdb
        object_store: filesystem
        schema: v13
        index:
          prefix: index_
          period: 24h
  limits_config:
    retention_period: 168h
  compactor:
    retention_enabled: true
    delete_request_store: filesystem
singleBinary:
  replicas: 1
  persistence:
    enabled: true
    size: 5Gi
    storageClass: local-path
  resources:
    requests: { cpu: 50m, memory: 256Mi }
    limits: { memory: 512Mi }
read: { replicas: 0 }
write: { replicas: 0 }
backend: { replicas: 0 }
gateway: { enabled: false }
chunksCache: { enabled: false }
resultsCache: { enabled: false }
lokiCanary: { enabled: false }
test: { enabled: false }
minio: { enabled: false }
monitoring:
  selfMonitoring: { enabled: false }
  lokiCanary: { enabled: false }
```

- [ ] **Step 2:** `gitops/apps/loki.yaml`: copy the shape of `gitops/apps/monitoring.yaml` with two sources only (chart + `ref: values`, no dashboards path). Application `loki`, chart `loki`, repo `https://grafana.github.io/helm-charts`, `targetRevision: 7.5.0`, `releaseName: loki`, valueFile `$values/gitops/loki/values.yaml`, destination namespace `logging`, same syncPolicy and `CreateNamespace=true` (no `ServerSideApply` needed).
- [ ] **Step 3: Verify the render.** `helm template loki grafana/loki --version 7.5.0 -n logging -f gitops/loki/values.yaml | grep -c '^kind: StatefulSet'` prints `1`.
- [ ] **Step 4:** Ask, then commit "Add Loki" and push.
- [ ] **Step 5: Verify the rollout.** Refresh `root`. Expected: app `loki` Synced/Healthy; `kubectl -n logging get pod loki-0` is `2/2` or `1/1` Running; `kubectl -n logging get pvc` shows `storage-loki-0` Bound 5Gi; `kubectl -n logging exec loki-0 -c loki -- wget -qO- localhost:3100/ready` prints `ready`.

### Task 2: Alloy

**Files:** Create `gitops/apps/alloy.yaml`, `gitops/alloy/values.yaml`.

**Interfaces:** Consumes Loki's push endpoint `http://loki.logging:3100/loki/api/v1/push` from Task 1.

- [ ] **Step 1:** `gitops/alloy/values.yaml` (rendered clean with `helm template`). The chart default `controller.type` is already `daemonset`.

```yaml
alloy:
  resources:
    requests: { cpu: 25m, memory: 64Mi }
    limits: { memory: 128Mi }
  configMap:
    content: |
      discovery.kubernetes "pods" {
        role = "pod"
      }
      discovery.relabel "pods" {
        targets = discovery.kubernetes.pods.targets
        rule {
          source_labels = ["__meta_kubernetes_namespace"]
          target_label  = "namespace"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_name"]
          target_label  = "pod"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_container_name"]
          target_label  = "container"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_label_app_kubernetes_io_name", "__meta_kubernetes_pod_label_app"]
          separator     = ";"
          regex         = "([^;]+);.*|;(.+)"
          replacement   = "$1$2"
          target_label  = "app"
        }
      }
      loki.source.kubernetes "pods" {
        targets    = discovery.relabel.pods.output
        forward_to = [loki.write.default.receiver]
      }
      loki.write "default" {
        endpoint {
          url = "http://loki.logging:3100/loki/api/v1/push"
        }
      }
```

- [ ] **Step 2:** `gitops/apps/alloy.yaml`: same shape as `loki.yaml` with chart `alloy`, `targetRevision: 1.15.0`, `releaseName: alloy`, valueFile `$values/gitops/alloy/values.yaml`, namespace `logging`.
- [ ] **Step 3: Verify the render.** `helm template alloy grafana/alloy --version 1.15.0 -n logging -f gitops/alloy/values.yaml | grep -c '^kind: DaemonSet'` prints `1`.
- [ ] **Step 4:** Ask, then commit "Add Alloy log collector" and push.
- [ ] **Step 5: Verify the rollout.** Refresh `root`. Expected: app `alloy` Synced/Healthy; `kubectl -n logging get ds alloy` shows DESIRED=3 READY=3; no `error` lines in `kubectl -n logging logs ds/alloy --tail=50`.
- [ ] **Step 6: Verify ingestion and labels.** Port-forward `svc/loki` 3100, then `curl -s -G localhost:3100/loki/api/v1/label/namespace/values` includes `todo`, `argocd`, `kube-system`; and `curl -s -G localhost:3100/loki/api/v1/query --data-urlencode 'query=sum by (app) (count_over_time({namespace=~".+"}[5m]))'` returns series, none with an empty `app` for `todo` or `argocd` pods.

### Task 3: Grafana datasource

**Files:** Modify `gitops/monitoring/values.yaml` (the `grafana:` block, near line 46).

- [ ] **Step 1:** Under `grafana:` add `additionalDataSources` with one entry: `name: Loki`, `type: loki`, `uid: loki`, `access: proxy`, `url: http://loki.logging:3100`, `isDefault: false`.
- [ ] **Step 2: Verify the render.** `helm template monitoring prometheus-community/kube-prometheus-stack --version 93.1.0 -n monitoring -f gitops/monitoring/values.yaml | grep -c 'type: loki'` prints at least `1`.
- [ ] **Step 3:** Ask, then commit "Add Loki datasource to Grafana" and push.
- [ ] **Step 4: Verify the rollout.** `monitoring` app Synced/Healthy and Grafana pod Ready (the sidecar picks the datasource up without a restart; if it does not appear within a minute, `kubectl -n monitoring rollout restart deploy/monitoring-grafana`).
- [ ] **Step 5: Verify the datasource.** Using the Grafana admin credentials from the `grafana-admin` Secret against `grafana.k3s.lan`: `GET /api/datasources` lists both Prometheus and Loki; `GET /api/datasources/uid/loki/health` returns `OK`; and a query through `/api/datasources/proxy/uid/loki/loki/api/v1/query_range` with `{namespace="todo"}`, `{namespace="argocd"}`, and `{namespace="kube-system"}` each return at least one line.
- [ ] **Step 6: Check headroom.** `kubectl top nodes` shows no node above 85% memory; report the Loki and Alloy pod usage (`kubectl -n logging top pods`).
- [ ] **Step 7:** Update `README.md` with a short "Logging" note (Loki + Alloy in `logging`, 7d retention, how to query in Grafana Explore). Ask, then commit "Document logging stack".
