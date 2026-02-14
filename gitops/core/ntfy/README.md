# [ntfy](https://docs.ntfy.sh)

Configured with Yahoo free SMTP.

## [Configuration](./server.yml)

- **Auth mode**: `deny-all` - requires authentication for all access
- **Admin user**: `baburciu`
- **SMTP**: Yahoo SMTP (`smtp.mail.yahoo.com:587`)

## Managing Topics & Access

Topics are created automatically when you first publish to them. However, since `auth-default-access: deny-all` is set, you must grant access first.

### Exec into the NTFY pod

```bash
kubectl exec -it deployment/ntfy -n ntfy -- sh
```

### Grant access to a topic

```bash
# Grant read-write access to a topic
ntfy access baburciu budget-schedules rw

# Grant read-only access
ntfy access baburciu alerts ro

# Grant write-only access (can publish but not subscribe)
ntfy access baburciu notifications wo

# View all access rules
ntfy access
```

### Creating tokens (optional)

Tokens can be used instead of username/password for API access:

```bash
# Create a token for a user
ntfy token add baburciu

# Create a token with a label
ntfy token add --label="budget-notifier" baburciu

# List all tokens
ntfy token list

# Remove a token
ntfy token remove tk_xxxxxxxxxxxx
```

Tokens are used with Bearer auth: `Authorization: Bearer tk_xxxxxxxxxxxx`

## Usage Examples

### Send notification with email (basic auth)

```bash
kubectl run -it --image docker.io/nicolaka/netshoot:v0.13 k8s-network -- sh

# Send to 'alerts' topic with email delivery
curl -u baburciu:"$NTFY_ADMIN_PASS" \
    -H "Email: bogdanadrian.burciu@yahoo.com" \
    -d "Email sent via ntfy.delaleusystems.com" \
    http://ntfy.ntfy.svc.cluster.local/alerts
```

### Send notification with token auth

```bash
curl -H "Authorization: Bearer tk_xxxxxxxxxxxx" \
    -H "Email: bogdanadrian.burciu@yahoo.com" \
    -d "Message body" \
    http://ntfy.ntfy.svc.cluster.local/alerts
```

### Send with priority and tags

```bash
curl -u baburciu:"$NTFY_ADMIN_PASS" \
    -H "Title: Important Alert" \
    -H "Priority: high" \
    -H "Tags: warning,skull" \
    -H "Email: bogdanadrian.burciu@yahoo.com" \
    -d "Something important happened!" \
    http://ntfy.ntfy.svc.cluster.local/alerts
```

## Access from Kubernetes

Only internal cluster access is allowed via `http://ntfy.ntfy.svc.cluster.local`. External access through `ntfy.delaleusystems.com` requires authentication.
