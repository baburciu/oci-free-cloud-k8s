# Bagisto - Delaleu Systems Marketplace

Kubernetes manifests for deploying [Bagisto](https://bagisto.com/) e-commerce marketplace at `store.delaleusystems.com`.

## Architecture

Bagisto is deployed via a Helm chart sourced from [baburciu/bagisto-helm](https://github.com/baburciu/bagisto-helm) and reconciled by Flux.

## Manifests

| File | Description |
|---|---|
| `namespace.yaml` | Creates the `bagisto` namespace |
| `helm.yaml` | GitRepository source and HelmRelease for the Bagisto chart |
| `httproute.yaml` | Gateway API HTTPRoutes for public and admin traffic |
| `securitypolicy.yaml` | Envoy Gateway SecurityPolicy for OIDC on the admin path |
| `secret.yaml` | ExternalSecret to sync the Dex OIDC client secret from OCI Vault |
| `kustomization.yaml` | Kustomize resource list |

## Routing and OIDC Protection

The storefront is publicly accessible, while the `/admin` panel is protected with GitHub OIDC authentication via Dex.

This is achieved with two HTTPRoutes on the same hostname (`store.delaleusystems.com`):

### `bagisto` HTTPRoute (public)

Matches `/` — serves the public storefront with no authentication.

### `bagisto-admin` HTTPRoute (OIDC-protected)

Matches `/admin`, `/oauth2`, and `/logout`. A `SecurityPolicy` targets this route to enforce OIDC authentication through Dex (with GitHub as the identity provider).

Gateway API path specificity rules ensure the more specific `/admin`, `/oauth2`, and `/logout` prefixes take precedence over the catch-all `/`.

### Why `/oauth2` and `/logout` must be on the admin route

The OIDC filter is only active on routes that the `SecurityPolicy` targets. During the OIDC flow:

1. User visits `/admin` -> OIDC filter redirects to Dex for GitHub login
2. Dex redirects back to `/oauth2/callback` -> OIDC filter exchanges the auth code for tokens and sets session cookies
3. User is redirected to `/admin` with a valid session

If `/oauth2/callback` were matched by the public `/` route instead, there would be no OIDC filter to process the callback, and the authentication flow would break. The same applies to `/logout` — the OIDC filter must intercept it to clear the session.

## OIDC Flow

```
User -> /admin
  |
  v
Envoy OIDC filter (SecurityPolicy on bagisto-admin HTTPRoute)
  |
  v
Redirect to Dex (login.delaleusystems.com/dex/)
  |
  v
GitHub OAuth login
  |
  v
Dex redirects to /oauth2/callback
  |
  v
Envoy OIDC filter completes token exchange, sets session cookie
  |
  v
Redirect back to /admin (authenticated)
```

## Prerequisites

- Envoy Gateway with the `envoy` Gateway in `envoy-gateway` namespace
- Dex deployed at `login.delaleusystems.com` with the `envoy-gateway` static client configured
- The `dex-envoy-client-secret` stored in OCI Vault
- A `store.delaleusystems.com/oauth2/callback` redirect URI registered in the Dex `envoy-gateway` static client
