# 02 — Traefik

Traefik is the Ingress controller. It watches Kubernetes `Ingress` resources and routes
external HTTP/HTTPS traffic to the correct in-cluster Services.

> **Why Traefik?** ingress-nginx was officially retired on March 24, 2026 (SIG-Security /
> SIG-Network — no further releases or security patches). Traefik is the recommended
> replacement: actively maintained, supports both the Ingress API and the Gateway API.

---

## Install Traefik

```bash
helm repo add traefik https://traefik.github.io/charts
helm repo update
```

Traefik requires specific configuration for this workshop. Use a values file:

```bash
helm upgrade --install traefik traefik/traefik \
  --namespace traefik \
  --values traefik-values.yaml   # create this file — see below
```

---

## Values to configure

Create `traefik-values.yaml` (in this directory or your working directory).
Fill in the `# TODO` fields:

```yaml
# traefik-values.yaml

deployment:
  # Run as a DaemonSet so Traefik runs on every matching node
  # and can bind host ports directly.
  kind: DaemonSet

# Pin Traefik to the node labeled ingress-ready=true (the control-plane).
# kind's extraPortMappings bind host ports 80/443 to that node's container.
nodeSelector:
  ingress-ready: "true"

# The control-plane node has a NoSchedule taint by default in kind.
# Without this toleration, the DaemonSet pod is never scheduled there —
# even if the nodeSelector matches.
tolerations:
  - key: node-role.kubernetes.io/control-plane
    operator: Exists
    effect: NoSchedule

service:
  # MetalLB assigns an external IP to this Service.
  type: LoadBalancer

ports:
  web:
    # Bind port 80 on the host — required for WSL2 → Windows browser access.
    # kind maps this host port to the control-plane container via extraPortMappings.
    hostPort: <PORT_FOR_HTTP>    # TODO: which port for HTTP?
  websecure:
    hostPort: <PORT_FOR_HTTPS>   # TODO: which port for HTTPS?

# Optional: enable Traefik's dashboard (useful for debugging)
# api:
#   dashboard: true
#   insecure: true   # TODO: is this safe to expose? What would you add to protect it?
```

---

## Verify

```bash
kubectl get pods -n traefik
kubectl get svc -n traefik
```

The Service must show an `EXTERNAL-IP` (not `<pending>`). If it stays pending,
MetalLB is not configured — go back to `01-metallb/`.

Smoke test — a 404 from Traefik means it is running with no routes yet (correct at this stage):

```bash
curl http://<TRAEFIK-EXTERNAL-IP>
# Expected: 404 page not found  ← Traefik is running, no Ingress rules yet
```

---

## Check the IngressClass name

```bash
kubectl get ingressclass
```

The `NAME` column is what you put in `spec.ingressClassName` in every `Ingress` resource.
Note it — you will need it in `06-nextcloud/ingress.yaml.skeleton` and
`08-monitoring/values.yaml.skeleton`.

---

## Common mistakes

**DaemonSet pod stays Pending despite correct nodeSelector**  
The control-plane node has a `node-role.kubernetes.io/control-plane:NoSchedule` taint.
The DaemonSet must tolerate it — add the `tolerations` block above or the pod will never
be scheduled. Check with `kubectl describe pod -n traefik <pod>` and look for the
`Tolerations` and `Events` sections.

**Service EXTERNAL-IP stays `<pending>`**  
MetalLB must have a configured `IPAddressPool` **before** Traefik creates its Service.
If you installed Traefik first, the Service will pick up an IP once the pool is applied —
no need to reinstall Traefik.

**`curl localhost` works, `curl http://test.local` does not**  
`localhost` hits the DaemonSet via `hostPort`. `http://test.local` goes through Ingress
routing. If Ingress fails: wrong `ingressClassName`, wrong `host` in the Ingress spec, or
the hosts file entry is missing / pointing to the wrong IP.
