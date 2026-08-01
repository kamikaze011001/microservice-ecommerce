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

**How to apply:** to test ingress *rules* without depending on the tunnel, port-forward the
controller and pass the hostname explicitly — this separates "are my Ingress manifests right"
from "is the tunnel up on this machine":

```bash
kubectl -n infra port-forward svc/ingress-nginx-controller 18090:80 &
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: microecom.local' http://localhost:18090/
```

**This is a diagnostic, NOT a substitute for the tunnel.** It cannot run the app in a browser:
`k8s/apps/overlays/local/kustomization.yaml` bakes the SPA's API base as
`http://api.microecom.local` with **no port**, so a storefront served from `:8080` still issues
its XHR against port **80**. The page loads and every API call fails. curl only appears to work
because you supply the port yourself, which the SPA cannot.

There is therefore **no sudo-free path** to a working browser session — port 80 must be bound,
and that needs root. Run `sudo -v && make k8s-tunnel` so the password is cached at a clean
prompt; `minikube tunnel` interleaves its own `Password:` prompt with `❗`/`🔗` status lines and
prints "Tunnel successfully started" *before* attempting the privileged bind, so a missed prompt
looks like success and then silently exits.

Related: [[minikube-registry-host-5001-pod-5000]] for the other place minikube needs a
port-forward because a Service is not reachable from the host.
