# Day 2 — Deploying Nextcloud

**Duration**: ~4h40  
**Prerequisites**: Day 1 complete — `bash scripts/validate-day1.sh` passes with no failures.  
**Goal**: A fully functional Nextcloud instance with a PostgreSQL database, Redis cache,
persistent storage, and an Ingress route — reachable in your browser.

---

## Objectives

By the end of Day 2 you will have:

- [ ] CloudNativePG operator installed, PostgreSQL cluster running (1 primary + 1 replica)
- [ ] Redis deployed as a session/cache store
- [ ] PersistentVolumeClaims bound for both Nextcloud data and PostgreSQL storage
- [ ] Nextcloud deployed as a multi-container pod (PHP-FPM + nginx sidecar)
- [ ] Nextcloud login page accessible at `https://nextcloud.local` (or `http://` for now)
- [ ] Admin account reachable and functional

---

## Architecture — end of Day 2

```
  Browser
    │ http://nextcloud.local
    ▼
  ┌────────────────────────────────────────────────────────────────────┐
  │  kind cluster                                                      │
  │                                                                    │
  │  MetalLB ── Traefik (from Day 1) ──────────────────────────────┐  │
  │                                   Ingress: nextcloud.local     │  │
  │  ┌─────────────────────────────────────────────────────────────┘  │
  │  │ namespace: nextcloud                                           │
  │  │                                                                │
  │  │  ┌────────────────────────────────────────────┐               │
  │  │  │ Nextcloud Pod                              │               │
  │  │  │  init: fix-permissions (chown www-data)    │               │
  │  │  │  ┌──────────────┐  ┌──────────────────┐   │               │
  │  │  │  │  nginx       │  │  nextcloud:fpm   │   │               │
  │  │  │  │  :80 → :9000 │  │  PHP-FPM  :9000  │   │               │
  │  │  │  └──────┬───────┘  └────────┬─────────┘   │               │
  │  │  │         └──── shared PVC ───┘              │               │
  │  │  │              /var/www/html                  │               │
  │  │  └────────────────────────────────────────────┘               │
  │  │                                                                │
  │  │  ┌──────────────────────┐  ┌──────────────┐                  │
  │  │  │ CloudNativePG        │  │    Redis      │                  │
  │  │  │  primary (RW)        │  │   :6379       │                  │
  │  │  │  replica (RO)        │  └──────────────┘                  │
  │  │  │  auto-created Secret │                                      │
  │  │  └──────────────────────┘                                      │
  │  │                                                                │
  │  │  PVCs (local-path): nextcloud-data, postgresql-storage         │
  │  └────────────────────────────────────────────────────────────────┘
  └────────────────────────────────────────────────────────────────────┘
```

---

## Step 1 — Install the CloudNativePG operator

CloudNativePG (CNPG) is a Kubernetes operator that manages PostgreSQL clusters as
first-class Kubernetes resources. You describe the cluster you want in a `Cluster` CRD
and the operator handles provisioning, replication, failover, and backups.

**Install the CNPG operator**. Two methods are available — choose one:
- `kubectl apply -f` on the official release manifest (find it on the GitHub releases page)
- Helm chart (check the CloudNativePG docs for the repo URL)

**Hints**:
- CNPG docs: https://cloudnative-pg.io/documentation/ — installation page has both methods
- The operator runs in its own namespace (`cnpg-system`)
- Wait until the operator pod is `Running` before applying the `Cluster` CRD in Step 2;
  the CRD registration is not immediate

**Verify**:

```bash
kubectl get pods -n cnpg-system
kubectl get crd | grep postgresql
```

Expected: operator pod `Running`, `clusters.postgresql.cnpg.io` CRD present.

---

## Step 2 — Deploy the PostgreSQL cluster

**File**: `manifests/04-postgresql/cluster.yaml.skeleton`

Create a CNPG `Cluster` resource in the `nextcloud` namespace. It needs:
- 2 instances (1 primary + 1 replica)
- A `bootstrap.initdb` section that creates your database and a user
- A storage section with a PVC size (2Gi is sufficient for the workshop)
- The default StorageClass (you can omit `storageClass` to use the cluster default)

**Hints**:
- `apiVersion: postgresql.cnpg.io/v1`, `kind: Cluster`
- The `bootstrap.initdb` block has fields for `database` and `owner` — choose names
  you will reference in the Nextcloud config later
