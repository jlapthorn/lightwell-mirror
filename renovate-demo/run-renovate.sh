#!/usr/bin/env bash
# Run Renovate once against the demo repository in the offline Gitea, in the
# role the scheduled GitHub Action plays in lightwell-java-demo-app. It reads
# the repo's renovate.json, looks packages up on the offline Nexus and opens
# remediation PRs in Gitea.
#
#   ./renovate-demo/run-renovate.sh
#   LOG_LEVEL=debug ./renovate-demo/run-renovate.sh
#
# Needs: podman, the gitea and nexus compose services, and setup-gitea.sh
# having been run (it writes the bot token). Extra arguments go to renovate.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

[ -s "$TOKEN_FILE" ] || die "no Renovate token at $TOKEN_FILE; run renovate-demo/setup-gitea.sh"
wait_for_gitea

# The token goes through the environment, not the command line, so it
# doesn't show up in `ps`. allowInternal lets Renovate reach Gitea and Nexus
# on localhost; it's only accepted in this (self-hosted, global) config.
RENOVATE_TOKEN=$(cat "$TOKEN_FILE") exec podman run --rm --network host \
    -e RENOVATE_TOKEN \
    -e LOG_LEVEL="${LOG_LEVEL:-info}" \
    -e RENOVATE_PLATFORM=gitea \
    -e RENOVATE_ENDPOINT="$GITEA/api/v1" \
    -e RENOVATE_REPOSITORIES="$SLUG" \
    -e RENOVATE_ONBOARDING=false \
    -e RENOVATE_REQUIRE_CONFIG=required \
    -e RENOVATE_GIT_AUTHOR="Renovate Bot <$BOT@example.com>" \
    -e RENOVATE_HOST_RULES='[{"matchHost": "localhost", "allowInternal": true}]' \
    "$RENOVATE_IMAGE" "$@"
