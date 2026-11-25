# Shared settings and helpers for the Renovate demo scripts. Sourced, not run.
# shellcheck shell=bash

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

# Read a KEY=value setting from the environment, else from the project's .env
# (without sourcing .env as shell code).
setting() {
    local v=${!1:-}
    [ -n "$v" ] || v=$(sed -n "s/^$1=//p" "$ROOT/.env" 2>/dev/null | tail -n 1)
    printf '%s' "${v:-${2:-}}"
}

GITEA=$(setting GITEA_URL "http://localhost:$(setting GITEA_PORT 3000)")
NEXUS=$(setting NEXUS_URL "http://localhost:$(setting NEXUS_PORT 8081)")
GITEA_ADMIN=$(setting GITEA_ADMIN_USER gitea-admin)
BOT=$(setting RENOVATE_BOT_USER renovate-bot)
ORG=demo
REPO=lightwell-python-demo-app
SLUG=$ORG/$REPO
APP_SRC=$HERE/$REPO
TOKEN_FILE=$HERE/.renovate-token
RENOVATE_IMAGE=$(setting RENOVATE_IMAGE docker.io/renovate/renovate:44.257.3)

b=$(tput bold 2>/dev/null || true); r=$(tput sgr0 2>/dev/null || true)
red=$(tput setaf 1 2>/dev/null || true); grn=$(tput setaf 2 2>/dev/null || true)
step() { echo; echo "${b}━━━ $* ━━━${r}"; }
say()  { echo "${b}>${r} $*"; }
run()  { echo "${b}\$ $*${r}"; "$@"; }
die()  { echo "error: $*" >&2; exit 1; }

admin_password() {
    local p; p=$(setting GITEA_ADMIN_PASSWORD)
    [ -n "$p" ] || die "set GITEA_ADMIN_PASSWORD in $ROOT/.env (see nexus.env.example)"
    printf '%s' "$p"
}

# Gitea REST API as the admin user: gitea_api METHOD PATH [JSON body]
gitea_api() {
    local auth; auth=$(printf '%s:%s' "$GITEA_ADMIN" "$(admin_password)" | base64 -w0)
    curl -fsS -X "$1" -H "Authorization: Basic $auth" -H 'Content-Type: application/json' \
        ${3:+--data "$3"} "$GITEA/api/v1$2"
}

wait_for_gitea() {
    local i
    for i in $(seq 60); do
        curl -fsS -o /dev/null "$GITEA/api/healthz" 2>/dev/null && return 0
        sleep 2
    done
    die "Gitea not reachable at $GITEA (podman compose up -d gitea)"
}