- CNPG manages the PostgreSQL data PVC automatically — do not create a separate PVC for it
- The operator needs a few minutes to pull the PostgreSQL image, initialize the primary,
  and start replication to the replica

**Verify**:

```bash
kubectl get cluster -n nextcloud
kubectl get pods -n nextcloud
```

Expected: cluster in `Healthy` phase, two pods — one with `-1` suffix (primary),
one with `-2` (replica), both `Running`.

```bash
kubectl describe cluster <cluster-name> -n nextcloud
```

Look at the `Status.CurrentPrimary` and `Status.Instances` fields.

---

## Step 3 — Understand CNPG-managed secrets

CNPG automatically creates Kubernetes Secrets containing connection credentials.
You do not create these — but you must understand their structure to reference them in
the Nextcloud Deployment.

**Inspect the secrets**:

```bash
kubectl get secrets -n nextcloud
```

You will see a secret named `<cluster-name>-app` (among others). Decode it:

```bash
kubectl get secret <cluster-name>-app -n nextcloud -o jsonpath='{.data}' 
```

The values are base64-encoded. Decode each key to understand what it contains.

**Key observation**: The key names in the CNPG secret (`username`, `password`, `host`,
`dbname`, `uri`) do **not** map one-to-one to the environment variable names that
Nextcloud expects (`POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_HOST`, `POSTGRES_DB`).
You must bridge that gap explicitly in your Deployment spec using `secretKeyRef`.

Make a note of:
- The exact secret name
- Which key holds the username
- Which key holds the password
- Which key holds the hostname (used by the application to connect to PostgreSQL)
- Which key holds the database name

---

## Step 4 — Deploy Redis

**File**: `manifests/05-redis/redis.yaml.skeleton`

Deploy Redis as a simple `Deployment` + `ClusterIP` `Service` in the `nextcloud` namespace.
Nextcloud uses Redis for session locking and caching — without it, concurrent requests can
corrupt the database.

**What the Deployment needs**:
- Image: `redis:7-alpine` (lightweight, sufficient for this use case)
- Port 6379
- A liveness probe and a readiness probe (hint: Redis has a `PING` command)
- Resource `requests` and `limits` — Redis defaults to using unlimited memory; always
  set a `memory` limit

**Hints**:
- Redis does not need persistent storage for the workshop (cache data is ephemeral)
- The `redis-cli ping` command returns `PONG` — usable as a probe exec command
- Set `maxmemory` and `maxmemory-policy` via the Redis command args, or pass a config file
  via a ConfigMap — this prevents OOM kills on resource-constrained machines

**Verify**:

```bash
kubectl get pods -n nextcloud -l app=redis
kubectl exec -n nextcloud <redis-pod> -- redis-cli ping
# Expected: PONG
```

---

### Checkpoint 1 — data layer

- [ ] CNPG cluster in `Healthy` phase, 2 pods `Running`
- [ ] Redis pod `Running`, `redis-cli ping` returns `PONG`
- [ ] PVC for PostgreSQL is `Bound` (`kubectl get pvc -n nextcloud`)

---

## Step 5 — Create PersistentVolumeClaims for Nextcloud

**File**: `manifests/06-nextcloud/pvc.yaml.skeleton`

Nextcloud stores all user files and PHP application data under `/var/www/html`.
This directory must be on a PVC so data survives pod restarts.

Create one PVC in the `nextcloud` namespace:
- Name: something descriptive (`nextcloud-data` is conventional)
- StorageClass: the default (`local-path`)
- Access mode: `ReadWriteOnce` (only one pod writes at a time)
- Size: 5Gi (enough for the workshop demo)

**Hints**:
- `apiVersion: v1`, `kind: PersistentVolumeClaim`
- Access mode `ReadWriteOnce` is correct here — the Deployment runs 1 replica
- The PVC won't bind until a pod actually mounts it (local-path provisions on first mount)

**Verify**:

```bash
kubectl get pvc -n nextcloud
```

Status will be `Pending` until the Deployment mounts it — that is normal.

---

## Step 6 — Create the Secrets

**File**: `manifests/06-nextcloud/secrets.yaml.skeleton`

Store the Nextcloud admin credentials. **Do not hard-code them in the Deployment.**

