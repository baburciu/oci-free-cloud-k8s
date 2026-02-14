# Actual Budget Schedule Notifier

A Kubernetes CronJob that checks Actual Budget for scheduled transactions and sends email notifications via [ntfy](https://docs.ntfy.sh) when payments are due. I use it for fixed-term deposits.

## Features

- Connects to Actual Budget server using the official `@actual-app/api` library
- Checks for scheduled transactions due today (high priority notification)
- Sends summary of upcoming transactions in the next 3 days
- Sends email notifications via NTFY's email gateway

## Configuration

### Required Secrets in Oracle Vault

The ExternalSecret fetches these from Oracle Vault:

1. **`actualbudget-server-password`**: The **server password** (not OIDC credentials!)
   - This is the password you set when first configuring Actual Budget server
   - Even with OIDC enabled for user login, the server still has a separate server-level password
   - The `@actual-app/api` library uses this server password for API access
   - If you don't remember it, check Actual Budget data directory or [reset it](https://actualbudget.org/docs/troubleshooting/reset_password/)

2. **`actualbudget-sync-id`**: budget's Sync ID
   - Find it in Actual Budget: Settings → Show advanced settings → Sync ID
   - Looks like: `abcd1234-5678-90ef-ghij-klmnopqrstuv`

3. **`ntfy-admin-pass`**: Reuses existing NTFY admin password (already in vault)

### Environment Variables in CronJob

- `ACTUAL_SERVER_URL`: Internal Kubernetes service URL for Actual Budget (default: `http://actualbudget.actualbudget.svc.cluster.local:5006`)
- `NTFY_URL`: Internal Kubernetes service URL for NTFY (default: `http://ntfy.ntfy.svc.cluster.local`)
- `NTFY_TOPIC`: The NTFY topic to publish to (default: `budget-schedules`)
- `NTFY_USER`: NTFY username for basic auth (default: `baburciu`)
- `NOTIFICATION_EMAIL`: Email address to receive notifications

### Schedule

By default, the CronJob runs daily at 8:00 AM (Europe/Bucharest timezone). Modify the `schedule` field in [`cronjob.yaml`](./cronjob.yaml) to change this:

## NTFY Setup

### Creating a Topic

Topics in NTFY are created automatically when you first publish to them.

### Authentication

This setup uses **basic auth** with existing NTFY admin credentials (`baburciu` + password from `ntfy-admin-pass`). No need to create separate tokens.

If you prefer token-based auth instead:

```bash
# Inside the NTFY pod
ntfy token add --label="budget-notifier" baburciu
# Returns: tk_xxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

Then update the cronjob.yaml to use `NTFY_TOKEN` instead of `NTFY_USER`/`NTFY_PASSWORD`.


## Notification Format

### Payment Due Today (High Priority)
```
💰 Payment Due Today: Rent Payment
---
Payee: Landlord
Amount: $1,500.00
Account: Checking
Date: 2024-02-14
```

### Upcoming Payments Summary (Normal Priority)
```
📅 3 Upcoming Payments (Next 3 Days)
---
• 2024-02-15: Electric Bill - $120.00
• 2024-02-16: Internet - $80.00
• 2024-02-17: Subscription - $15.00
```
