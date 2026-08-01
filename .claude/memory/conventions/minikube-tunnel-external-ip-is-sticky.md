---
name: minikube-tunnel-external-ip-is-sticky
description: How to tell whether minikube tunnel is really up — EXTERNAL-IP lies, and so does an unprivileged lsof
metadata: { type: convention, date: 2026-08-01 }
---

Three ways to be wrong about whether `minikube tunnel` is running. All three bit us on 2026-08-01.

## 1. `EXTERNAL-IP` is sticky — it survives the tunnel's death

`minikube tunnel` **patches** `EXTERNAL-IP: 127.0.0.1` onto LoadBalancer Services, and the value
**stays after the tunnel process exits**:

```bash
kubectl -n infra get svc ingress-nginx-controller   # EXTERNAL-IP 127.0.0.1  ← proves nothing
```

A cluster can show `127.0.0.1` while every request returns `000` / connection refused.

## 2. An unprivileged `lsof` cannot see the listener

The tunnel **re-execs under sudo** to bind privileged ports, so the socket on :80 is owned by
**root** — and `lsof -iTCP:80 -sTCP:LISTEN` as a normal user does not list other users' sockets
at all. It reports nothing against a tunnel that is serving traffic fine.

This is not academic: `cluster.sh` originally polled with `lsof`, never saw the healthy tunnel,
hit its 30s timeout, and called `stop_tunnel` on a working tunnel.

**Use an ownership-blind TCP connect instead** — it sees what a browser sees:

```bash
(exec 3<>/dev/tcp/127.0.0.1/80) 2>/dev/null && echo up || echo down
```

`/dev/tcp` is a **bash builtin**; it does not exist in zsh, so an interactive zsh check will
report "down" on a healthy tunnel. `cluster.sh` is fine (bash shebang) — your terminal may not be.

The same ownership rule applies to the kill path: an unprivileged `pkill -f 'minikube tunnel'`
cannot signal the root-owned process. `stop_tunnel` verifies the port actually freed and prints
`sudo pkill -f 'minikube tunnel'` rather than claiming a stop that did not happen.

## 3. `sudo -v` in *another* terminal does not count

macOS sudo defaults to **`tty_tickets`**: the cached credential is scoped to the terminal that
created it. Keep both halves on one line, in one shell:

```bash
sudo -v && make k8s-tunnel
```

A caller with **no TTY at all** (an agent shell, CI, cron) can never satisfy this — sudo refuses
to read a password without a terminal, so it cannot start the tunnel by any arrangement.
`start_tunnel` detects that with `tty -s` and says so instead of repeating advice that cannot work.

## Why the tunnel is needed at all (kind did not need it)

kind's `extraPortMappings` had the **already-privileged Docker daemon** publish :80 on the node
container at cluster creation — permanent, no per-session root. minikube's node containers publish
no :80, so the bind happens in **userspace** and needs root every session.

There is **no sudo-free path** to browsing the app. `k8s/images/build.sh` bakes the SPA's API base
as `http://api.microecom.local` with **no port** (Vite inlines env vars at *image build time*), so
a storefront served from a port-forward on :8080 still issues its XHR against port **80**. The page
loads and every API call fails. Port-forwarding `svc/ingress-nginx-controller` and passing
`-H 'Host: ...'` is a **diagnostic for Ingress rules only** — curl only appears to work because you
supply the port yourself, which the SPA cannot.

Related: [[minikube-registry-host-5001-pod-5000]] for the other place minikube needs a
port-forward because a Service is not reachable from the host.
