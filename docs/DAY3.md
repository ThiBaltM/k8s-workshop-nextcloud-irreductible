# Day 3 — Observability & Presentation

**Duration**: ~3h technical work + ~1h40 group restitutions  
**Prerequisites**: Day 2 complete — `bash scripts/validate-day2.sh` passes with no failures.  
**Goal**: TLS on all Ingresses, a working Prometheus/Grafana monitoring stack, and a polished
group presentation that demonstrates understanding of what you built.

---

## Objectives

By the end of the technical work you will have:

- [ ] cert-manager installed, self-signed ClusterIssuer configured
- [ ] TLS enabled on the Nextcloud Ingress (self-signed certificate)
- [ ] kube-prometheus-stack deployed (Prometheus + Grafana + Alertmanager)
- [ ] Grafana accessible via Ingress with TLS at `grafana.local`
- [ ] At least one meaningful Grafana dashboard showing cluster or application metrics
- [ ] CloudNativePG metrics visible in Prometheus

---

## Architecture — end of Day 3 (full stack)

```
  Browser
    │ https://nextcloud.local    https://grafana.local
    ▼
  ┌────────────────────────────────────────────────────────────────────┐
  │  kind cluster                                                      │
  │                                                                    │
  │  MetalLB ── Traefik ──────────────────────────────────────────┐   │
  │  ◄── cert-manager (ClusterIssuer)                             │   │
  │       ↕ TLS Secrets auto-created                              │   │
  │                                                               │   │
  │  ┌─────────────────────────────────────────────────────────┐  │   │
  │  │ namespace: nextcloud    (unchanged from Day 2)           │  │   │
  │  │  Nextcloud pod  ─  PostgreSQL (CNPG)  ─  Redis          │  │   │
  │  │  Ingress: nextcloud.local  (+ TLS annotation)           │  │   │
  │  └─────────────────────────────────────────────────────────┘  │   │
  │                                                               │   │
  │  ┌─────────────────────────────────────────────────────────┐  │   │
  │  │ namespace: monitoring                                   │  │   │
  │  │  Prometheus (scrapes all namespaces)                    │  │   │
  │  │  Grafana  ←  Ingress: grafana.local (+ TLS)            │  │   │
  │  │  Alertmanager                                           │  │   │
  │  │  ServiceMonitor / PodMonitor → CloudNativePG metrics    │  │   │
  │  └─────────────────────────────────────────────────────────┘  │   │
  └────────────────────────────────────────────────────────────────┘   │
  └────────────────────────────────────────────────────────────────────┘
```

---

## Step 1 — Install cert-manager

cert-manager is a Kubernetes operator that automates TLS certificate lifecycle:
it watches annotated `Ingress` resources, requests certificates from a configured
issuer, stores them as `kubernetes.io/tls` Secrets, and renews them before expiry.

**Install cert-manager via Helm**.

**Critical**: cert-manager requires its CRDs to be installed **before** the operator.
There are two ways:
- Add `--set crds.enabled=true` to the `helm install` command (installs CRDs as part of
  the chart), or
- Apply the CRD manifest separately before `helm install` (see cert-manager docs)

Either method works. The Helm flag is simpler.

**Hints**:
- cert-manager docs: https://cert-manager.io/docs/installation/helm/
  The page has the exact repo URL, chart name, and recommended install command.
- cert-manager runs in its own namespace (`cert-manager` by default)
- After install, **wait** for the webhook pod to be fully `Running` before creating any
  `Issuer` or `Certificate` resources. Applying issuers too early returns a TLS handshake
  error from the webhook.

**Verify**:

```bash
kubectl get pods -n cert-manager
```

Three pods expected: `cert-manager`, `cert-manager-cainjector`, `cert-manager-webhook`,
all `Running`.

---

## Step 2 — Create a self-signed ClusterIssuer

An `Issuer` (or `ClusterIssuer`) tells cert-manager how to sign certificates.
A `ClusterIssuer` is cluster-scoped — it can issue certificates in any namespace.

Create a `ClusterIssuer` using the `selfSigned` issuer type.

**File**: `manifests/07-ingress/cert-manager/` — create your files here.

