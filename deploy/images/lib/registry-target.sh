#!/usr/bin/env bash
# Classify a container registry as local-plain-HTTP or remote. Source, don't execute.
#
# build.sh probes the registry over http:// before building. That question is
# only meaningful for the local dev registry: a remote registry does not serve
# port 80, so the probe hangs until it times out and then blames minikube. Remote
# registries authenticate through `docker login` in their own caller
# (scripts/aws/push-images.sh), which is the real reachability check.
#
# Matching is anchored to the WHOLE host, not a substring: "localhost.example.com"
# is a remote host that merely starts with the word.

# registry_is_local_http <registry>
#   0 = plain-HTTP registry on this machine; build.sh should probe it
#   1 = anything else, including the empty string
registry_is_local_http() {
    case "${1:-}" in
        localhost|localhost:*|127.0.0.1|127.0.0.1:*) return 0 ;;
        *) return 1 ;;
    esac
}
