# Distributed tracing design

## Goal

Enable traces in Grafana: store them in Tempo and follow a request from Traefik (ingress) through the todo app to its database calls, with links between traces and logs. Deployed GitOps-style through Argo CD, following the `loki` app pattern.

## Scope

- **In:** Tempo; Traefik OTLP tracing; todo app OpenTelemetry tracing; Grafana Tempo datasource with trace-to-logs; Loki derived field linking `traceId` to Tempo.
- **Out:** service map and span metrics (needs Tempo's metrics generator), Argo CD traces, sampling policies, routing spans through Alloy.

## Cluster constraints

- 3 nodes, no taints; only the `local-path` storage class (node-pinned, reclaim Delete, not resizable).
- k3s-server memory was ~68% used when this was written, so resource limits stay tight.
- Traefik is the k3s-bundled chart (image 3.7.13), configured by `gitops/traefik/helmchartconfig.yaml`.
- The todo app is Spring Boot 4.1.2 in a separate repo (`~/Developer/java/todo`, image `ghcr.io/sraeburn/todo`), built and released by GitHub Actions; this repo pins the tag in `gitops/apps/todo.yaml`. Logs are already structured JSON (`logging.structured.format.console: logstash`), and Loki collects them.

## Architecture

Apps send OTLP directly to Tempo: Traefik over OTLP/HTTP and the todo app over OTLP/HTTP (`http://tempo.tracing:4318`). No collector hop.

### Tempo

- New Argo CD Application `tempo` in a new `tracing` namespace (`CreateNamespace=true`), multi-source like `gitops/apps/loki.yaml`: chart `tempo` 3.2.1 (Tempo 3.1.1) from repo `https://grafana-community.github.io/helm-charts` (the `grafana/tempo` chart is deprecated and moved there) + `$values/gitops/tempo/values.yaml`. Sync policy as `loki`: automated, `prune: false`, `selfHeal: true`.
- Single binary, 1 replica; OTLP gRPC (4317) and HTTP (4318) receivers enabled.
- Retention 168h (7d); 5Gi PVC on `local-path`; metrics generator off.
- Resources: memory request 256Mi, limit 512Mi; `memBallastSizeMbs: 0` (the chart default of 1024 would exceed the limit).
- In-cluster query endpoint `http://tempo.tracing:3200`.

### Traefik

`gitops/traefik/helmchartconfig.yaml` enables OTLP tracing over HTTP to `http://tempo.tracing:4318/v1/traces` with 100% sampling (`sampleRate: 1.0`). Traefik propagates the W3C `traceparent` header to backends, so the todo app's spans join the same trace.

### Todo app (separate repo)

- `build.gradle.kts`: add `org.springframework.boot:spring-boot-starter-opentelemetry`.
- `application.yml`: `management.tracing.sampling.probability: 1.0` and `management.opentelemetry.tracing.export.otlp.transport: http`.
- The OTLP endpoint is set by environment variable `MANAGEMENT_OPENTELEMETRY_TRACING_EXPORT_OTLP_ENDPOINT` from the Helm chart (`gitops/charts/todo`), value `http://tempo.tracing:4318/v1/traces`, so the image stays environment-agnostic. It is a chart value so it can be turned off.
- Released as todo 0.4.0 through the app's normal GitHub Actions flow; this repo's tag bump in `gitops/apps/todo.yaml` happens after the image exists.
- With tracing active, Spring adds `traceId`/`spanId` to the JSON logs.

### Grafana

In `gitops/monitoring/values.yaml` under `grafana.additionalDataSources`:

- New `Tempo` datasource, `uid: tempo`, `url: http://tempo.tracing:3200`, with `tracesToLogsV2` pointing at the `loki` datasource (filter by the `namespace` and `pod` labels, matching on the trace ID).
- The existing `Loki` datasource gains a derived field that extracts `traceId` from the JSON log line and links to the `tempo` datasource.

## Order of work

1. Tempo app, Grafana datasource links, Traefik tracing. Verify with Traefik-only traces.
2. Todo repo change and release (todo 0.4.0), then the chart env var and tag bump here.
3. Verify a full trace across Traefik, the todo app, and its database calls, plus the log-to-trace and trace-to-log links.

## Verification

1. `tempo` app Synced/Healthy; Tempo pod Ready and PVC Bound; `/ready` returns `ready`.
2. Grafana `Tempo` datasource health is OK; a search in Explore returns a Traefik trace after hitting `todo.k3s.lan`.
3. After the app release: one request to `todo.k3s.lan` produces one trace containing Traefik and `todo` spans, with database spans under the todo span.
4. A log line for that request shows a working link to its trace, and the trace links back to its logs.
5. `kubectl top nodes` shows no node above 85% memory.

## Risks

- Memory headroom on k3s-server is limited; check after Tempo is up and trim if needed.
- Traces and logs are only correlated if the app's logs contain `traceId`; verified in step 4 above.
- Cross-repo release: the todo repo change and image build are outside this repo, so each commit, push, and release there needs the user's approval.
- A 5Gi `local-path` PVC cannot be resized in place and is lost with its node; acceptable for a homelab, same as Loki.
- 100% sampling is fine at this traffic; revisit if volume grows.
