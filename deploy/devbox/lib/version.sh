# shellcheck shell=bash
# Image versions for the devbox. Sourced by devbox.sh and tests/version-test.sh.
#
# A service's tag is the LAST COMMIT THAT CHANGED ITS BUILD INPUTS — not HEAD.
# A commit touching only order-service gives order-service a new tag and leaves
# the other nine on theirs, so they aren't rebuilt and a rollback of one service
# can't drag the others along. Same inputs ⇒ same tag ⇒ the image already in
# the registry is reused.
#
# Uncommitted (or untracked) changes in those inputs give
#   <sha>-dirty-<MMDD-HHMM>
# — unique per build, and honest: you can see it isn't reproducible from git.

# version_inputs <service> — paths whose content ends up in the image. Mirrors
# the COPY lines of the Dockerfile that builds it (deploy/images/build.sh).
version_inputs() {
  case "$1" in
    frontend)            echo "frontend" ;;
    mock-paypal-service) echo "mock-paypal-service" ;;
    devbox-portal)       echo "deploy/devbox/portal" ;;
    *) echo "$1 core deploy/images/Dockerfile.jvm deploy/images/Dockerfile.cores" ;;
  esac
}

# version_of <service> [now] — prints the tag. `now` (MMDD-HHMM) is injectable
# so tests are deterministic. Run from the repo root.
version_of() {
  local svc=$1 now=${2:-$(date +%m%d-%H%M)} inputs sha
  # shellcheck disable=SC2046 # word-splitting the path list is intended
  inputs=$(version_inputs "$svc")
  # shellcheck disable=SC2086
  sha=$(git log -1 --format=%h --abbrev=7 -- $inputs)
  if [[ -z "$sha" ]]; then
    echo "version_of: no commit touches $inputs" >&2
    return 1
  fi
  # shellcheck disable=SC2086
  if [[ -n "$(git status --porcelain -- $inputs)" ]]; then
    echo "$sha-dirty-$now"
  else
    echo "$sha"
  fi
}

# is_dirty_tag <tag> — dirty tags are never reused: two dirty builds in the
# same minute from different edits must not share a tag.
is_dirty_tag() { [[ "$1" == *-dirty-* ]]; }
