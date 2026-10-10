# ⎈ Oracle Cloud Kubernetes free tier setup

This repository leverages Oracle Cloud's [always free tier][oci-free-tier] to provision a kubernetes cluster.
In its current setup there are **no monthly costs** anymore, as I've now moved
the last part (DNS) from oci to cloudflare.

[oci-free-tier]: https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm

Oracle Kubernetes Engine (OKE) is free to use, and you only pay for worker
nodes _if_ you exceed the Always Free tier — which we don’t.
The free tier provides **4 oCPUs and 24GB of memory**, which are split between two
worker nodes (`VM.Standard.A1.Flex`), allowing for efficient resource
utilization. Each node has a 100GB boot volume, with around 60GB available for
in-cluster storage via Longhorn. For ingress, we use the `GatewayAPI` implementation
provided by envoy-gateway together with Oracle’s
Flexible Load Balancer (10Mbps; layer 7). For `teleport` we use the network LB (layer 4).
In this configuration both load balancers are free to use.

Getting an Always Free account can sometimes be tricky, but there are several
guides on Reddit that explain how to speed up the creation process.

The initial infra setup is inspired by this great tutorial: https://arnoldgalovics.com/free-kubernetes-oracle-cloud/

> [!WARNING]
> This project uses arm instances, no x86 architecture; due to limitations
> of the always free tier.
>
> *And please mind:*
> This setup is loosely documented and opinionated. It's working and in use
> by myself. It's public, to showcase how this setup can be recreated, but
> you need to know what you're doing and where to make modification for yourself.

This repo hosts my personal stuff and is a playground for my kubernetes tooling.

> [!TIP]
> In case you want to reproduce another `oke` setup, you might [find this guide](https://github.com/piontec/free-oci-kubernetes)
> also helpful.

## :wrench: Tooling

- [x] K8s control plane
- [x] Worker Nodes
- [x] Ingress with GatewayAPI
  * envoy-gateway on a layer 7 lb
  * teleport svc on a layer 4 lb
  * `httproutes` with oidc protection
- [x] Certmanager
  * with letsencrypt setup for cloudflare dns challenge
- [x] External DNS
  * with sync to the cloudflare dns management
  * CR to provide `A` records for my home-network
- [x] Dex as OIDC Provider
  * with github as idP
- [x] FluxCD for Gitops
  * deployed with the new fluxcd operator
  * github → flux webhook receiver for instant reconciliation
- [x] Teleport for k8s cluster access
- [x] Storage
   * with longhorn
   * daily backups of selected volumes to OCI Object Storage ([docs/backup.md](docs/backup.md))
- [x] Grafana with Dex Login
   * Dashboards for Flux
   * [ ] Switch to Grafana Operator
- [ ] Loki for log aggregation
- [x] Metrics Server for cpu/mem usage overview
- [ ] Kyverno and Image Signing
- [x] [S3 Proxy](https://github.com/oxyno-zeta/s3-proxy) for http access of buckets

# :keyboard: Setup
> [!Note]
> I've recently updated the tf-backend config,  to utilizes the oci native
> backend now. This requires terraform >= v1.12

This setup uses terraform to manage the oci **and** a bit of the kubernetes part.

## Tooling on the client side

* terraform
* oci-binary
* `oci setup config` successfully run

The terraform state is pushed to oracle object storage (free as well). For that
we have to create a bucket initially:
```
❯ oci os bucket create --name terraform-states --versioning Enabled --compartment-id xxx
```

With the bucket created we can configure the `~/.oci/config`:
```
[DEFAULT]
user=ocid1.user.xxx
fingerprint=ee:f4:xxx
tenancy=ocid1.tenancy.oc1.xxx
region=eu-frankfurt-1
key_file=/Users/xxxx.pem

[default]
aws_access_key_id = xxx <- this needs to be created via UI: User -> customer secret key
aws_secret_access_key = xxx <- this needs to be created via UI: User -> customer secret key

```
Refer to my [backend config](./terraform/infra/_terraform.tf) for the terraform s3 configuration.

## 🏗️ Terraform Layout
* The infrastructure (everything to an usable k8s-api endpoint) is managed by
terraform in [`infra`](terraform/infra/)
* The k8s-modules (OCI specific config for secrets etc.) are managed by terraform in [`config`](terraform/config/)
* The k8s apps/config is done with FluxCD; see below

These components are independent from each other, but obv. the [`infra`](terraform/infra/) should be created first.

For the config part, you need to add a private `*.tfvars` file:
```hcl
# terraform/infra/infra.auto.tfvars
compartment_id = "ocid1.tenancy.oc1..aa"
```
```hcl
# terraform/config/config.auto.tfvars
compartment_id = "ocid1.tenancy.oc1..aa"

github_app_id = "2748318"

github_app_installation_id = "106655669"

# from 'awk '{printf "%s%s", (NR>1?"\\n":""), $0} END {printf ""}' private-key.pem' (downloaded from GitHub App)
github_app_pem = "-----BEGIN RSA PRIVATE KEY-----\nM"
```

> [!TIP]
> During the initial provisioning the terraform run of `config` might fail,
> it's trying to create a `ClusterSecretStore` which only exist after the
> initial deployment of `external secrets` with flux. This is expected.
> Just rerun terraform after external secrets is successfully deployed.

## Kubernets Access - kubeconfig
After running terraform in the [infra](./terraform/infra) folder, a kubeconfig file
will be created as `terraform/.kube.config`.
This can be used to access the cluster.
For a more regulated access, see the Teleport section below.

The terraform resources in the [config](./terraform/config) folder will rely on the kubeconfig.

## FluxCD
Most resources and core components of the k8s cluster are provisioned with FluxCD.

* Flux pulls the repo and Terraform manages the GitHub push webhook (which
  triggers Flux reconciliation after each commit) with the GitHub App below.

### Flux Operator
Flux Operator and its `FluxInstace` CR is instantiated from [Terraform](terraform/config/modules/fluxcd/flux.tf).

I've setup a GitHub App following the [official guides](https://fluxcd.io/blog/2025/04/flux-operator-github-app-bootstrap/#github-app-docs), used
`https://login.delaleusystems.com/dex/callback` as Callback URL (see [dex](gitops/core/dex/helm.yaml) config) then added these permissions
```console
contents        - read, write
commit statuses - read, write
webhooks        - read, write

# needed for Dex GitHub connector - see https://github.com/dexidp/website/issues/163
```
and installed the App on this repo. <br/>
![GitHub App permissions](docs/github-app-permissions.png)

Also created a GitHub App Client Secret and manually added to OCI Vault (see below).

## Deployment

### OCI Vault

Vault secrets are:

| Vault Secret Name | Created by | Purpose |
|---|---|---|
| `github-flux-webhook-token` | Terraform ([webhook.tf](terraform/config/modules/fluxcd/webhook.tf))  | Flux webhook validation |
| `cloudflare-api-token` | Manual | Cloudflare API token for external-dns |
| `github-app-client-id` | Manual | GitHub App Client ID |
| `github-app-client-secret` | Manual | GitHub App Client Secret (generated on the General page) |
| `dex-grafana-client` | Terraform ([dex_secrets.tf](terraform/config/modules/external-secrets/dex_secrets.tf)) | Dex→Grafana OIDC client secret |
| `dex-s3-proxy-client-secret` | Terraform ([dex_secrets.tf](terraform/config/modules/external-secrets/dex_secrets.tf)) | Dex→S3-proxy OIDC client secret |
| `dex-envoy-client-secret` | Terraform ([dex_secrets.tf](terraform/config/modules/external-secrets/dex_secrets.tf)) | Dex→Envoy Gateway OIDC client secret |
| `dex-actualbudget-client-secret` | Terraform ([dex_secrets.tf](terraform/config/modules/external-secrets/dex_secrets.tf)) | Dex→Actual Budget OIDC client secret |
| `neon-pg-password` | Manual | External PostgreSQL password for n8n |
| `s3-proxy-user-access_key` | Manual | OCI S3-compatible access key |
| `s3-proxy-user-secret_key` | Manual | OCI S3-compatible secret key |
| `ntfy-smtp-sender-pass` | Manual | Yahoo SMTP app password for ntfy email notifications |
| `ntfy-admin-pass` | Manual | ntfy admin user password (used by init container and in-cluster callers) |
| `teleport-github-client-secret` | Manual | GitHub OAuth for Teleport SSO |
| `actualbudget-server-password` | Manual | Actual Budget server password for API access (see note below) |
| `actualbudget-sync-id` | Manual | Actual Budget file Sync ID (Settings → Show advanced settings → Sync ID) |
| `longhorn-backup-s3` | Terraform ([longhorn-backup](terraform/config/modules/longhorn-backup/vault_secret.tf)) | JSON with S3-compatible key pair, endpoint and target URL of the `longhorn-backups` bucket, for Longhorn backups |

> [!NOTE]
> **Actual Budget Schedule Notifier**: The `actualbudget-server-password` is the **server password** set during
> initial Actual Budget server setup — not the OIDC user credentials. The `@actual-app/api` library uses this
> for programmatic access. The schedule-notifier CronJob ([gitops/core/actualbudget/schedule-notifier](gitops/core/actualbudget/schedule-notifier))
> depends on both **Actual Budget** and **ntfy** being fully configured first:
> 1. Actual Budget must be running with a synced budget file
> 2. ntfy must be configured with the `baburciu` admin user and SMTP enabled
> 3. Run `ntfy access baburciu budget-schedules rw` inside the ntfy pod to grant topic access

> [!IMPORTANT]
> **Dex client secrets must be alphanumeric only** (no special characters like `%`, `+`, `=`, `[`, `]`, `{`, `}`).
> Special characters cause URL encoding issues during OAuth token exchange with Envoy Gateway's OIDC filter.
> The Terraform configuration generates secrets with `special = false` to ensure compatibility.

## OIDC Authentication with Dex

This setup uses [Dex](https://dexidp.io/) as an OIDC provider with GitHub as the upstream identity provider.
There are two different authentication patterns used depending on the application.

### Authentication Flow Overview

```mermaid
flowchart TB
    subgraph User["User Browser"]
        Browser
    end

    subgraph GitHub["GitHub"]
        GitHubOAuth["GitHub OAuth"]
    end

    subgraph K8s["Kubernetes Cluster"]
        subgraph DexNS["dex namespace"]
            Dex["Dex OIDC Provider"]
        end

        subgraph EnvoyNS["envoy-gateway-system"]
            EnvoyGW["Envoy Gateway"]
            EnvoyProxy["Envoy Proxy"]
        end

        subgraph AppNS["Application Namespaces"]
            Longhorn["Longhorn UI"]
            Prometheus["Prometheus"]
            Grafana["Grafana"]
        end
    end

    Browser -->|1. Access app| EnvoyProxy
    EnvoyProxy -->|2. Redirect to Dex| Dex
    Dex -->|3. Redirect to GitHub| GitHubOAuth
    GitHubOAuth -->|4. Auth + Consent| Browser
    Browser -->|5. Callback with code| Dex
    Dex -->|6. Exchange code for token| GitHubOAuth
    Dex -->|7. Redirect with Dex code| Browser
    Browser -->|8. Callback to app| EnvoyProxy
    EnvoyProxy -->|9. Exchange code for token| Dex
    EnvoyProxy -->|10. Authenticated request| Longhorn
    EnvoyProxy -->|10. Authenticated request| Prometheus

    Browser -->|Direct OIDC| Grafana
    Grafana -->|Built-in OIDC| Dex
```

### Pattern 1: Envoy Gateway SecurityPolicy (Longhorn, Prometheus)

Applications without built-in OIDC support use Envoy Gateway's [SecurityPolicy](https://gateway.envoyproxy.io/docs/tasks/security/oidc/)
to add authentication at the ingress layer.

```mermaid
sequenceDiagram
    participant User
    participant Envoy as Envoy Proxy
    participant Dex
    participant GitHub
    participant App as Backend App

    User->>Envoy: GET /
    Envoy->>User: 302 Redirect to Dex
    User->>Dex: /dex/auth?client_id=envoy-gateway
    Dex->>User: 302 Redirect to GitHub
    User->>GitHub: OAuth Authorization
    GitHub->>User: 302 Callback to Dex
    User->>Dex: /dex/callback?code=xxx
    Dex->>GitHub: Exchange code for token
    GitHub->>Dex: Access token
    Dex->>User: 302 Redirect to app with Dex code
    User->>Envoy: /oauth2/callback?code=yyy
    Envoy->>Dex: POST /dex/token (exchange code)
    Dex->>Envoy: ID token + Access token
    Envoy->>User: Set session cookie + 302 to /
    User->>Envoy: GET / (with cookie)
    Envoy->>App: Proxied request
    App->>Envoy: Response
    Envoy->>User: Response
```

**Configuration:**
- SecurityPolicy references HTTPRoute and specifies OIDC settings
- Client secret stored in app namespace (e.g., `longhorn/dex-envoy-client`)
- Same `clientID: envoy-gateway` used across all SecurityPolicies
- Redirect URL unique per app (e.g., `https://storage.delaleusystems.com/oauth2/callback`)

**Secrets flow:**
```
OCI Vault (dex-envoy-client-secret)
    ↓ ExternalSecret
K8s Secret (dex-envoy-client) in longhorn namespace → Envoy Gateway SecurityPolicy
K8s Secret (dex-envoy-client) in dex namespace → Dex static client config (via envFrom)
```

### Pattern 2: Built-in OIDC (Grafana)

Applications with native OIDC support handle authentication directly without Envoy Gateway involvement.

```mermaid
sequenceDiagram
    participant User
    participant Envoy as Envoy Proxy
    participant Grafana
    participant Dex
    participant GitHub

    User->>Envoy: GET /
    Envoy->>Grafana: Proxied request
    Grafana->>User: 302 Redirect to Dex
    User->>Dex: /dex/auth?client_id=grafana
    Dex->>User: 302 Redirect to GitHub
    User->>GitHub: OAuth Authorization
    GitHub->>User: 302 Callback to Dex
    User->>Dex: /dex/callback?code=xxx
    Dex->>GitHub: Exchange code for token
    GitHub->>Dex: Access token
    Dex->>User: 302 Redirect to Grafana
    User->>Envoy: /login/generic_oauth?code=yyy
    Envoy->>Grafana: Proxied callback
    Grafana->>Dex: POST /dex/token (exchange code)
    Dex->>Grafana: ID token + Access token
    Grafana->>User: Set session cookie + 302 to /
```

**Configuration:**
- Grafana configured with `GF_AUTH_GENERIC_OAUTH_*` environment variables
- Client secret mounted as volume from K8s secret
- Separate `clientID: grafana` in Dex static clients
- No SecurityPolicy needed on HTTPRoute

**Secrets flow:**
```
OCI Vault (dex-grafana-client)
    ↓ ExternalSecret
K8s Secret (dex-grafana-client) in grafana namespace → Grafana deployment (volume mount)
K8s Secret (dex-grafana-client) in dex namespace → Dex static client config (via envFrom)
```

### Dex Static Clients

Dex is configured with static clients in [helm.yaml](gitops/core/dex/helm.yaml):

| Client Name | Client ID | Used By | Redirect URI |
|-------------|-----------|---------|--------------|
| Envoy | `envoy-gateway` | Longhorn, Prometheus (via SecurityPolicy) | `https://<app>.delaleusystems.com/oauth2/callback` |
| Grafana | `grafana` | Grafana (built-in OIDC) | `https://monitoring.delaleusystems.com/login/generic_oauth` |
| S3Proxy | `s3-proxy` | S3 Proxy (built-in OIDC) | `https://s3.delaleusystems.com/auth/dex/callback` |

#### Development
Switching to a feature/dev branch is rather simple, just modify the
inCluster `FluxInstance` - search for the `sync` block and update the `ref`
section to the according branch.

## Teleport
[Teleport](https://goteleport.com/) is my preferred way to access the kuberentes api
### Prerequisites
In it's current state, teleport wants to setup a wildcard domain like `*.teleport.example.com` (could be disabled).
With OracleCloud managing the dns, this is not possible, as `cert-manager` is not
able to do a `dns01` challenge against orcale dns.
I've now switched to Cloudflare (also to mitigate costs of a few cents).

The Teleport <-> K8s Role (`k8s/system:masters`) is created by the teleport
operator (see the `fluxcd-addons/Kustomization`). The SSO setup is created with
[fluxcd](./gitops/core/teleport/rbac).

### ~Login via local User~ - removed
I've removed local users in teleport and am using SSO with github as idP.

This might still be useful for local setups not using SSO:

The login process must be `reset` for each user, so that
password and 2FA can be configured by each user in the WebUI.
The User can be created via the teleport-operator by creating a `TelepertUser` in
kubernetes.
```
# reset the user once
❯ k --kubeconfig ~/.kube/oci.kubeconfig exec -n teleport -ti deployment/teleport-cluster-auth -- tctl users reset nce

# login to teleport
❯ tsh login --proxy teleport.delaleusystems.com:443 --auth=local --user baburciu teleport.delaleusystems.com
```

### Login via Github
There's no user management in teleport, so no reset, or 2FA setup is needed.
```
❯ tsh login --proxy teleport.delaleusystems.com:443 --auth=github-acme --user baburciu teleport.delaleusystems.com

# login to the k8s cluster
❯ tsh kube login oci

# test
❯ k get po -n teleport
```

### Certificates
The x509 certs are managed by `cert-manager`. With the dns management done by
cloudflare, i've removed all `http01` challenges. The renewal process with
`http01` and cloudflare is [out of the box not possible][cert-manager-cloudflare]

Switching to `dns` challenge solves this issue.

### Known Issues
```
❯ tsh kube login oci
ERROR: connection error: desc = "transport: authentication handshake failed: tls: failed to verify certificate: x509: certificate signed by unknown authority"
```
When reinstalling teleport, during a logged in session happens, the tsh Client
throws this error. A logout & login has to happen.

## Gateway API - Loadbalancer setup
With the recent deprecation of the `nginx-ingress` project, i [switched][pr] to
[GatewayAPI][gatewayapi]. All `ingress` resources are replaced by `httproutes`.
I chose the [envoy-gateway][envoy-gateway] implementation, as they feature
`SecurityPolicies` which allow the protection of `httproutes` with OIDC auth.

With orcale providing a layer 7 loadbalancer, the oci-controller needs to
know which securitygroup should be associated with the lb. This is done by
annotating the Service. Using envoy, we have to add the annotations on an
`EnvoyProxy` CR.
The SG is created via terraform, and it's OCID is written to `ConfigMap/oci-lb-sg-id`,
which is used to feed the value to a [helm chart deploying the `EnvoyProxy` CR](gitops/core/envoy-gateway/charts/envoyproxy).

[gatewayapi]: https://gateway-api.sigs.k8s.io/
[envoy-gateway]: https://gateway.envoyproxy.io/

## Backups
Longhorn backs up the Actual Budget and Bagisto (storage + MySQL) volumes every
night to the `longhorn-backups` OCI Object Storage bucket. The bucket, its
credentials and the Vault secret are created by Terraform; volumes opt in via
PVC labels. Setup, manual backup and restore steps are in [docs/backup.md](docs/backup.md).

## Monitoring

# :money_with_wings: Cost
Overview of my monthly costs:
![](docs/cost.25.png)

# :books: Docs
A collection of relevant upstream documentation for reference

## Ingress
* LB Annotation [for oracle cloud][lb-annotations]
* Providing OCI-IDs to Helm Releases on [nginx][nginx-helm-lb-annotations]

## Cert Manager
* [DNS01 Challenge][cert-manager-dns-challenge]

## External Secrets
* [Advanced Templating for secrets][secrets-templating]

## External Dns
* [CRDs for DNS records][dns-crds]

## Teleport
* [teleport-operator][teleport-operator]
* Teleport [User/Roles RBAC][teleport-rbac]
* Mapping to teleport role
* [SSO with GithubConnector][teleport-github-sso] and [External Client Secret][teleport-client-secret]
* [Helm Chart Deploy Infos][teleport-helm-doc] & [Helm Chart ref][teleport-helm-chart]

## FluxCD
* [Monitoring setup][flux-monitoring]
* [Webhook Config][flux-webhook]
* [Webhook Url Hashing][flux-webhook-hashing]
* [FluxCD Operator][flux-operator-migration]

[lb-annotations]: https://github.com/oracle/oci-cloud-controller-manager/blob/master/docs/load-balancer-annotations.md
[nginx-helm-lb-annotations]: https://github.com/kubernetes/ingress-nginx/blob/74ce7b057e8d4ac96d2e11e027930397e5f70010/charts/ingress-nginx/templates/controller-service.yaml#L7
[cert-manager-dns-challenge]: https://cert-manager.io/docs/configuration/acme/dns01/
[cert-manager-cloudflare]: https://ryanschiang.com/cloudflare-letsencrypt-http-01

[secrets-templating]: https://external-secrets.io/v0.15.0/guides/templating/#helm

[dns-crds]: https://kubernetes-sigs.github.io/external-dns/latest/docs/sources/crd/#using-crd-source-to-manage-dns-records-in-different-dns-providers

[teleport-client-secret]: https://goteleport.com/docs/admin-guides/infrastructure-as-code/teleport-operator/secret-lookup/#step-23-create-a-custom-resource-referencing-the-secret
[teleport-github-sso]: https://goteleport.com/docs/admin-guides/access-controls/sso/github-sso/
[teleport-rbac]: https://goteleport.com/docs/admin-guides/access-controls/getting-started/#step-13-add-local-users-with-preset-roles
[teleport-helm-chart]: https://goteleport.com/docs/reference/helm-reference/teleport-cluster/
[teleport-helm-doc]: https://goteleport.com/docs/admin-guides/deploy-a-cluster/helm-deployments/kubernetes-cluster/
[teleport-operator]: https://goteleport.com/docs/admin-guides/infrastructure-as-code/teleport-operator/

[flux-monitoring]: https://fluxcd.io/flux/monitoring/metrics/#monitoring-setup
[flux-webhook]: https://fluxcd.io/flux/guides/webhook-receivers/
[flux-webhook-hashing]: https://github.com/fluxcd/notification-controller/issues/1067
[flux-operator-migration]: https://fluxcd.control-plane.io/operator/flux-bootstrap-migration/

# Upgrading the Kubernetes Version
There are two ways to move the cluster to a newer version:

| | In-place upgrade | Recreate the cluster |
|---|---|---|
| Steps | one `terraform apply` per minor version, then roll the nodes | targeted destroy + apply at the target version, then restore volumes |
| Downtime | short pod restarts while nodes roll | hours: everything is down until Flux has redeployed and volumes are restored |
| Longhorn data | kept; replicas resync onto the new nodes | lost; restored from the [S3 backups](docs/backup.md) |
| LB public IP | kept | new IP; external-dns updates the Cloudflare records |
| Risk | one node replaced at a time | both A1 nodes released at once; "Out of host capacity" in Frankfurt can leave the cluster without nodes for hours or days |

OKE only offers the next minor version as an upgrade, so an in-place upgrade
across several minors needs one apply per minor. The [K8s skew policy][k8s-skew]
lets kubelets run up to three minor versions behind the control plane, so the
nodes only need to be rolled once, at the end.

[k8s-skew]: https://kubernetes.io/releases/version-skew-policy/#kubelet

## Before either path
* Take fresh Longhorn backups of the volumes that matter ([docs/backup.md](docs/backup.md))
  and check they are `Completed`. For a consistent MySQL backup, scale the apps
  to 0 first.
* Check for API removals in the target version, e.g. `pluto detect-all-in-cluster --target-versions k8s=<version>`.
* Check that a node image exists for the target version. `k8s.tf` picks the
  first image matching `.*aarch.*OKE-<version>.*`:
  ```
  ❯ oci ce node-pool-options get --node-pool-option-id all \
      | jq -r '.data.sources[]."source-name"' | grep aarch | grep 'OKE-1.37.0'
  ```

## In-place upgrade
All commands run inside [terraform/infra/](terraform/infra).

1. Upgrade the control plane, one minor version at a time:
   ```
   # versions offered as next step
   ❯ oci ce cluster get --cluster-id $(terraform output -raw k8s_cluster_id) | jq -r '.data."available-kubernetes-upgrades"'

   # set the version
   ❯ sed -i '' 's/default = "'$(terraform output -raw kubernetes_version)'"/default = "v1.35.2"/' _variables.tf

   # expect: cluster + node_pool "updated in-place", local_file.kube_config replaced
   ❯ terraform plan
   # ~10min; workloads keep running, nodes are not rolled
   ❯ terraform apply
   ❯ kubectl version
   ```
   Repeat until the target version. Each apply also updates the node pool's
   version and image, which only applies to nodes created afterwards.

2. Roll the nodes, one at a time:
   ```
   # instance OCID per node IP
   ❯ oci ce node-pool get --node-pool-id $(terraform output -raw node_pool_id) \
       | jq -r '.data.nodes[] | "\(."private-ip")  \(.id)"'

   ❯ kubectl drain <node-ip> --ignore-daemonsets --delete-emptydir-data
   # the node pool launches a replacement
   ❯ oci compute instance terminate --force --instance-id <instance-ocid>
   ```
   Before rolling the next node, wait until:
   * the new node is `Ready` on the new version (`kubectl get nodes -o wide`)
   * Longhorn accepts it: `kubectl -n longhorn get nodes.longhorn.io` shows
     `READY=True` and `SCHEDULABLE=True`. If not, `kubectl -n longhorn describe
     nodes.longhorn.io <node-ip>` names what's missing (iSCSI, and NFS for RWX
     volumes); install it via [node-pool-init.sh](terraform/infra/files/node-pool-init.sh)
   * all volumes are `healthy` again (`kubectl -n longhorn get volumes.longhorn.io -w`)

   Then delete the old node's entry in the Longhorn UI (Nodes).

   The drain can take a moment: Longhorn's `instance-manager` PDBs block
   eviction until the other node has a healthy replica of every volume
   (`node-drain-policy: block-if-contains-last-replica`).

## Recreate the cluster
Commands in `terraform/infra` unless stated otherwise.

1. Release the load balancer while the cluster still exists. Deleting an OKE
   cluster doesn't delete the LBs it created, and the free tier has room for one:
   ```
   ❯ flux suspend kustomization --all
   ❯ kubectl -n envoy-gateway delete gateway envoy
   # wait until empty
   ❯ oci lb load-balancer list --compartment-id <tenancy-ocid>
   ```
2. Let the nodes drain. Deleting the node pool cordons and drains both nodes
   at once, so Longhorn's PDBs (and the Bagisto Redis one) block it, and OKE
   gives up or forces termination only after a 60min grace period:
   ```
   ❯ kubectl -n longhorn patch settings.longhorn.io node-drain-policy --type=merge -p '{"value":"always-allow"}'
   ❯ kubectl -n bagisto delete pdb bagisto-redis-master
   ❯ kubectl get pdb -A   # expect none
   ```
3. Destroy only the cluster. Its dependents are the node pool and the local
   kubeconfig file; the Vault, its key and the network stay:
   ```
   # expect exactly 3 to destroy: cluster, node_pool, local_file.kube_config
   ❯ terraform plan -destroy -target=oci_containerengine_cluster.k8s_cluster -out=destroy.tfplan
   ❯ terraform apply destroy.tfplan
   ```
   Node pool deletion takes ~15min once the nodes can drain, creating
   the new cluster and node pool takes ~15min.
4. Create the new cluster at the target version:
   ```
   ❯ sed -i '' 's/default = "v1.34.1"/default = "v1.37.0"/' _variables.tf
   # expect: cluster, node_pool, local_file.kube_config created
   ❯ terraform plan -out=create.tfplan
   ❯ terraform apply create.tfplan
   ```
   The plan also re-adds the 443 and NodePort rules to the security lists: the
   cloud controller removed them together with the old LB.
5. Re-apply the config stack in [terraform/config/](terraform/config). It
   recreates Flux, the GitHub App secret, the `ClusterSecretStore`, the
   `oci-lb-sg-id` ConfigMap and the namespaces in the new cluster. Read the
   plan: anything other than creates for those K8s objects (e.g. a Vault secret
   being destroyed) needs fixing first.
   ```
   ❯ terraform plan
   ❯ terraform apply
   ```
   The first apply fails on the `ClusterSecretStore`: its CRD and validating
   webhook only exist once Flux has installed External Secrets. Wait until
   `kubectl -n external-secrets get deploy` shows all three deployments ready,
   then run `terraform apply` again.
6. Flux bootstraps everything from git. external-dns points the Cloudflare
   records to the new LB IP and cert-manager re-issues the certificates.
   The apps with backed-up volumes start empty.
   Kustomizations whose dry-run ran before the External Secrets webhook or the
   Envoy Gateway / cert-manager CRDs were ready show `dry-run failed`, and only
   retry at their 1h interval. Speed that up with
   `flux -n flux-system reconcile ks <name>` for each of them.

   The OIDC-protected routes (Longhorn, Prometheus, Flux UI, Bagisto admin)
   answer `500` at first: Envoy Gateway fetched Dex's discovery document before
   external-dns had created `login.delaleusystems.com`, marked the
   `SecurityPolicies` `Accepted=False`, and doesn't retry. The OCI VCN resolver
   also caches that "no such host" for up to 30min. Once the name resolves in
   the cluster, restart the Envoy Gateway controller (the proxy keeps serving):
   ```
   ❯ kubectl run dnscheck --rm -i --restart=Never --image=busybox:1.36 -- nslookup login.delaleusystems.com
   ❯ kubectl -n envoy-gateway rollout restart deploy/envoy-gateway
   ❯ kubectl get securitypolicy -A -o json | jq -r '.items[] | "\(.metadata.name): \(.status.ancestors[0].conditions[0].status)"'
   ```
7. Restore the volumes as described in [docs/backup.md](docs/backup.md#restore)
   (UI or kubectl).
8. The new cluster has a new OCID: use `terraform/.kube.config`, or regenerate
   the local kubeconfig with `oci ce cluster create-kubeconfig --cluster-id <ocid> ...`.

# Upgrading Longhorn
Longhorn only upgrades one minor version at a time (e.g. 1.10 → 1.11 → 1.12 → 1.13),
so bump the chart version in [longhorn/helm.yaml](gitops/core/longhorn/helm.yaml)
once per minor and let each step finish before the next.

Upgrade with the volumes detached. Each Longhorn version runs its own
`instance-manager` pod per node, which reserves `guaranteed-instance-manager-cpu`
(12% of a node, ~220m on these 2-OCPU nodes). A live engine upgrade moves a volume's
replicas to the new instance manager, but its engine process stays in the old one
until the volume is detached, so every step leaves one more instance manager per
node. With the nodes at ~95% CPU requests, the next version's instance manager can't
be scheduled (`state=error`), and from then on no volume can attach. Detached
volumes are upgraded offline in seconds and leave a single instance manager per node.

1. Take fresh backups of the volumes that matter ([docs/backup.md](docs/backup.md)).
2. Stop every workload with a Longhorn volume. Suspend the Kustomizations of plain
   manifests (e.g. `ntfy`), otherwise Flux scales them back; HelmReleases have no
   drift correction. Prometheus is scaled through its `Prometheus` resource:
   ```
   ❯ flux -n flux-system suspend ks ntfy
   ❯ kubectl -n ntfy scale deploy/ntfy --replicas=0
   ❯ kubectl -n actualbudget scale deploy/actualbudget --replicas=0
   ❯ kubectl -n bagisto scale deploy/bagisto-bagisto sts/bagisto-bagisto-mysql sts/bagisto-redis-master --replicas=0
   ❯ kubectl -n monitoring patch prometheus kube-prometheus-stack-prometheus --type=merge -p '{"spec":{"replicas":0}}'
   # wait until every volume is detached
   ❯ kubectl -n longhorn get volumes.longhorn.io
   ```
3. For each minor version: bump the chart, push, and wait until the new engine image
   is `deployed`, only the new instance managers are left, and every volume's
   `status.currentImage` is the new engine (`concurrentAutomaticEngineUpgradePerNodeLimit: 1`
   upgrades detached volumes automatically):
   ```
   ❯ kubectl -n longhorn get engineimages.longhorn.io,instancemanagers.longhorn.io
   ❯ kubectl -n longhorn get volumes.longhorn.io -o custom-columns=NAME:.metadata.name,STATE:.status.state,ENGINE:.status.currentImage
   ```
   A `faulted` volume is skipped by the automatic upgrade; set its `spec.image` to
   the new engine image by hand while it's detached.
4. Start the workloads again (MySQL and Redis before Bagisto), resume the suspended
   Kustomizations and check that all volumes are `attached`/`healthy`.
5. Delete the engine images no volume uses any more (`REFCOUNT 0`):
   `kubectl -n longhorn delete engineimages.longhorn.io <name>`.

Flux's dry-run of the `longhorn-backup` RecurringJob can fail while Longhorn's
admission webhook restarts during the upgrade; it passes on the next reconcile.
