# env-config — the desired state of your devbox envs

Argo CD keeps the cluster equal to this repo. To change an env, commit here.

```
envs/
  prod-like/
    env.yaml                 settings shared by every service in the env
    services/<service>.yaml  one file = one Argo CD Application (<env>-<service>)
```

- **Deploy another version of a service:** change `image.tag` in its file, commit, push.
- **Roll back:** `git revert` the commit (or set the old tag again). The history is `git log`.
- **Change config:** non-secret env vars go under `apps.<service>.env`. Secrets stay in Vault, never here.

Seeded from `deploy/devbox/env-repo/` in the microecom repo on the first
`make devbox-up`. After that, THIS repo is the source of truth — the seed is
never re-applied, so your history is kept.
