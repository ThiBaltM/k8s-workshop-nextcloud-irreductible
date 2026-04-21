# Day 1 — Building the Foundation

**Duration**: ~4h40  
**Goal**: A fully functional infrastructure layer — load balancer, ingress controller,
storage class — ready to receive the application stack on Day 2.

---

## Objectives

By the end of Day 1 you will have:

- [ ] A 3-node kind cluster (1 control-plane + 2 workers), all nodes `Ready`
- [ ] Namespaces: `nextcloud`, `monitoring`, `traefik`, `metallb-system`
- [ ] MetalLB installed and configured with an IP address pool
- [ ] Traefik running as a DaemonSet with a MetalLB-assigned external IP
- [ ] A default StorageClass available for persistent volumes
- [ ] A test nginx deployment reachable via Ingress from your browser

---

## Architecture — end of Day 1

```
  Browser
    │ http://test.local
    ▼
  ┌────────────────────────────────────────────────────────────────┐
  │  kind cluster                                                  │
  │                                                                │
  │  ┌─────────────────────────────────────────────────────────┐  │
  │  │ metallb-system                                          │  │
  │  │  controller (Deployment)  +  speaker (DaemonSet/node)   │  │
  │  │  IPAddressPool ── L2Advertisement                        │  │
  │  └──────────────────────────────┬──────────────────────────┘  │
  │                                 │ assigns LoadBalancer IP      │
  │  ┌──────────────────────────────▼──────────────────────────┐  │
  │  │ traefik                                                 │  │
  │  │  DaemonSet  (nodeSelector: ingress-ready=true)          │  │
  │  │  Service/LoadBalancer  →  ExternalIP from MetalLB       │  │
  │  └──────────────────────────────┬──────────────────────────┘  │
  │                                 │ routes Ingress rules         │
  │  ┌──────────────────────────────▼──────────────────────────┐  │
  │  │ default                                                 │  │
  │  │  Ingress(test.local) → ClusterIP Service → nginx pod    │  │
  │  └─────────────────────────────────────────────────────────┘  │
  │                                                                │
  │  StorageClass: standard  (local-path-provisioner, default)     │
  └────────────────────────────────────────────────────────────────┘
```

---

## Step 1 — Bootstrap the cluster

Run the setup script from the repo root:

```bash
bash cluster/setup.sh
```

It checks prerequisites, creates the cluster from `cluster/kind-config.yaml`, waits for
all nodes to be Ready, and prints next steps. It is idempotent — safe to re-run.

**After it completes, verify**:

```bash
kubectl get nodes
kubectl get pods -n kube-system
kubectl get nodes --show-labels | grep ingress-ready
```

Expected: 3 nodes `Ready`, system pods `Running` or `Completed`, the control-plane node
has the label `ingress-ready=true` (set by `kind-config.yaml`).

> That label is not decoration — you will use it in Step 5 to pin Traefik to the
> control-plane so host ports 80/443 are reachable from the host.

---

## Step 2 — Create namespaces

**File**: `manifests/00-namespaces/namespaces.yaml.skeleton`

Rename the skeleton to `namespaces.yaml` and create 4 namespaces:
`nextcloud`, `monitoring`, `traefik`, `metallb-system`.

Add at least one label to each (e.g. `name: <namespace-name>`). Labels enable
NetworkPolicy selectors and make `kubectl` filtering easier.

**Hints**:
- `apiVersion: v1`, `kind: Namespace`
- Multiple resources in one file: separate with `---`
- The names `metallb-system` and `traefik` must match exactly — downstream Helm charts
  reference them

**Apply and verify**:

```bash
kubectl apply -f manifests/00-namespaces/namespaces.yaml
kubectl get ns nextcloud monitoring traefik metallb-system
```

All four should show status `Active`.

---

### Checkpoint 1 — namespaces

- [ ] All 4 namespaces exist and are `Active`

---

## Step 3 — Install MetalLB

A `LoadBalancer`-type Service on a cloud cluster gets an IP automatically from the cloud
provider. On a bare-metal or local cluster, nothing does that — the Service stays
`<pending>` forever. MetalLB fills that gap.

**Install MetalLB via Helm** into the `metallb-system` namespace.

**Hints**:
- MetalLB publishes an official Helm chart. The install page at https://metallb.io/installation/
  has the Helm repo URL and chart name.
- Pass `--namespace metallb-system` (the namespace already exists — no need for
  `--create-namespace`)