Create a `Secret` (type `Opaque`) in `nextcloud` containing:
- The admin username
- The admin password

> The PostgreSQL credentials come from the CNPG-managed secret (Step 3) — you do not
> duplicate them here. You reference both secrets in the Deployment.

**Hints**:
- Values in a `Secret` must be base64-encoded: `echo -n "mypassword" | base64`
- Or use `stringData` instead of `data` — Kubernetes encodes it automatically
- These values will be injected as environment variables via `secretKeyRef` in the Deployment
- Never commit this file to git with real credentials. The `.gitignore` excludes
  `secrets.yaml` — verify before pushing.

---

## Step 7 — Create the ConfigMap

**File**: `manifests/06-nextcloud/configmap.yaml.skeleton`

Nextcloud reads configuration from environment variables on first run. Create a ConfigMap
in `nextcloud` containing the non-sensitive settings:

| Environment variable | Purpose | Value |
|---------------------|---------|-------|
| `NEXTCLOUD_TRUSTED_DOMAINS` | Domains Nextcloud allows access from | `nextcloud.local` |
| `NEXTCLOUD_UPDATE` | Skip upgrade checks on startup | `1` |
| `OVERWRITEPROTOCOL` | Protocol reported to Nextcloud for URL generation | `http` (change to `https` on Day 3) |
| `OVERWRITECLIURL` | Base URL for `occ` command-line tool | `http://nextcloud.local` |
| `REDIS_HOST` | Redis hostname | ClusterIP Service name |
| `REDIS_PORT` | Redis port | `6379` |
| `PHP_MEMORY_LIMIT` | PHP memory limit | `512M` |
| `PHP_UPLOAD_LIMIT` | Upload size limit | `512M` |

> Do not put `POSTGRES_*` variables here — those come from the CNPG secret.

**Hints**:
- Service DNS inside a namespace: `<service-name>.<namespace>.svc.cluster.local`
  or simply `<service-name>` if both pods are in the same namespace
- `NEXTCLOUD_TRUSTED_DOMAINS` accepts space-separated values for multiple domains

---

## Step 8 — Deploy Nextcloud

**File**: `manifests/06-nextcloud/deployment.yaml.skeleton`

This is the most complex step. The Nextcloud Deployment runs **three containers** in one pod:

```
Pod: nextcloud
├── initContainer: fix-permissions
│     Image: busybox
│     Sets correct ownership on the data volume before FPM starts
│
├── container: nextcloud (PHP-FPM)
│     Image: nextcloud:fpm
│     Reads all POSTGRES_* and REDIS_* env vars
│     Serves FastCGI on localhost:9000
│
└── container: nginx
      Custom nginx image or nginx:alpine + ConfigMap-mounted nginx.conf
      Proxies HTTP :80 → PHP-FPM :9000 via FastCGI
      Serves static files directly from the shared volume
```

Both containers mount the **same PVC** at `/var/www/html`. The init container runs first
and sets ownership before either main container starts.

---

### 8a — Init container

The PHP-FPM process runs as `www-data` (UID 33). The PVC starts with root ownership.
Without the init container, FPM cannot write to `/var/www/html` and Nextcloud fails on
first run.

**Hints**:
- Image: `busybox` or `alpine`
- Command: `chown -R 33:33 /var/www/html` (or use the symbolic user name if available)
- This container mounts the same PVC as the main containers
- Init containers run to completion before any main container starts — the pod will be
  in `Init:0/1` state while it runs

---

### 8b — PHP-FPM container

**Hints**:
- Image: `nextcloud:fpm` (not `nextcloud:latest` — that includes Apache, not nginx-friendly)
- Port 9000 is FastCGI — do not expose it as a Service port, only used internally within the pod
- Inject environment variables from the ConfigMap (`envFrom.configMapRef`) and both Secrets
  (`envFrom.secretRef` and `env[].valueFrom.secretKeyRef`)
- The CNPG secret keys do not match Nextcloud's expected env var names — map them explicitly:
  - `POSTGRES_HOST` ← CNPG secret key `host`
  - `POSTGRES_DB` ← CNPG secret key `dbname`
  - `POSTGRES_USER` ← CNPG secret key `username`
  - `POSTGRES_PASSWORD` ← CNPG secret key `password`
