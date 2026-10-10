# [Claude Code](https://github.com/baburciu/claude-code-in-k8s)

Runs `claude remote-control` so sessions can be started from `claude.ai/code` or
the Claude mobile app. Remote Control only makes outbound connections, so
there is no Service or HTTPRoute.

## First-time login

The login lives on the `claude-home` PVC, so this is needed once per volume.
Until then the pod is Running and logs a reminder every 30s.

```bash
kubectl exec -it deployment/claude-code -n claude-code -- claude auth login
# Trust the workspace folder: accept the prompt, then /exit
kubectl exec -it deployment/claude-code -n claude-code -- bash -c 'cd ~/workspace && claude'
# Answer "y" to "Enable Remote Control?", then detach with Ctrl-P Ctrl-Q (not Ctrl-C)
kubectl attach -it deployment/claude-code -n claude-code
```

## Upgrading

Bump the image tag in [deployment.yaml](./deployment.yaml) to a newer
Claude Code version published by the image's CI.
