# 03 — Storage

kind ships with `local-path-provisioner` pre-installed as the default StorageClass.
**No installation is required.** This page explains what it does and what its limitations
are — you need this understanding before creating PVCs on Day 2.

---

## Verify it is there

```bash
kubectl get storageclass
```

Expected output:

```
NAME                 PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      AGE
standard (default)   rancher.io/local-path   Delete          WaitForFirstConsumer   ...
```

Key details:
- **Provisioner**: `rancher.io/local-path` — data is stored on the node's local filesystem
- **ReclaimPolicy**: `Delete` — the data directory is deleted when the PVC is released
- **VolumeBindingMode**: `WaitForFirstConsumer` — the PVC is not bound until a pod
  actually mounts it. `kubectl get pvc` shows `Pending` until a pod is created. This is normal.
- **Default**: the `(default)` annotation means any PVC that omits `storageClassName` uses this

---

## Where does the data live?

```bash
kubectl get configmap -n local-path-storage local-path-config -o yaml
```

Look at the `config.json` key. You will see a `paths` array pointing to a directory
on the node host (typically `/var/local-path-provisioner`).

When a PVC is bound, local-path creates a subdirectory under that path on the node
where the pod is scheduled. The directory is a `hostPath` volume under the hood.

---

## What you must understand before Day 2

**Question 1 — Node affinity**  
local-path creates storage on a specific node. What happens if the Nextcloud pod
is rescheduled to a different node (e.g., after a node failure or pod eviction)?

**Question 2 — Production suitability**  
Is `local-path` appropriate for a production PostgreSQL primary? What storage solution
would you use instead, and why?

**Question 3 — ReclaimPolicy consequences**  
The policy is `Delete`. What does that mean for your data if you accidentally delete
a PVC? How would you change this for a production workload?

**Question 4 — ReadWriteOnce vs ReadWriteMany**  
`local-path` only supports `ReadWriteOnce`. What does that imply for running
multiple replicas of a Deployment that mounts the same PVC?

---

## No action required

You do not need to install or configure anything for storage on Day 1.
On Day 2, when you create PVCs, you will use this StorageClass (explicitly or as default).

Come back to these questions before the restitution — they will be asked.
