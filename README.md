# k8s-workshop-nextcloud

A 3-day hands-on Kubernetes workshop where you deploy a production-grade
[Nextcloud](https://nextcloud.com/) instance on a local multi-node
[kind](https://kind.sigs.k8s.io/) cluster — from bare infrastructure to a
monitored, TLS-secured application stack. You build every layer yourself:
load balancer, ingress controller, database operator, persistent storage,
and observability. By the end, you present a live demo and walk through
your architecture choices under instructor questioning.

---

## What you'll build

```
           Browser (Windows: localhost / WSL2: kind Docker IP)
                │ HTTPS  nextcloud.local
                │ HTTPS  grafana.local
                ▼
  ┌─────────────────────────────────────────────────────────────────┐
  │  kind cluster  (1 control-plane  +  2 workers)                  │
  │                                                                 │
  │   MetalLB  ──  LoadBalancer IP allocation (L2, Docker subnet)   │
  │       │                                                         │
  │   Traefik Ingress Controller  ◄── cert-manager (self-signed TLS)│
  │       │                  │                                      │
  │       │ nextcloud.local  │ grafana.local                        │
  │       ▼                  ▼                                      │
  │  ┌──────────────┐   ┌────────────────────────────────┐         │
  │  │ ns: nextcloud│   │ ns: monitoring                 │         │
  │  │              │   │                                │         │
  │  │  ┌─────────┐ │   │  Prometheus                    │         │
  │  │  │Nextcloud│ │   │  Grafana                       │         │
  │  │  │  nginx  │ │   │  Alertmanager                  │         │
  │  │  │ PHP-FPM │ │   └────────────────────────────────┘         │
  │  │  └────┬────┘ │                                               │
  │  │       │      │                                               │
  │  │  ┌────▼────┐ ┌──────────┐                                   │
  │  │  │CloudNa- │ │  Redis   │                                    │
  │  │  │tivePG   │ │(sessions)│                                    │
  │  │  │primary  │ └──────────┘                                    │
  │  │  │replica  │                                                  │
  │  │  └─────────┘                                                  │
  │  │  PVCs: Nextcloud data + PostgreSQL data  (local-path)         │
  │  └──────────────┘                                                │
  └─────────────────────────────────────────────────────────────────┘
```

---

## Prerequisites

Install these tools **before Day 1**. Versions listed are the minimum required.

| Tool | Min. version | Install |
|------|-------------|---------|
| Docker Desktop / Docker Engine | latest | [docs.docker.com](https://docs.docker.com/get-docker/) |
| kind | v0.31 | [kind.sigs.k8s.io](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) |
| kubectl | v1.35 | [kubernetes.io](https://kubernetes.io/docs/tasks/tools/) |
| Helm | v3.17 | [helm.sh](https://helm.sh/docs/intro/install/) |

**Hardware**: 8 GB RAM minimum (16 GB recommended) · ~10 GB free disk space

**WSL2 users (Windows)** — read before setup day:
- Ubuntu 22.04+ with systemd enabled: add `[boot] systemd=true` to `/etc/wsl.conf`,
  then run `wsl --shutdown` from PowerShell and restart your distro.
- Low RAM? Create `%USERPROFILE%\.wslconfig` and add `[wsl2]` / `memory=6GB`.
- Keep all workshop files in your WSL2 home (`~/projects/...`), not under `/mnt/c/`.
- Browser access to `nextcloud.local` and `grafana.local` requires editing
  the **Windows** hosts file (as Administrator):
  `C:\Windows\System32\drivers\etc\hosts` → `127.0.0.1  nextcloud.local grafana.local`

---

## Quick start

```bash
# 1. Fork this repo on GitHub, then clone your fork
git clone https://github.com/<your-group>/k8s-workshop-nextcloud.git
cd k8s-workshop-nextcloud

# 2. Bootstrap the kind cluster (detects WSL2 automatically)
bash cluster/setup.sh

# 3. Verify all 3 nodes are Ready
kubectl get nodes

# 4. Open docs/DAY1.md and start working
```

The setup script checks prerequisites, creates the cluster, waits for all nodes
to be Ready, and prints your next steps. It is idempotent — safe to re-run.

---

## Workshop structure

| Day | Title | What you build |
|-----|-------|----------------|
| **Day 1** | Building the Foundation | kind cluster · MetalLB · Traefik · StorageClass · test Ingress |
| **Day 2** | Deploying Nextcloud | CloudNativePG · Redis · Nextcloud multi-container pod · PVCs · Ingress |
| **Day 3** | Observability & Presentation | kube-prometheus-stack · cert-manager · TLS · Grafana dashboards · group restitution |

Full step-by-step instructions for each day:
[`docs/DAY1.md`](docs/DAY1.md) · [`docs/DAY2.md`](docs/DAY2.md) · [`docs/DAY3.md`](docs/DAY3.md)

---

## Repository structure

```
k8s-workshop-nextcloud/
├── cluster/
│   ├── kind-config.yaml        # Provided — kind cluster definition (do not modify)
│   └── setup.sh                # Provided — bootstrap script
├── docs/
│   ├── DAY1.md                 # Day 1 instructions
│   ├── DAY2.md                 # Day 2 instructions
│   └── DAY3.md                 # Day 3 instructions
├── manifests/
│   ├── 00-namespaces/          # SKELETON — first thing to apply
│   ├── 01-metallb/             # README only — Helm install guide
│   ├── 02-traefik/             # README only — Helm install guide
│   ├── 03-storage/             # README only — StorageClass setup
│   ├── 04-postgresql/          # SKELETON — CloudNativePG Cluster CRD
│   ├── 05-redis/               # SKELETON — Redis Deployment + Service
│   ├── 06-nextcloud/           # SKELETONS — ConfigMap, Secret, PVC, Deployment, Service
│   ├── 07-ingress/             # SKELETON — Ingress rules + cert-manager TLS
│   └── 08-monitoring/          # SKELETON — kube-prometheus-stack Helm values
└── scripts/
    ├── validate-day1.sh        # Automated validation — run at end of Day 1
    ├── validate-day2.sh        # Automated validation — run at end of Day 2
    └── validate-day3.sh        # Automated validation — run at end of Day 3
```

Skeleton files use a `.yaml.skeleton` extension. Rename to `.yaml`, fill in every
`# TODO:` comment, and apply with `kubectl apply -f`. Do not remove a TODO until
you have actually addressed it — it helps you track what is still missing.

---

## Rules

**Groups**
- Work in groups of 4–5. One fork per group — everyone pushes to the same repo.
- Distribute the work. If one person touches every file, expect questions during
  restitution that the rest of the group cannot answer.

**Git discipline**
- Commit often. Each commit should represent one logical change.
- Write meaningful commit messages: `deploy redis with resource limits` is good,
  `update yaml` is not.
- Never commit secrets, `.env` files, or kubeconfig files. The `.gitignore` covers
  common cases — verify with `git status` before every push.

**On using AI tools**
- You are allowed to use AI assistants (Copilot, ChatGPT, Claude, etc.).
- You are responsible for every line you deploy. The instructor will ask you to
  explain your Deployment spec, your nginx ConfigMap, your Ingress annotations —
  any of it, without notice.
- *"The AI generated it"* is not an answer. If you cannot explain it, do not deploy it.

**Validation scripts**
- Run `bash scripts/validate-dayN.sh` before declaring a day complete.
- Scripts check cluster state, not your YAML. A passing script means the expected
  state is reached. A failing script tells you exactly what is missing.
- Do not modify the validation scripts.

---

## Evaluation

| Criterion | Weight | What the instructor looks at |
|-----------|--------|------------------------------|
| Cluster setup & infrastructure | 15% | kind cluster, MetalLB, Traefik, StorageClass all functional |
| Application deployment | 30% | Nextcloud + PostgreSQL + Redis running, login page accessible |
| Networking & exposure | 15% | Ingress config, TLS, correct proxy headers |
| Monitoring | 15% | Prometheus scraping, Grafana accessible, at least one meaningful dashboard |
| Code quality & structure | 10% | Clean YAML, proper namespacing, labels, resource limits defined |
| Restitution & understanding | 15% | Live demo quality, architecture walkthrough, Q&A answers |

The restitution is a 20–30 min live session per group: demo of Nextcloud (create
account, upload a file, show persistence), tour of Grafana, architecture walkthrough,
then open Q&A from the instructor and other groups.

---

## Useful links

| Resource | URL |
|----------|-----|
| Kubernetes docs | https://kubernetes.io/docs/ |
| kind docs | https://kind.sigs.k8s.io/docs/ |
| Helm docs | https://helm.sh/docs/ |
| Traefik Kubernetes Ingress | https://doc.traefik.io/traefik/providers/kubernetes-ingress/ |
| MetalLB configuration | https://metallb.io/configuration/ |
| CloudNativePG docs | https://cloudnative-pg.io/documentation/ |
| Nextcloud admin manual | https://docs.nextcloud.com/server/latest/admin_manual/ |
| cert-manager docs | https://cert-manager.io/docs/ |
| kube-prometheus-stack | https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack |
