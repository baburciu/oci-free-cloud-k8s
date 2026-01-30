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
  * flux → github commit annotation about conciliation status
- [x] Teleport for k8s cluster access
- [x] Storage
   * with longhorn
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

gh_token = "github_pat_aa"

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
Therefore we need a GitHub Personal Acccess Token (PAT - fine grained) in for this repo, with these permissions
```console
contents        - read, write
commit statuses - read, write
webhooks        - read, write
```

* Place this token in a [private tfvars of `config`](terraform/config/config.auto.tfvars). This is used to generate the fluxcd webhook url, which triggers fluxcd reconciliation after each commit
* Place this token in the oci vault (`github-fluxcd-token`). This allows fluxcd
to annotate the github commit status, depending on the state of the `Kustomization`.

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
| `github-fluxcd-token` | Manual | GitHub PAT for Flux notifications |
| `slack-fluxcd-token` | Manual | Slack webhook URL for Flux alerts |
| `github-app-client-id` | Manual | GitHub App Client ID |
| `github-app-client-secret` | Manual | GitHub App Client Secret (generated on the General page) |
| `dex-grafana-client` | Terraform ([dex_secrets.tf](terraform/config/modules/external-secrets/dex_secrets.tf)) | Dex→Grafana OIDC client secret |
| `dex-s3-proxy-client-secret` | Terraform ([dex_secrets.tf](terraform/config/modules/external-secrets/dex_secrets.tf)) | Dex→S3-proxy OIDC client secret |
| `dex-envoy-client-secret` | Terraform ([dex_secrets.tf](terraform/config/modules/external-secrets/dex_secrets.tf)) | Dex→Envoy Gateway OIDC client secret |
| `cloudflare-api-token` | Manual | Cloudflare API token for external-dns |
| `s3-proxy-user-access_key` | Manual | OCI S3-compatible access key |
| `s3-proxy-user-secret_key` | Manual | OCI S3-compatible secret key |
| `teleport-github-client-secret` | Manual | GitHub OAuth for Teleport SSO |

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
I recommend only upgrading to the version the first command (`available-kubernetes-upgrades`) shows.
Other upgrades, or jumps to the latest version not being shown, might break the process.
The [K8s Skew policy][k8s-skew] allows the worker nodes (`kubelets`)
to be three minor versions behind, so you might be alright, if you incrementally update the controlplane,
before updating the nodepool.

[k8s-skew]: https://kubernetes.io/releases/version-skew-policy/#kubelet

The commands should be executed inside [terraform/infra/](terraform/infra)
```
# get new cluster versions
❯ oci ce cluster get --cluster-id $(terraform output --raw k8s_cluster_id) | jq -r '.data."available-kubernetes-upgrades"'

# update the cluster version with the information from above
❯ sed -i '' 's/default = "'$(terraform output --raw kubernetes_version)'"/default = "v1.31.1"/' _variables.tf

# upgrade the controlplane and the nodepool & images
# this shouldn't roll the nodes and might take around 10mins
❯ terraform apply
```
 To roll the nodes, i cordon & drain the k8s node:
```
❯ k drain <k8s-node-name> --force --ignore-daemonsets --delete-emptydir-data
❯ k cordon <k8s-node-name>
```
A node deletion in k8s doesn't trigger a change in the `nodepool`. For that, we
need to terminate the correct instance. But i haven't figured out how to delete the -
currently cordoned - node, only using `oci`.

So, login to the webui -> Oke Cluster -> Node pool and check for the right
instance by looking at the private_ip and copy the id.

Now terminate that instance:
```
❯ oci compute instance terminate --force --instance-id <oidc.id>
```
This triggers a node recreation. Now wait till the node is Ready; And then wait for
longhorn to sync the volumes.
```
# wait until all volumes are healthy again
❯ k get -w volumes.longhorn.io -A
```
Repeat the cordon/drain/terminate for the second node.
### OKE Upgrade 1.31.1
For the current update, i've written above upgrade instructions.
Worked flawlessly, though still with a bit of manual interaction in the webui...

### OKE Upgrade 1.29.1
I mostly skipped `1.27.2` & `1.28.2` (on the workers) and went for the `1.29` release. As the UI didn't
prompt for a direct upgrade path of the control-plane, i upgraded the k8s-tf
version to the prompted next release, ran the upgrade, and continued with the next version.

The worker nodes remained at `1.26.7` during the oke upgrade, which worked because with 1.28
the new skew policy allows for worker nodes to be three versions behind.

### OKE Upgrade 1.25.4

:warning: remember to remove any `PSP`s first

1. Upgrade the nodepool & cluster version by setting the k8s variable; Run terrafrom (takes ~10min)
2. Drain/Cordon worker01
3. Go to the UI; delete the worker01 from the nodepool
4. Scale the Nodepool back to 2 (takes ~10min)
5. Wait for longhorn to sync (no volume in state `degraded`)
6. repeat for second node (2-5)

### OKE Upgrade 1.24

The 1.23.4 -> 1.24.1 Kubernetes Upgrade went pretty smooth, but by hand.

I followed the official guide:

- https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengupgradingk8smasternode.htm
- https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengupgradingk8sworkernode.htm

Longhorn synced all volumes after the new node got ready. No downtime experienced.
