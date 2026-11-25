#!/usr/bin/env bash
# Prepare the offline Gitea (compose service "gitea") for the Renovate demo:
#   * admin user  $GITEA_ADMIN_USER (default gitea-admin), password from .env
#   * bot user    renovate-bot, with an API token saved to demo/.renovate-token
#   * repository  demo/lightwell-python-demo-app, pushed from ./lightwell-python-demo-app
#
#   ./demo/setup-gitea.sh           # safe to re-run; creates what's missing
#   ./demo/setup-gitea.sh --reset   # delete and re-push the repo (start the demo over)
#
# Gitea's CLI runs in a throwaway container that shares the gitea service's
# volumes, so no `podman exec` is needed.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

RESET=0
[ "${1:-}" = --reset ] && RESET=1

wait_for_gitea
CID=$(podman ps -q --filter label=com.docker.compose.service=gitea | head -n 1)
[ -n "$CID" ] || die "gitea container not running (podman compose up -d gitea)"
IMAGE=$(podman inspect -f '{{.ImageName}}' "$CID")
gitea_cli() { podman run --rm --volumes-from "$CID" "$IMAGE" gitea "$@"; }
PASS=$(admin_password)

# --- Users ------------------------------------------------------------------
users=$(gitea_cli admin user list | awk 'NR > 1 {print $2}')
if ! grep -qx "$GITEA_ADMIN" <<<"$users"; then
    say "Creating admin user $GITEA_ADMIN"
    gitea_cli admin user create --admin --username "$GITEA_ADMIN" --password "$PASS" \
        --email "$GITEA_ADMIN@example.com" --must-change-password=false >/dev/null
fi
if ! grep -qx "$BOT" <<<"$users"; then
    say "Creating bot user $BOT"
    gitea_cli admin user create --username "$BOT" --email "$BOT@example.com" \
        --password "$(head -c 24 /dev/urandom | base64)" --must-change-password=false >/dev/null
fi

# --- Renovate's token -------------------------------------------------------
if ! { [ -s "$TOKEN_FILE" ] &&
       curl -fsS -o /dev/null -H "Authorization: token $(cat "$TOKEN_FILE")" "$GITEA/api/v1/user"; }; then
    say "Creating an API token for $BOT -> ${TOKEN_FILE#"$ROOT"/}"
    token=$(gitea_cli admin user generate-access-token --username "$BOT" \
        --token-name "renovate-$(date +%Y%m%d%H%M%S)" --raw \
        --scopes write:repository,write:issue,read:user,read:organization,read:misc)
    (umask 077 && printf '%s\n' "$token" > "$TOKEN_FILE")
fi

# --- Organisation and repository ---------------------------------------------
gitea_api GET "/orgs/$ORG" >/dev/null 2>&1 ||
    gitea_api POST /orgs "{\"username\": \"$ORG\", \"visibility\": \"public\"}" >/dev/null

if gitea_api GET "/repos/$SLUG" >/dev/null 2>&1; then
    if [ "$RESET" = 1 ]; then
        say "Deleting $SLUG (--reset)"
        gitea_api DELETE "/repos/$SLUG" >/dev/null
    else
        say "Repository $GITEA/$SLUG already exists (use --reset to start over)"
        exit 0
    fi
fi

say "Creating $SLUG and pushing ${APP_SRC#"$ROOT"/}"
gitea_api POST "/orgs/$ORG/repos" \
    "{\"name\": \"$REPO\", \"default_branch\": \"main\", \"description\": \"Lightwell + Renovate Python demo\"}" >/dev/null
for label in security:#d73a4a lightwell:#ee0000; do
    gitea_api POST "/repos/$SLUG/labels" "{\"name\": \"${label%%:*}\", \"color\": \"${label#*:}\"}" >/dev/null
done
gitea_api PUT "/repos/$SLUG/collaborators/$BOT" '{"permission": "write"}' >/dev/null

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cp -r "$APP_SRC"/. "$work"/
rm -rf "$work"/__pycache__ "$work"/.pytest_cache
auth=$(printf '%s:%s' "$GITEA_ADMIN" "$PASS" | base64 -w0)
git -C "$work" init -q -b main
git -C "$work" add -A
git -C "$work" -c user.name="Demo Developer" -c user.email=dev@example.com \
    commit -q -m "Notification service: Flask app pinned to the certified Jinja2 3.1.5"
git -C "$work" -c http.extraHeader="Authorization: Basic $auth" \
    push -q "$GITEA/$SLUG.git" main

say "${grn}Ready:${r} $GITEA/$SLUG  (log in as $GITEA_ADMIN)"