**Hints**:
- `apiVersion: cert-manager.io/v1`, `kind: ClusterIssuer`
- The `selfSigned` issuer spec is intentionally minimal — there is no external CA, cert-manager
  generates a self-signed cert for each request
- A self-signed certificate will trigger a browser warning ("Your connection is not private").
  That is expected — click through. In production you would use Let's Encrypt or an internal CA.

**Verify**:

```bash
kubectl get clusterissuer
kubectl describe clusterissuer <name>
```

The `Status.Conditions` should show `Ready: True`.

---

## Step 3 — Enable TLS on the Nextcloud Ingress

**File**: `manifests/07-ingress/ingress.yaml.skeleton` (edit your existing Ingress)

Add TLS to the Nextcloud Ingress by:
1. Adding a `tls` block to the Ingress spec (hostname + secret name where cert-manager
   will store the certificate)
2. Adding the cert-manager annotation that tells it which issuer to use
3. Updating `OVERWRITEPROTOCOL` in your ConfigMap to `https`
4. Updating `OVERWRITECLIURL` to `https://nextcloud.local`

After updating the ConfigMap, trigger a pod restart so Nextcloud picks up the new values.

**Hints**:
- The cert-manager annotation: `cert-manager.io/cluster-issuer: <issuer-name>`
- The `tls[].secretName` is the name cert-manager will use for the Secret it creates.
  Choose a name that makes sense (e.g., `nextcloud-tls`)
- cert-manager creates the Secret automatically when it sees the annotated Ingress.
  You do not create the Secret yourself.
- The certificate may take 10–30 seconds to appear after applying the Ingress

**Verify**:

```bash
kubectl get certificate -n nextcloud
kubectl get secret <tls-secret-name> -n nextcloud
```

Certificate status should be `Ready: True`.

```bash
curl -k https://nextcloud.local
# -k skips cert verification (expected for self-signed)
# Expected: HTTP 200 or redirect to login
```

Update your hosts file entry if you haven't already:
- Linux/macOS: point `nextcloud.local` to `127.0.0.1`
- Windows: same in `C:\Windows\System32\drivers\etc\hosts`

Open `https://nextcloud.local` in your browser. Accept the self-signed certificate
warning and verify the login page loads over HTTPS.

---

### Checkpoint 1 — TLS

- [ ] cert-manager pods all `Running`
- [ ] `ClusterIssuer` in `Ready: True` state
- [ ] `Certificate` resource in `nextcloud` namespace: `Ready: True`
- [ ] `https://nextcloud.local` loads in browser (with cert warning, that is fine)

---

## Step 4 — Install kube-prometheus-stack

kube-prometheus-stack is a Helm chart that bundles Prometheus, Grafana, Alertmanager,
and a set of pre-configured dashboards and alerts for Kubernetes cluster monitoring.

**File**: `manifests/08-monitoring/values.yaml.skeleton`

**Install via Helm** into the `monitoring` namespace.

**Key values to configure** in the Helm values override file:

| Setting | Why you need to configure it |
|---------|------------------------------|
| Grafana admin password | Default is randomly generated — you need a known value |
| Grafana Ingress enabled | To expose Grafana at `grafana.local` |
| Grafana Ingress hostname | `grafana.local` |
| Grafana persistence enabled | So dashboards survive pod restarts |
| Prometheus persistence enabled | So metrics survive pod restarts |

**Hints**:
- Helm repo: `https://prometheus-community.github.io/helm-charts`, chart: `kube-prometheus-stack`
- The chart installs a large number of CRDs. Pass `--set crds.enabled=true` (or the
  equivalent depending on the chart version — check the chart's README on GitHub for
  the current flag name)
- `helm show values prometheus-community/kube-prometheus-stack | less` — the values file
  is very large; search for `grafana.ingress` and `prometheus.prometheusSpec.storageSpec`
- The namespace must exist (`monitoring` — you created it on Day 1)
- The install takes 2–3 minutes; many images to pull

**Verify**:

```bash
kubectl get pods -n monitoring
```

Expected: Prometheus, Grafana, Alertmanager pods all `Running`. Several operator pods too.

---

## Step 5 — Access Grafana and explore dashboards

Add `grafana.local` to your hosts file (point to the Traefik IP or `127.0.0.1`).

