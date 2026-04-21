# 01 — MetalLB

MetalLB gives your kind cluster the ability to assign real IP addresses to `LoadBalancer`
Services. Without it, any Service of type `LoadBalancer` stays in `<pending>` forever —
because there is no cloud provider to fulfill the request.

---

## What you need before installing

MetalLB L2 mode allocates IPs from the same subnet as your cluster nodes.
In kind, nodes are Docker containers — their network is the Docker bridge.

**Find the subnet**:

```bash
docker network inspect kind
```

Look at `IPAM.Config[0].Subnet` (typically `172.18.0.0/16` or similar).

Pick a small IP range at the **high end** of that subnet that no existing container uses.
A `/28` block gives 14 usable IPs — more than enough.

> If multiple students share the same physical network, every group must use a **different**
> pool range. Two MetalLB instances claiming the same IPs will fight over ARP responses.

---

## Install MetalLB

```bash
helm repo add metallb https://metallb.io/charts
helm repo update

helm install metallb metallb/metallb \
  --namespace metallb-system \
  --wait
```

> **Important**: `--wait` blocks until all pods are `Running`. Do not skip it.
> MetalLB installs a validating webhook. Applying the `IPAddressPool` CRD before
> the webhook pod is ready returns a TLS connection error.

**Verify**:

```bash
kubectl get pods -n metallb-system
```

Expected: one `controller` pod + one `speaker` pod per node (3 total speakers),
all `Running`.

---

## Configure the address pool

Once all pods are Running, create two resources:

```yaml
# ip-address-pool.yaml  (create this file, do not commit it to the skeleton repo)
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: workshop-pool
  namespace: metallb-system
spec:
  addresses:
    - <YOUR_IP_RANGE>   # TODO: e.g., 172.18.255.200/28 — from docker network inspect kind
                        # Every group on the same network MUST use a different range.
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: workshop-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - workshop-pool     # must match the IPAddressPool name above
```

```bash
kubectl apply -f ip-address-pool.yaml
```

**Verify**:

```bash
kubectl get ipaddresspool,l2advertisement -n metallb-system
```

---

## Test it

After Traefik is installed (next step), its Service of type `LoadBalancer` will
get an IP from this pool. If you see `<pending>` in the `EXTERNAL-IP` column,
come back here — the pool is misconfigured or MetalLB pods are not fully ready.

---

## Common mistake

Applying `IPAddressPool` before MetalLB's webhook is ready causes:
```
Error from server: failed calling webhook "ipaddresspoolvalidationwebhook.metallb.io": ...
```
Wait until `kubectl get pods -n metallb-system` shows **all** pods `Running`, then retry.
