---
name: a-shared-builder-assumes-its-local-registry
description: deploy/images/build.sh probed every registry over plain HTTP, so the AWS path hung 75s on ECR's closed port 80 and then told the operator to start minikube
metadata: { type: convention, date: 2026-08-21 }
---

`deploy/images/build.sh` is shared by the local minikube path and the AWS/ECR path. It
opened with:

```bash
if ! curl -fsS -o /dev/null "http://${REGISTRY}/v2/" 2>/dev/null; then
  echo "ERROR: registry at ${REGISTRY} is not reachable." >&2
  echo "Run 'make k8s-cluster-up' or 'make k8s-registry-forward' first." >&2
```

`scripts/aws/push-images.sh:33` sets `REGISTRY` to the ECR host and calls the same
script. Measured against the real endpoint:

```
curl: (28) Failed to connect to 583178372344.dkr.ecr.ap-southeast-1.amazonaws.com
      port 80 after 75028 ms: Couldn't connect to server
```

So step 2 of the AWS bring-up **could not work at all**: 75 seconds of silence, then an
exit pointing at minikube — the wrong system entirely.

The probe was not wrong, only mis-scoped. It answers "is the local dev registry up?", a
question that only makes sense for a plain-HTTP registry on this machine. On the AWS
path it is also redundant: `push-images.sh:40` already runs
`aws ecr get-login-password | docker login`, the real reachability-and-auth check.

Fixed by extracting `registry_is_local_http` into `deploy/images/lib/registry-target.sh`,
gating the probe on it, and adding `--max-time 5` so even the local probe cannot hang.
Anchor the match — `localhost|localhost:*|127.0.0.1|127.0.0.1:*`, never `*localhost*`,
because `localhost.attacker.example.com` contains the word and is remote.

**How to apply:** when one script serves both a local and a remote target, every
environment-sensitive assumption in it is a latent bug on whichever path was added
later. Look for `http://`, `localhost`, and error messages naming a specific local tool.
Related: [[an-unexercised-path-fails-where-nothing-rendered-it]].
