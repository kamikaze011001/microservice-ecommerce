---
name: minikube-tunnel-external-ip-is-sticky
description: A LoadBalancer showing EXTERNAL-IP 127.0.0.1 does not mean minikube tunnel is running — the value persists after the tunnel exits
metadata: { type: convention, date: 2026-08-01 }
---

`minikube tunnel` **patches** `EXTERNAL-IP: 127.0.0.1` onto LoadBalancer Services, and that
value **stays on the Service after the tunnel process exits**. So this is *not* a health check:

```bash
kubectl -n infra get svc ingress-nginx-controller   # EXTERNAL-IP 127.0.0.1  ← proves nothing
```

A cluster can show `127.0.0.1` while every request returns `000` / connection refused.

**Check the process and the listener instead:**
```bash
ps aux | grep '[m]inikube tunnel'
lsof -nP -iTCP:80 -sTCP:LISTEN
```
Both empty + `EXTERNAL-IP 127.0.0.1` = the tunnel ran at some point and died.

**Why it dies:** `make k8s-tunnel` runs `minikube tunnel` in the **foreground** and it prompts
for **sudo** (it binds privileged ports 80/443). A declined or mistyped password, a Ctrl-C, or
closing the terminal kills it — and the stale EXTERNAL-IP makes it look like it is still up.

**How to apply:** to test ingress *rules* without depending on the tunnel at all, port-forward
the controller and pass the hostname explicitly — this cleanly separates "are my Ingress
manifests right" from "is the tunnel up on this machine":

```bash
kubectl -n infra port-forward svc/ingress-nginx-controller 18090:80 &
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: microecom.local' http://localhost:18090/
```

Related: [[minikube-registry-host-5001-pod-5000]] for the other place minikube needs a
port-forward because a Service is not reachable from the host.