- After `helm install`, **wait** until all MetalLB pods are `Running` before the next step.
  MetalLB installs a validating webhook; if the webhook pod is not ready, applying the
  `IPAddressPool` CRD will fail with a TLS handshake error.

**Verify**:

```bash
kubectl get pods -n metallb-system
```

Expected: one `controller` Deployment pod + one `speaker` DaemonSet pod per node
(3 speakers on a 3-node cluster), all `Running`.

---

## Step 4 — Configure MetalLB L2 address pool

MetalLB needs to know which IP range it controls. In L2 mode, those IPs must live in
the same subnet as the cluster nodes — in kind that is the Docker bridge network.

Two resources to create:

1. `IPAddressPool` — the range MetalLB may allocate
2. `L2Advertisement` — instructs MetalLB to respond to ARP requests for those IPs

**Finding the right IP range**:

```bash
docker network inspect kind
```

Look at `IPAM.Config[0].Subnet` (something like `172.18.0.0/16`). Choose a small block
at the high end of that subnet that no container currently occupies — a `/28` gives 14
usable IPs, which is more than enough.

> If multiple students share the same physical network, each group must use a different
> pool range. Overlapping pools cause MetalLB speakers to fight over the same ARP entries.

**Hints**:
- `apiVersion: metallb.io/v1beta1` for both resources
- `IPAddressPool` spec: field `addresses` is a list — accepts CIDR (`x.x.x.x/28`) or
  range (`x.x.x.200-x.x.x.214`)
- `L2Advertisement` spec: field `ipAddressPools` lists the pool names to advertise
- Both resources go in `metallb-system`

**Verify**:

```bash
kubectl get ipaddresspool,l2advertisement -n metallb-system
```

---

### Checkpoint 2 — MetalLB

- [ ] MetalLB controller and 3 speakers are `Running`
- [ ] `IPAddressPool` exists with a CIDR inside your Docker subnet
- [ ] `L2Advertisement` exists and references the pool

---

## Step 5 — Install Traefik

Traefik is the Ingress controller. It watches `Ingress` resources and routes external
HTTP/HTTPS traffic to the appropriate in-cluster Services.

> **Why Traefik and not ingress-nginx?**  
> ingress-nginx was officially retired on March 24, 2026 by SIG-Security and SIG-Network
> — no further releases, bug fixes, or security patches. Traefik is actively maintained,
> supports both the classic Ingress API and the newer Gateway API, and is the recommended
> replacement.

**Install Traefik via Helm** into the `traefik` namespace.

**Key values to configure** (pass with `--set` or a custom values file):

| What to configure | Why |
|-------------------|-----|
| `deployment.kind: DaemonSet` | Runs on every matching node, binds host ports |
| `nodeSelector.ingress-ready: "true"` | Pins Traefik to the control-plane (the node with extraPortMappings) |
| `service.type: LoadBalancer` | MetalLB will assign an external IP |
| `ports.web.hostPort: 80` | Binds port 80 on the host — needed for WSL2 → Windows browser access |
| `ports.websecure.hostPort: 443` | Same for HTTPS |

**Hints**:
- Helm repo: `https://traefik.github.io/charts`, chart: `traefik`
- Explore available values first: `helm show values traefik/traefik | grep -A3 'deployment\|nodeSelector\|hostPort\|service.type'`
- `helm upgrade --install` is idempotent — use it in preference to `helm install`

**Verify**:

```bash
kubectl get pods -n traefik
kubectl get svc -n traefik
```

The Service `EXTERNAL-IP` must not be `<pending>`. If it stays pending more than 30s,
MetalLB is not ready or the pool does not cover any available IP.

Smoke test — a 404 is correct here (Traefik is running, no routes yet):

```bash
curl http://<TRAEFIK-EXTERNAL-IP>
# Expected: 404 page not found
```

---

### Checkpoint 3 — Traefik

- [ ] Traefik pod(s) `Running`
- [ ] Traefik Service has an `EXTERNAL-IP`
- [ ] `curl http://<IP>` returns a 404 from Traefik (not `connection refused`)

---

## Step 6 — Understand the StorageClass

kind pre-installs `local-path-provisioner` as the default StorageClass. No action is
needed — but you must understand it before you create PersistentVolumeClaims on Day 2.

```bash
kubectl get storageclass
kubectl get pods -n local-path-storage
kubectl get configmap -n local-path-storage local-path-config -o yaml
```

**Questions to answer now** (they will come up during restitution):

1. Where on the node host does local-path store data? Check the ConfigMap.
2. What happens to PVC data if the pod is rescheduled to a different node?
3. Is this StorageClass appropriate for a production PostgreSQL primary?
4. What annotation marks a StorageClass as the cluster default?