Open `http://grafana.local` in your browser. Log in with the admin password you configured.

**Explore**:
1. **Dashboards → Browse**: kube-prometheus-stack ships with pre-built dashboards for
   node resources, pod resources, kubelet, CoreDNS, etc. Find the Kubernetes / Pods dashboard.
2. **Explore**: Run a PromQL query manually. Try `kube_pod_status_phase{namespace="nextcloud"}`.
3. Find a metric that shows Nextcloud pod CPU usage over time.

---

## Step 6 — Enable TLS on the Grafana Ingress

Same approach as Step 3. Either:
- Add TLS to the Grafana Ingress in the kube-prometheus-stack Helm values (preferred —
  keeps everything in one place), or
- Apply a separate Ingress resource that overrides the one created by the chart

Add the cert-manager annotation, a `tls` block, and a TLS secret name.

Then add `grafana.local` to your hosts file and verify `https://grafana.local` loads
with a self-signed certificate warning.

**Verify**:

```bash
kubectl get certificate -n monitoring
```

---

### Checkpoint 2 — monitoring

- [ ] All monitoring pods `Running`
- [ ] Grafana reachable at `https://grafana.local` (with cert warning)
- [ ] Prometheus UI accessible (you can use `kubectl port-forward` for this one)
- [ ] At least one Grafana dashboard is showing data

---

## Step 7 — Monitor CloudNativePG

CloudNativePG exposes a Prometheus metrics endpoint. Prometheus needs a `PodMonitor`
or `ServiceMonitor` resource to discover and scrape it.

**Hints**:
- CNPG pods expose metrics on port `9187` (or `metrics` — check the pod labels with
  `kubectl describe pod <cnpg-pod> -n nextcloud`)
- kube-prometheus-stack deploys a Prometheus operator that watches for `ServiceMonitor`
  and `PodMonitor` CRDs across the cluster
- Create a `PodMonitor` (`apiVersion: monitoring.coreos.com/v1`) in the `nextcloud`
  namespace that selects CNPG pods by their labels and scrapes the metrics port
- The Prometheus operator must be configured to pick up monitors from other namespaces —
  check the `prometheus.prometheusSpec.podMonitorNamespaceSelector` Helm value
  (setting it to `{}` means "all namespaces")
- After applying, verify in the Prometheus UI (**Status → Targets**) that the CNPG targets
  appear and are `UP`

**Verify**:

```bash
kubectl get podmonitor -n nextcloud
```

In the Prometheus UI (port-forward if needed): **Status → Targets** should show CNPG
endpoints in `UP` state.

In Grafana: search for a dashboard covering PostgreSQL or CloudNativePG. The CNPG project
publishes a community Grafana dashboard — find it and import it using its dashboard ID.

---

### Final Checkpoint — Day 3 Validation

```bash
bash scripts/validate-day3.sh
```

**Manual checklist**:
- [ ] cert-manager running, `ClusterIssuer` `Ready: True`
- [ ] `https://nextcloud.local` accessible (self-signed cert warning expected)
- [ ] `https://grafana.local` accessible
- [ ] Prometheus scraping CNPG metrics
- [ ] At least one Grafana dashboard showing live data

---

## Common pitfalls

**cert-manager webhook not ready**  
Applying a `ClusterIssuer` or annotated Ingress too quickly after `helm install` returns
a webhook TLS error. Wait until all three cert-manager pods are fully `Running`, not just
`ContainerCreating`. `kubectl rollout status deployment -n cert-manager cert-manager-webhook`

**Certificate stuck in `False` / `Issuing` state**  
Check `kubectl describe certificate <name> -n <ns>` for events. Common causes:
- Issuer name in annotation doesn't match the `ClusterIssuer` name exactly
- The Ingress annotation uses `cert-manager.io/issuer` (namespace-scoped) instead of
  `cert-manager.io/cluster-issuer` (cluster-scoped) — make sure you're using the right one
- The webhook was not ready when the Ingress was first applied — delete and re-apply the Ingress

**Grafana Ingress not created by the chart**  
If `grafana.ingress.enabled: true` is not in your values file, the chart creates no Ingress.
`helm upgrade` with the corrected values file will create it.