- Readiness and liveness probes: Nextcloud is slow to start (30–120s on first run).
  Use a `httpGet` probe on the nginx container instead (see 8c), or use an `exec` probe
  with a generous `initialDelaySeconds` (60+) and `failureThreshold` (10+)
- Mount the PVC at `/var/www/html`

---

### 8c — nginx sidecar container

nginx serves as the HTTP frontend. It handles static files directly and passes PHP
requests to PHP-FPM via FastCGI on `localhost:9000` (same pod = shared network namespace).

nginx needs a custom configuration mounted from a **separate ConfigMap**
(`nginx-config` is a reasonable name). Create this ConfigMap alongside the Deployment.

The nginx.conf must:
- Listen on port 80
- Set `root /var/www/html`
- Handle the Nextcloud URL structure (its router rewrites URLs to `index.php`)
- Pass `.php` files to `fastcgi_pass 127.0.0.1:9000`
- Set `SCRIPT_FILENAME` correctly for FastCGI
- Include `fastcgi_params`

**Hints**:
- Nextcloud's own documentation has an nginx configuration example for use with PHP-FPM.
  The official Nextcloud Docker repository also has a reference `nginx.conf`.
- The key FastCGI directives: `fastcgi_pass`, `fastcgi_index`, `fastcgi_param SCRIPT_FILENAME`,
  and `include fastcgi_params`
- Mount the nginx ConfigMap as a volume at `/etc/nginx/nginx.conf` (subPath) or
  `/etc/nginx/conf.d/default.conf`
- Mount the **same PVC** as PHP-FPM at `/var/www/html` — nginx must serve the same files
- Port 80 is what the Service and Ingress target — expose it on the nginx container, not FPM

---

### 8d — Volume summary

The pod needs these volumes:

| Volume name | Source | Mounted by | Mount path |
|-------------|--------|------------|------------|
| `nextcloud-data` | PVC | init, fpm, nginx | `/var/www/html` |
| `nginx-config` | ConfigMap | nginx | `/etc/nginx/nginx.conf` (subPath) |

---

## Step 9 — Create the Service

**File**: `manifests/06-nextcloud/service.yaml.skeleton`

Create a `ClusterIP` Service in `nextcloud` targeting the **nginx container** on port 80.

**Hints**:
- The Service selector must match the labels on the Nextcloud Pod (set in the Deployment's
  `spec.template.metadata.labels`)
- Only port 80 (nginx) is exposed — not port 9000 (FPM is internal to the pod)

**Verify**:

```bash
kubectl get svc -n nextcloud
kubectl get endpoints -n nextcloud
```

Endpoints should show the pod IP once the pod is Running.

---

## Step 10 — Create the Ingress

**File**: `manifests/07-ingress/ingress.yaml.skeleton`

Expose Nextcloud externally via Traefik with the hostname `nextcloud.local`.

**Hints**:
- `ingressClassName`: use the same class as your Day 1 test Ingress
- Traefik annotations for Nextcloud:
  - Body size: Nextcloud uploads files — the default 1MB limit will break uploads.
    Look for Traefik's middleware annotation for body size (`plugin` or `IngressRoute`
    annotations, or a `Middleware` CRD)
  - Proxy headers: `X-Forwarded-Proto`, `X-Forwarded-Host` — Nextcloud uses these to
    build correct redirect URLs. Without them, login redirects may fail.
- Add `nextcloud.local` to your hosts file pointing to the Traefik IP (same as Day 1)
- TLS comes on Day 3 — HTTP is fine for now

**Verify**:

```bash
kubectl get ingress -n nextcloud
curl -v http://nextcloud.local
# Expected: HTTP 302 redirect to /index.php/login, or the login page itself
```

---

### Checkpoint 2 — application running

```bash
kubectl get pods -n nextcloud
```

Expected:
- `nextcloud-*` pod: `2/2 Running` (nginx + fpm; init container already completed)
- `<cnpg-cluster>-1`: `1/1 Running` (primary)
- `<cnpg-cluster>-2`: `1/1 Running` (replica)
- `redis-*`: `1/1 Running`

```bash
kubectl get pvc -n nextcloud
# All PVCs: Bound
```

---

## Step 11 — Verify and explore Nextcloud

Open `http://nextcloud.local` in your browser. You should reach the login page.

Log in with the admin credentials you set in Step 6.

**Post-login checks**:
1. Upload a small file. Verify it appears in the Files app.
2. Restart the Nextcloud pod (`kubectl delete pod -n nextcloud <pod>`) and verify the
   file is still there after the pod comes back. This confirms PVC persistence.
3. Check the Nextcloud admin overview: **Settings → Administration → Overview**.
   Address any warnings about missing background jobs or Redis configuration.

**Useful `occ` commands** (run inside the FPM container, not nginx):

```bash
kubectl exec -n nextcloud <nextcloud-pod> -c nextcloud -- php occ status
kubectl exec -n nextcloud <nextcloud-pod> -c nextcloud -- php occ config:list system
```

---

### Final Checkpoint — Day 2 Validation

```bash
bash scripts/validate-day2.sh
```

**Manual checklist**:
- [ ] CNPG cluster: 1 primary + 1 replica, both `Running`
- [ ] Redis pod: `Running`
- [ ] Nextcloud pod: `2/2 Running`
- [ ] All PVCs: `Bound`
- [ ] `curl http://nextcloud.local` → HTTP 200 or 302
- [ ] Nextcloud login page accessible, admin login works

---

## Common pitfalls

**"Access through untrusted domain" error**  
Nextcloud blocks access from any domain not listed in `trusted_domains`. Check that
`NEXTCLOUD_TRUSTED_DOMAINS` in your ConfigMap includes exactly `nextcloud.local` (and
matches the `host` field in your hosts file and Ingress). After fixing the ConfigMap,
delete the pod to force a restart — ConfigMap changes are not picked up automatically by
running pods unless a rolling update is triggered.

**nginx sidecar returns 502 Bad Gateway**  
nginx cannot reach PHP-FPM on `localhost:9000`. Causes:
- Wrong `fastcgi_pass` directive (should be `127.0.0.1:9000`, not a hostname outside the pod)
- FPM container not started yet (check `kubectl get pod` — is it `2/2`?)
- FPM crashed — `kubectl logs <pod> -c nextcloud`

**nginx sidecar returns 403 Forbidden**  
nginx cannot read files from `/var/www/html`. Causes:
- The init container did not run or failed — check `kubectl describe pod` init container status
- The nginx `root` directive points to the wrong path
- The PVC is mounted at a different path in one of the containers

**CNPG secret keys don't match what Nextcloud expects**  
The CNPG secret has keys `username`, `password`, `host`, `dbname` — but Nextcloud expects
`POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_HOST`, `POSTGRES_DB`. You must map each
key explicitly with `env[].valueFrom.secretKeyRef`. Using `envFrom.secretRef` directly on
the CNPG secret injects wrong variable names and Nextcloud silently falls back to SQLite.

**Nextcloud pod stuck in `Init:0/1`**  
The init container is still running or failed. Check with:
`kubectl logs <pod> -c fix-permissions` (or whatever you named the init container).
Common cause: typo in the command, or the PVC failed to mount.

**Nextcloud is very slow to start (first run)**  
On first launch, Nextcloud runs database migrations, installs default apps, and generates
config — this takes 1–3 minutes. If your readiness probe is too aggressive it will kill
the container before it finishes. Use `initialDelaySeconds: 60` minimum and
`failureThreshold: 10`.

**File uploads fail or return 413**  
Traefik's default body size limit is 0 (unlimited), but some annotations or middleware
can override it. More likely: PHP's `upload_max_filesize` and `post_max_size` are too
low. Set `PHP_UPLOAD_LIMIT` in the ConfigMap (the Nextcloud FPM image respects this env var).

---

## Bonus — stretch goals

- **Horizontal scaling attempt**: Change the Deployment to `replicas: 2`. What happens
  with `local-path` storage and `ReadWriteOnce` access mode? What would you need to
  change to make multi-replica Nextcloud work?

- **occ maintenance**: Run `kubectl exec ... -- php occ maintenance:mode --on` to put
  Nextcloud in maintenance mode. What does the UI show? Turn it off. When is this
  command needed in production?

- **Database inspection**: Connect to the PostgreSQL primary directly using `kubectl exec`
  and `psql`. List tables, count rows in `oc_filecache`. Understand what CNPG created.

- **Failover test**: Delete the primary PostgreSQL pod. Watch CNPG promote the replica.
  How long does failover take? Does Nextcloud recover automatically?
