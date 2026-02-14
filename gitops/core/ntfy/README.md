# [ntfy](https://docs.ntfy.sh)

Configured with Yahoo free SMTP.

## Usage

```shell
kubectl run -it  --image docker.io/nicolaka/netshoot:v0.13  k8s-network -- sh
# only k8s service access is allowed, the external ntfy.delaleusystems.com is not accessible
# due to server setting 'auth-default-access: deny-all'
curl -u baburciu:"$NTFY_ADMIN_PASS" \
    -H "Email: bogdanadrian.burciu@yahoo.com" \
    -d "Email sent via ntfy.delaleusystems.com" \
    http://ntfy.ntfy.svc.cluster.local/alerts
```
