# Longhorn backups to OCI Object Storage

Selected Longhorn volumes are backed up daily to an OCI Object Storage bucket
through its S3-compatible API. Object Storage is part of the Always Free tier
(20 GB, 50k API requests/month), so this adds no cost.

Only volumes that hold data we can't rebuild from git are backed up:

| Namespace | PVC | Content |
|---|---|---|
| `actualbudget` | `actualbudget-data` | Actual Budget server and user files |
| `bagisto` | `bagisto-bagisto-storage` | Bagisto uploads (product images, media) |
| `bagisto` | `data-bagisto-bagisto-mysql-0` | Bagisto MySQL database |

Not backed up: Prometheus (metrics are disposable), Bagisto Redis (cache and
sessions only) and ntfy.

## How it is wired

```
Terraform (terraform/config/modules/longhorn-backup)
  ├─ bucket longhorn-backups
  ├─ IAM user + group LonghornBackup, allowed only on that bucket
  ├─ Customer Secret Key (S3 access/secret key pair) of that user
  └─ OCI Vault secret longhorn-backup-s3 (JSON):
       AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_ENDPOINTS, BACKUP_TARGET
          ↓ ExternalSecret (gitops/core/longhorn/secret.yaml, dataFrom.extract)
K8s Secret longhorn/longhorn-backup-s3
  ├─ credential secret of the Longhorn backup target
  └─ BACKUP_TARGET → HelmRelease valuesFrom → defaultBackupStore.backupTarget
          ↓
BackupTarget "default" = s3://longhorn-backups@eu-frankfurt-1/
          ↓
RecurringJob daily-s3-backup (gitops/core/longhorn/backup)
  cron 0 3 * * *, retain 2, group s3-backup
  → runs on every volume whose PVC carries the opt-in labels
```

The RecurringJob lives in its own Flux `Kustomization` (`longhorn-backup`),
which depends on `longhorn`, because its CRD is installed by the Longhorn
HelmRelease.

The `valuesFrom` on the Longhorn HelmRelease is `optional`, so a missing Vault
secret never blocks installing the storage layer. If the backup target URL
shows empty after a fresh install, force a reconcile once the Secret exists:

```sh
flux -n longhorn reconcile hr longhorn
```

## Opting a volume in

A volume is backed up when its PVC has these labels:

```yaml
recurring-job.longhorn.io/source: enabled            # Longhorn reads job labels from the PVC
recurring-job-group.longhorn.io/s3-backup: enabled   # the group of daily-s3-backup
```

The group is deliberately not `default`: Longhorn adds
`recurring-job-group.longhorn.io/default` to every volume without job labels,
so a job in the `default` group would back up every volume.

Where the labels come from:

| PVC | Set by |
|---|---|
| `actualbudget-data` | Flux `postRenderers` patch in [actualbudget/helm.yaml](../gitops/core/actualbudget/helm.yaml) (the community chart has no PVC labels value) |
| `bagisto-bagisto-storage` | `storage.labels` in [bagisto/helm.yaml](../gitops/core/bagisto/helm.yaml) ([bagisto-helm](https://github.com/baburciu/bagisto-helm) chart ≥ 0.2.0) |
| `data-bagisto-bagisto-mysql-0` | `mysqlStandalone.persistence.labels` in the same file |

The MySQL PVC is created from the StatefulSet's `volumeClaimTemplates`, which
are immutable. Changing them on an existing StatefulSet makes the Helm upgrade
fail, and the labels only reach newly created PVCs anyway. To change them on a
running cluster:

```sh
kubectl -n bagisto label pvc data-bagisto-bagisto-mysql-0 <labels>
kubectl -n bagisto delete sts bagisto-bagisto-mysql --cascade=orphan   # pod and PVC keep running
# push the values change; the Helm upgrade recreates the StatefulSet, which adopts the pod
```

## Manual backup

Longhorn UI → **Volumes** → click the volume → **Create Backup**. Leave
*Full Backup* unchecked: backups are incremental and the first one uploads
everything anyway. Several volumes can be selected in the list and backed up
at once. Manual backups count towards `retain`.

Progress is under **Backup and Restore → Backups**, or:

```sh
kubectl -n longhorn get backups.longhorn.io \
  -o custom-columns=VOLUME:.status.volumeName,STATE:.status.state,PROGRESS:.status.progress,CREATED:.status.backupCreatedAt
oci os object list --bucket-name longhorn-backups --prefix backupstore/volumes/ --all --fields name,size
```

## Restore

The same steps apply to a recreated cluster once Flux has installed Longhorn
and the backup target shows *Available*. Example for Actual Budget:

1. Stop Flux from fighting the restore, then stop the app and drop the empty PVC:
   ```sh
   flux -n actualbudget suspend hr actualbudget
   kubectl -n actualbudget scale deploy/actualbudget --replicas=0
   kubectl -n actualbudget delete pvc actualbudget-data
   ```
   For Bagisto, suspend `hr/bagisto` and scale both `deploy/bagisto` and
   `sts/bagisto-bagisto-mysql` to 0.
2. Longhorn UI → **Backup and Restore → Backups** → the volume → latest
   backup → **Restore**. Tick *Use Previous Name* and wait until the volume is
   *Detached*.
3. **Volumes** → the restored volume → **Create PV/PVC** with
   *Use Previous PVC*, so the PVC gets its original namespace and name.
4. Give the PVC back to Helm, so the next upgrade doesn't refuse to touch it:
   ```sh
   kubectl -n actualbudget label pvc actualbudget-data app.kubernetes.io/managed-by=Helm
   kubectl -n actualbudget annotate pvc actualbudget-data \
     meta.helm.sh/release-name=actualbudget meta.helm.sh/release-namespace=actualbudget
   ```
   Skip this for `data-bagisto-bagisto-mysql-0`: StatefulSet PVCs aren't Helm-owned.
5. Bring the app back:
   ```sh
   kubectl -n actualbudget scale deploy/actualbudget --replicas=1
   flux -n actualbudget resume hr actualbudget
   ```
   The backup labels are re-added by the next Helm upgrade. For the MySQL
   PVC, re-add them with `kubectl label`.

## MySQL consistency

The MySQL volume is backed up as a live block-device snapshot. That is
crash-consistent: the same state as after a power loss, which InnoDB recovers
from on startup. It is not a point-in-time logical dump. If that is ever
needed, add a nightly `mysqldump` CronJob next to the volume backup.

## Free-tier limits

- **20 GB of Object Storage.** It is shared with `terraform-states` and other
  buckets. The first three backups used about 48 MiB.
- **50k API requests per month.** This is why `defaultBackupStore.pollInterval`
  is 3600s rather than the default 300s.