**kube-prometheus-stack CRD error during install**  
Some versions of the chart require CRDs to be installed separately before `helm install`.
If you get "no kind X is registered" errors, check the chart's installation documentation
for the current recommended CRD install method.

**Prometheus not scraping CNPG**  
Two common reasons:
1. The `PodMonitor` label selector doesn't match the CNPG pod labels. Use
   `kubectl get pods -n nextcloud --show-labels` to see the actual labels, then match them.
2. Prometheus is not watching the namespace where the `PodMonitor` lives. Check
   `podMonitorNamespaceSelector` in the Helm values — `{}` means all namespaces.

**OVERWRITEPROTOCOL not updated after adding TLS**  
If Nextcloud still redirects to `http://` after enabling HTTPS, the ConfigMap still has
`OVERWRITEPROTOCOL: http`. Update the ConfigMap and restart the pod. Nextcloud uses
this value to build redirect URLs — a mismatch causes infinite redirect loops.

---

## Bonus — Grafana

If you finish the technical work early:

- **Custom dashboard**: Create a Grafana dashboard from scratch using PromQL. Show at least:
  - Nextcloud pod CPU and memory usage
  - PostgreSQL active connections
  - Redis memory usage
  Export it as JSON and commit it to your repo.

- **Alerting**: Create a Prometheus alerting rule that fires when the Nextcloud pod is
  not ready. Configure Alertmanager to... do nothing (no email config in the workshop) —
  but verify the alert appears in the Alertmanager UI.

- **Grafana provisioning**: Instead of manually importing the CNPG dashboard, provision
  it automatically via the Helm values (`grafana.dashboards` or `grafana.dashboardProviders`).

---

## Restitution format

Each group presents for **20–30 minutes**. All group members must participate.

### Structure

**1. Live demo** (~8 min)
- Open `https://nextcloud.local` — show the browser certificate (even if it warns)
- Log in as admin
- Upload a file, navigate to it, copy the sharing link
- Delete the Nextcloud pod and wait for it to restart — show that the file is still there
- Show the Grafana dashboard during the restart to demonstrate monitoring in action

**2. Architecture walkthrough** (~8 min)  
Walk through what you deployed, layer by layer. The instructor will ask you to open
files in your repo and explain specific choices.

Expect questions such as:
- *"Why does the Nextcloud pod have two containers? What would happen if you used one?"*
- *"Open your nginx ConfigMap. Walk me through this `fastcgi_pass` line."*
- *"Your PostgreSQL cluster has 2 instances. Which is the primary right now? How do you know?"*
- *"How does cert-manager know to create a certificate for `nextcloud.local`?"*
- *"What would break if MetalLB was not installed?"*
- *"Where is Nextcloud's data actually stored on disk? On which node?"*

**3. Difficulties and how you solved them** (~5 min)  
Pick the two or three hardest problems you hit. Explain what the symptom was, what you
tried, and what fixed it. This is not a confession session — it demonstrates debugging
methodology.

**4. Q&A** (~5 min)  
Open questions from the instructor and other groups. Other groups are encouraged to
challenge your choices — be ready to defend them.

### What the instructor is evaluating

Beyond whether things work, the instructor looks for:
- **Understanding over recitation**: Can you explain *why* a configuration works, not
  just *what* it does?
- **Debugging reasoning**: When you describe a problem you hit, do you describe a logical
  debugging process or "I changed things until it worked"?
- **Trade-off awareness**: Could you articulate why `local-path` storage is acceptable
  here but not in production? Why 1 replica for Nextcloud but 2 instances for PostgreSQL?
- **Collective knowledge**: Does the whole group understand the full stack, or is one
  person carrying the rest?

### Preparation checklist

Before the restitution:
- [ ] `bash scripts/validate-day3.sh` passes
- [ ] You can open a browser and demonstrate Nextcloud end-to-end without fumbling
- [ ] Every team member has read and can explain at least one skeleton file they filled in
- [ ] You can show Grafana with live data (not empty dashboards)
- [ ] You have thought through the "why" questions above — not memorized answers, but
  actual understanding
- [ ] Your repo is committed and pushed (the instructor may look at your git history)