---

## Step 7 — Deploy a test application via Ingress

Validate the full traffic chain before Day 2. Create three resources from scratch
(no skeleton) in the `default` namespace:

1. A `Deployment` — one replica of `nginx:alpine`
2. A `ClusterIP` `Service` — port 80, targeting your Deployment
3. An `Ingress` — routes `test.local` to that Service

**Hints**:

- **ingressClassName**: must match what Traefik registered.
  Check: `kubectl get ingressclass`

- **Hosts file** — point `test.local` to the Traefik IP (or `127.0.0.1` if using host ports):
  - Linux/macOS: `/etc/hosts`
  - WSL2: edit **both** `/etc/hosts` inside WSL2 *and*
    `C:\Windows\System32\drivers\etc\hosts` on Windows (requires Administrator PowerShell)
    for browser access from Windows

- **Iterating without touching the hosts file**:
  ```bash
  curl -H "Host: test.local" http://<traefik-ip>
  ```

- **Debugging**: `kubectl describe ingress <name>` shows whether Traefik picked up the rule.
  `kubectl logs -n traefik <pod>` shows routed requests.

**Verify**:

```bash
curl http://test.local
# Expected: nginx welcome page HTML
```

---

### Final Checkpoint — Day 1 Validation

```bash
bash scripts/validate-day1.sh
```

All checks must pass before starting Day 2. Run it as many times as needed.

**Manual checklist**:
- [ ] 3 nodes `Ready`
- [ ] 4 namespaces exist, all `Active`
- [ ] MetalLB pods `Running`, `IPAddressPool` and `L2Advertisement` present
- [ ] Traefik pod `Running`, Service has `EXTERNAL-IP`
- [ ] `curl http://test.local` → HTTP 200

---

## Common pitfalls

**MetalLB webhook error on IPAddressPool apply**  
The validating webhook pod must be fully `Running` before you apply any MetalLB CRDs.
If you get a TLS or connection error, wait a few seconds and retry — do not skip the
webhook with `--validate=false`.

**Traefik Service stays `<pending>` for EXTERNAL-IP**  
MetalLB cannot assign an IP until the pool is configured. Installation order matters:
MetalLB pods running → IPAddressPool + L2Advertisement applied → Traefik installed
(or its Service will reconcile and pick up an IP once the pool appears).

**`port-forward` works, Ingress does not**  
`port-forward` tunnels directly to a pod, completely bypassing Ingress. They are different
code paths. Ingress failures: wrong `ingressClassName`, wrong `host` field, missing
hosts file entry, or the Service name/port in the Ingress spec does not match the actual
Service.

**WSL2: browser cannot reach `172.18.x.x`**  
MetalLB assigns IPs on the Docker bridge network — only accessible from inside WSL2.
Fix: use `127.0.0.1` in the *Windows* hosts file and ensure Traefik is binding host ports
80/443 (the `hostPort` DaemonSet configuration). Verify with:
`docker exec <control-plane-container> ss -tlnp | grep -E ':80|:443'`

**CRLF on scripts (Windows clone)**  
`bash: /r: No such file or directory` → your shell scripts have Windows line endings.
Fix one file: `sed -i 's/\r//' cluster/setup.sh`
Fix everything: `git checkout -- .` after verifying `.gitattributes` is enforcing LF.

**Traefik 404 vs connection refused**  
`404 page not found` from Traefik = Traefik is running, no matching route. Correct starting
state.  
`Connection refused` = Traefik is not listening. Check pods, check hostPort config.

---

## Bonus — stretch goals

- **Traefik dashboard**: Enable the Traefik API dashboard in Helm values and expose it via
  Ingress at `traefik.local`. What security risk does this introduce? What Traefik
  middleware would mitigate it?

- **Manual TLS**: Before cert-manager on Day 3, create a self-signed certificate with
  `openssl`, store it as a Kubernetes `Secret` (type `kubernetes.io/tls`), and configure
  your test Ingress to terminate TLS. Understand the `tls.crt` / `tls.key` Secret format.

- **Resource limits**: Add `resources.requests` and `resources.limits` to the Traefik
  DaemonSet via Helm values. Set the memory limit to something low (e.g., 10Mi) and
  observe what happens.

- **Multi-node awareness**: Scale the test Deployment to 3 replicas. Use
  `kubectl get pods -o wide` to see which nodes they land on. Why does Traefik route to
  all three even though it runs only on the control-plane?
