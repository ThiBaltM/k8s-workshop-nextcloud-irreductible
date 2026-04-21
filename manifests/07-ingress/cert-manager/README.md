# cert-manager — Self-signed TLS

cert-manager automates TLS certificate management in Kubernetes. It watches annotated
`Ingress` resources, requests certificates from a configured issuer, stores them as
`kubernetes.io/tls` Secrets, and renews them before expiry.

This guide uses a self-signed issuer — certificates are not trusted by browsers by
default (you will see a "Your connection is not private" warning). That is expected
for a local workshop. In production you would use Let's Encrypt or an internal CA.

---

## Install cert-manager

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update

helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true
```

> `--set crds.enabled=true` installs the cert-manager CRDs as part of the Helm release.
> Without it, `Issuer`, `Certificate`, and `CertificateRequest` resources are unknown
> to the API server and every `kubectl apply` returns `no kind is registered`.

**Wait until all pods are Running before creating any Issuer resources:**

```bash
kubectl rollout status deployment -n cert-manager cert-manager-webhook
kubectl get pods -n cert-manager
```

Expected: `cert-manager`, `cert-manager-cainjector`, `cert-manager-webhook` all `Running`.

---

## Create a self-signed ClusterIssuer

A `ClusterIssuer` is cluster-scoped — it can issue certificates in any namespace.
Create the following file and apply it:

```yaml
# selfsigned-issuer.yaml  (create in this directory)
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  # TODO: choose a name. You will reference it in Ingress annotations.
  name: # TODO (e.g., selfsigned)
spec:
  selfSigned: {}   # no external CA — cert-manager signs certificates itself
```

```bash
kubectl apply -f selfsigned-issuer.yaml
```

**Verify**:

```bash
kubectl get clusterissuer
kubectl describe clusterissuer <name>
```

The `Status.Conditions` must show `Ready: True` before you annotate any Ingress.

---

## Enable TLS on an Ingress

Add two things to any `Ingress` resource:

**1. Annotation** — tells cert-manager which issuer to use:
```yaml
annotations:
  cert-manager.io/cluster-issuer: # TODO: name of your ClusterIssuer
```

**2. TLS spec** — tells cert-manager the hostname and where to store the certificate:
```yaml
spec:
  tls:
    - hosts:
        - # TODO: hostname (e.g., nextcloud.local)
      secretName: # TODO: name cert-manager will use for the TLS Secret
                  # (e.g., nextcloud-tls) — it does not need to exist yet
  rules:
    - host: # TODO: same hostname as above
      # ... rest of your rules
```

cert-manager sees the annotation and creates a `Certificate` resource automatically,
then fulfills it and stores the result in the named Secret.

---

## Verify certificate issuance

After applying the annotated Ingress:

```bash
# cert-manager creates a Certificate resource automatically
kubectl get certificate -n <namespace>

# The Certificate transitions to Ready: True when the Secret is created
kubectl describe certificate <name> -n <namespace>

# The TLS Secret appears once the certificate is issued
kubectl get secret <tls-secret-name> -n <namespace>
```

Expected: `Certificate` status `Ready: True` within 30 seconds.

---

## Test TLS

```bash
# -k skips certificate verification (expected for self-signed)
curl -kv https://nextcloud.local 2>&1 | grep -E 'subject|issuer|SSL'
```

In your browser: open `https://nextcloud.local`, click through the warning, and verify
the padlock icon shows a certificate (even if it is flagged as untrusted).

---

## Common mistakes

**ClusterIssuer shows `Ready: False`**  
Usually means cert-manager webhook was not fully ready when you applied it. Delete the
`ClusterIssuer` and re-apply after verifying all three cert-manager pods are `Running`.

**Certificate stays `Issuing` or `False`**  
Check `kubectl describe certificate <name> -n <ns>`. Common causes:
- Annotation uses `cert-manager.io/issuer` (namespace-scoped) instead of
  `cert-manager.io/cluster-issuer` (cluster-scoped) — they are different annotations
- The issuer name in the annotation does not exactly match the `ClusterIssuer` name
- The Ingress was applied before the `ClusterIssuer` was `Ready` — delete and re-apply the Ingress

**Browser still shows HTTP after adding TLS**  
Nextcloud's `OVERWRITEPROTOCOL` in the ConfigMap is still `http`. Update it to `https`,
apply the ConfigMap change, then restart the Nextcloud pod. Without this, Nextcloud builds
`http://` redirect URLs even when served over HTTPS, causing redirect loops.
