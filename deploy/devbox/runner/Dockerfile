# devbox-runner — devbox.sh in a box, for the portal's Jobs (create/delete an
# env, …). Same script as `make devbox-*`, so the portal never re-implements
# what is already proven.
#
# Build context: a copy of the repo's deploy/ tree + docker/seed-images (devbox.sh `portal` stages it;
# deploy/.run and build output are left out). Built and tagged with
# `version_of devbox-runner`, i.e. the last commit that touched deploy/.
FROM alpine:3.20

ARG TARGETARCH
ARG KUBECTL_VERSION=v1.31.4
RUN apk add --no-cache bash coreutils findutils git jq curl python3 py3-yaml \
 && curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH:-amd64}/kubectl" -o /usr/local/bin/kubectl \
 && chmod +x /usr/local/bin/kubectl

WORKDIR /workspace
COPY deploy ./deploy
# The pre-apps seed uploads the catalog's product images from here.
COPY docker/seed-images ./docker/seed-images

# Commits to the env repo are authored by the portal, not "devbox".
ENV DEVBOX_IN_CLUSTER=1 DEVBOX_ACTOR=devbox-portal
ENTRYPOINT ["bash", "/workspace/deploy/devbox/runner/entrypoint.sh"]
