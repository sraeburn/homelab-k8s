# Ingress VIP (MetalLB) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Serve all `*.k3s.lan` ingress traffic on floating IP 192.168.1.45 via MetalLB, with Traefik at 2 replicas.

**Architecture:** MetalLB (L2) announces the VIP; k3s ServiceLB is disabled so MetalLB owns Traefik's LoadBalancer Service. Traefik is scaled by a k3s `HelmChartConfig`.

**Tech Stack:** MetalLB 0.16.2, k3s HelmChartConfig, ArgoCD, Ansible.

**Spec:** `docs/superpowers/specs/2026-11-08-ingress-vip-design.md`

## Global Constraints

- VIP `192.168.1.45` (pool `/32`), namespace `metallb-system`, chart version `0.16.2`.
- Disabling ServiceLB and restarting k3s needs the user's explicit approval at that moment.
- **Ask before every commit and push.** Imperative commit messages, small commits.
- Verification is `helm template`, `kubectl --dry-run=server`, `kubectl`, `curl`.

## Review Focus

- Traefik Service must end with EXTERNAL-IP 192.168.1.45 only (Task 3 checks it).
- Ingress must keep working through every node's old IP until cutover finishes, then through the VIP (Tasks 2-3 curl checks).
- Pool must contain only the VIP so nothing else grabs it (Task 1 checks the rendered CR).
- A rerun of `ansible/k3s.yml` must not restart k3s when config is unchanged (Task 3 uses a handler/`changed` guard).

---

### Task 1: MetalLB and pool

**Files:** Create `gitops/apps/metallb.yaml`, `gitops/apps/metallb-config.yaml`, `gitops/metallb/pool.yaml`.

- [ ] **Step 1:** `gitops/apps/metallb.yaml`: Application `metallb`, repo `https://metallb.github.io/metallb`, chart `metallb`, `targetRevision: 0.16.2`, `releaseName: metallb`, destination `metallb-system`, automated selfHeal, prune false, syncOptions `CreateNamespace=true`, `ServerSideApply=true`. No custom values file.
- [ ] **Step 2:** `gitops/metallb/pool.yaml`: `IPAddressPool` `ingress` (addresses `192.168.1.45/32`) and `L2Advertisement` `ingress` (ipAddressPools `[ingress]`), both in `metallb-system`.
- [ ] **Step 3:** `gitops/apps/metallb-config.yaml`: Application `metallb-config`, repo `https://github.com/sraeburn/homelab-k8s.git`, path `gitops/metallb`, destination `metallb-system`, automated selfHeal, retry limit 5 with backoff (CRDs may not exist on the first attempt).
- [ ] **Step 4: Verify the render.** `helm template metallb metallb/metallb --version 0.16.2 -n metallb-system >/dev/null` exits 0; `grep -c 192.168.1.45 gitops/metallb/pool.yaml` prints 1.
- [ ] **Step 5:** Ask, then commit "Add MetalLB with ingress VIP pool" and push.
- [ ] **Step 6: Verify the rollout.** Refresh `root`. Expected: apps `metallb`, `metallb-config` Synced/Healthy; `kubectl -n metallb-system get pods` all Running; `kubectl -n metallb-system get ipaddresspool ingress` exists. Traefik Service unchanged.

### Task 2: Traefik replicas and VIP pin

**Files:** Create `gitops/traefik/helmchartconfig.yaml`, `gitops/apps/traefik-config.yaml`.

- [ ] **Step 1:** `HelmChartConfig` `traefik` in `kube-system` (`apiVersion: helm.cattle.io/v1`) with `valuesContent` setting `deployment.replicas: 2` and `service.annotations: {metallb.io/loadBalancerIPs: 192.168.1.45}`.
- [ ] **Step 2:** `gitops/apps/traefik-config.yaml`: Application `traefik-config`, path `gitops/traefik`, destination `kube-system`, automated selfHeal, prune false.
- [ ] **Step 3: Verify.** `kubectl apply --dry-run=server -f gitops/traefik/helmchartconfig.yaml` succeeds.
- [ ] **Step 4:** Ask, then commit "Run Traefik with two replicas" and push.
- [ ] **Step 5: Verify the rollout.** `kubectl -n kube-system get deploy traefik` shows 2/2; sites still return 200/302 via `192.168.1.40`.

### Task 3: Disable ServiceLB (needs user approval at run time)

**Files:** Modify `ansible/k3s.yml`.

- [ ] **Step 1:** In play "k3s server" add a task writing `/etc/rancher/k3s/config.yaml` with content `disable:\n  - servicelb\n` (`ansible.builtin.copy`, mode 0644), `notify: restart k3s`, plus handler `restart k3s` (`ansible.builtin.systemd`, name `k3s`, state restarted).
- [ ] **Step 2: Verify.** `ansible-playbook --syntax-check -i ansible/inventory.ini ansible/k3s.yml` exits 0.
- [ ] **Step 3:** Ask, then commit "Disable k3s ServiceLB in favor of MetalLB" and push.
- [ ] **Step 4: Ask the user for approval to run the play** (restarts k3s; brief outage). Then `cd ansible && ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -i inventory.ini k3s.yml --tags`-less full run; expect only the config task and handler to change.
- [ ] **Step 5: Verify.** `kubectl -n kube-system get svc traefik` EXTERNAL-IP is `192.168.1.45`; `kubectl -n kube-system get ds | grep svclb` is empty; `curl -H 'Host: grafana.k3s.lan' http://192.168.1.45/`, same for `argocd`, `headlamp`, `dev.hello`, `prod.hello`: each 200/302.
- [ ] **Step 6: Failover check.** Find the announcing node (`kubectl -n metallb-system logs -l component=speaker | grep -i announc`), `kubectl drain` it (ignore daemonsets), confirm the VIP still answers within ~10s, then `kubectl uncordon`. Ask first.

### Task 4: README and DNS

**Files:** Modify `README.md`.

- [ ] **Step 1:** Add `metallb` row to the deployed-apps table and `gitops/metallb/`, `gitops/traefik/` to the layout; add an "Ingress VIP" note (192.168.1.45, MetalLB L2, Traefik x2, rollback = remove `disable: servicelb` and restart k3s).
- [ ] **Step 2:** Change the `/etc/hosts` and UniFi DNS instructions to use `192.168.1.45` instead of `192.168.1.40`, and drop the single-node SPOF note.
- [ ] **Step 3:** Ask, then commit "Document ingress VIP" and push.
- [ ] **Step 4:** Tell the user to repoint the UniFi `*.k3s.lan` record to 192.168.1.45.
