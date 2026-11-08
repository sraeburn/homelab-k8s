# Ingress virtual IP (MetalLB)

## Goal

One floating IP, `192.168.1.45`, for all `*.k3s.lan` web traffic, so DNS survives any single node failing. Ingress only: the k3s API stays on `k3s-server` (192.168.1.40, single control plane).

## Current state

- Traefik is a `LoadBalancer` Service served by k3s ServiceLB (`svclb-traefik` DaemonSet); EXTERNAL-IP lists all three node IPs.
- Traefik runs as 1 replica.
- DNS (UniFi) points `*.k3s.lan` at 192.168.1.40 only.

## Decisions

| Question | Decision |
|---|---|
| VIP | `192.168.1.45` (checked unused: no ping, no ARP, no Service) |
| Tool | MetalLB in L2 mode, chart 0.16.2. ARP announcement from one healthy node, automatic failover. |
| Pool | `IPAddressPool` containing only `192.168.1.45/32`; `L2Advertisement` for it. |
| ServiceLB | Disabled via `/etc/rancher/k3s/config.yaml` (`disable: [servicelb]`) on the server, k3s restarted. |
| Traefik | 2 replicas and the VIP pinned by annotation, through a k3s `HelmChartConfig` (`gitops/traefik/`) applied by an ArgoCD Application. |
| API server HA | Out of scope. |

## Components

- `gitops/apps/metallb.yaml`: Application, chart `metallb` 0.16.2, namespace `metallb-system`, `CreateNamespace=true`, `ServerSideApply=true`, automated + selfHeal.
- `gitops/apps/metallb-config.yaml`: Application for `gitops/metallb/` (directory source) holding the pool and advertisement. Separate so CRDs exist before the CRs (retry on first sync).
- `gitops/apps/traefik-config.yaml`: Application for `gitops/traefik/` (destination namespace `kube-system`) holding `HelmChartConfig traefik`: `deployment.replicas: 2`, Service annotation `metallb.io/loadBalancerIPs: 192.168.1.45`.
- `ansible/k3s.yml`: new task on the server writing `/etc/rancher/k3s/config.yaml` (`disable: [servicelb]`) and restarting k3s when it changes.
- README: VIP section; DNS instructions point at the VIP.

## Cutover order

1. Push MetalLB + pool. Traefik Service still on ServiceLB. Verify MetalLB pods Running.
2. Push Traefik HelmChartConfig (2 replicas, VIP annotation). Verify 2 Traefik pods.
3. Disable ServiceLB and restart k3s (**user approval first**; brief API/UI outage). Traefik Service then gets 192.168.1.45.
4. Verify `curl -H 'Host: grafana.k3s.lan' http://192.168.1.45/` and the other hosts, from this Mac (same L2 subnet).
5. User repoints UniFi `*.k3s.lan` to 192.168.1.45.

## Rollback

Remove `disable: [servicelb]` from the k3s config and restart k3s; ServiceLB resumes and node-IP DNS still works. Nothing else needs undoing.

## Risks

- k3s restart briefly drops the API and UIs.
- UniFi may cache ARP, slowing failover by a few seconds.
- If the VIP is inside the DHCP range, a lease could collide (user to confirm outside range).
- Annotation name differs between MetalLB versions; verify with `kubectl -n kube-system get svc traefik` that EXTERNAL-IP becomes the VIP, otherwise rely on the pool (a single-address pool assigns it anyway).

## Verification

- `kubectl -n metallb-system get pods` Running.
- `kubectl -n kube-system get svc traefik` EXTERNAL-IP `192.168.1.45`.
- All sites return 200/302 through the VIP.
- Failover: stop MetalLB's announcing node (or `kubectl drain`) and confirm the VIP keeps answering within seconds.
