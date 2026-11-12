#!/bin/sh
# One-shot seeder: configures a fresh Nexus and uploads the mirrored
# artifacts from /mirror into hosted repositories. Safe to re-run: a repo is
# skipped once a marker for it exists in /seed-state (SEED_FORCE=1 overrides).
set -eu

NEXUS="${NEXUS_URL:-http://nexus:8081}"
API="$NEXUS/service/rest/v1"
: "${NEXUS_ADMIN_PASSWORD:?NEXUS_ADMIN_PASSWORD must be set}"
SEED_REPOS="${SEED_REPOS:?SEED_REPOS must list name:format pairs}"
JOBS="${SEED_JOBS:-8}"
STATE=/seed-state
NETRC=/tmp/netrc

log() { echo "$(date +%H:%M:%S) seed: $*"; }

write_netrc() {
    umask 077
    printf 'machine %s login admin password %s\n' \
        "$(echo "$NEXUS" | sed -E 's#^[a-z]+://([^:/]+).*#\1#')" "$1" > "$NETRC"
}

# curl wrapper: prints HTTP status, body goes to /tmp/resp.
call() {
    curl -sS --netrc-file "$NETRC" -o /tmp/resp -w '%{http_code}' "$@"
}

# --- upload helpers (run under xargs -P, one file per call) ---------------
# Each prints nothing on success and "path<TAB>status" on failure.
upload_maven() {  # repo-name file
    rel=${2#/mirror/$1/}
    code=$(curl -sS --netrc-file "$NETRC" -o /dev/null -w '%{http_code}' \
        --retry 3 -T "$2" "$NEXUS/repository/$1/$rel") || code=curl-error
    case $code in 2??) ;; *) printf '%s\t%s\n' "$rel" "$code" ;; esac
}
upload_pypi() {  # repo-name file
    rel=${2#/mirror/$1/}
    code=$(curl -sS --netrc-file "$NETRC" -o /tmp/pypi.$$ -w '%{http_code}' \
        --retry 3 -F "pypi.asset=@$2" "$API/components?repository=$1") || code=curl-error
    case $code in
        2??) ;;
        # Re-runs: Nexus rejects a file that is already stored.
        400) grep -qi 'already\|exist' /tmp/pypi.$$ 2>/dev/null ||
                 printf '%s\t%s %s\n' "$rel" "$code" "$(head -c 200 /tmp/pypi.$$)" ;;
        *) printf '%s\t%s\n' "$rel" "$code" ;;
    esac
    rm -f /tmp/pypi.$$
}
if [ "${1:-}" = __upload ]; then shift; NETRC=$NETRC "upload_$@"; exit 0; fi

log "waiting for $NEXUS"
until [ "$(curl -s -o /dev/null -w '%{http_code}' "$API/status/writable")" = 200 ]; do
    sleep 5
done

# --- admin password -------------------------------------------------------
if [ -s /nexus-data/admin.password ]; then
    write_netrc "$(cat /nexus-data/admin.password)"
    if [ "$(call -X PUT -H 'Content-Type: text/plain' \
            --data-binary "$NEXUS_ADMIN_PASSWORD" \
            "$API/security/users/admin/change-password")" = 204 ]; then
        log "admin password changed from the generated one"
    fi
fi
write_netrc "$NEXUS_ADMIN_PASSWORD"
code=$(call "$API/repositories")
[ "$code" = 200 ] || { log "admin login failed (HTTP $code)"; exit 1; }

# --- EULA (Community Edition requires acceptance before use) -------------
if [ "$(call "$API/system/eula")" = 200 ] && grep -q '"accepted" *: *false' /tmp/resp; then
    sed -E 's/"accepted" *: *false/"accepted": true/' /tmp/resp > /tmp/eula.json
    code=$(call -X POST -H 'Content-Type: application/json' \
        --data-binary @/tmp/eula.json "$API/system/eula")
    log "EULA accepted (HTTP $code)"
fi

# --- anonymous read access ------------------------------------------------
anon="${NEXUS_ANONYMOUS:-false}"
call -X PUT -H 'Content-Type: application/json' \
    -d "{\"enabled\":$anon,\"userId\":\"anonymous\",\"realmName\":\"NexusAuthorizingRealm\"}" \
    "$API/security/anonymous" >/dev/null
log "anonymous access: $anon"

# --- repositories ---------------------------------------------------------
create_repo() {  # name format(maven|pypi) type(hosted|group) [members...]
    name=$1 fmt=$2 type=$3; shift 3
    exists=false
    [ "$(call "$API/repositories/$name")" = 200 ] && exists=true
    # Existing hosted repos are left alone; existing groups get their member
    # list updated below, so a repo added to SEED_REPOS later joins the group.
    [ "$exists" = true ] && [ "$type" != group ] && return
    if [ "$type" = group ]; then
        members=$(printf '"%s",' "$@" | sed 's/,$//')
        body="{\"name\":\"$name\",\"online\":true,
               \"storage\":{\"blobStoreName\":\"default\",\"strictContentTypeValidation\":true},
               \"group\":{\"memberNames\":[$members]}"
    else
        body="{\"name\":\"$name\",\"online\":true,
               \"storage\":{\"blobStoreName\":\"default\",\"strictContentTypeValidation\":false,\"writePolicy\":\"allow\"}"
    fi
    [ "$fmt" = maven ] && body="$body,\"maven\":{\"versionPolicy\":\"MIXED\",\"layoutPolicy\":\"PERMISSIVE\",\"contentDisposition\":\"INLINE\"}"
    body="$body}"
    if [ "$exists" = true ]; then
        code=$(call -X PUT -H 'Content-Type: application/json' -d "$body" \
            "$API/repositories/$fmt/$type/$name")
        [ "$code" = 204 ] || { log "updating $name failed (HTTP $code): $(cat /tmp/resp)"; exit 1; }
        log "$fmt group $name members:$*"
        return
    fi
    code=$(call -X POST -H 'Content-Type: application/json' -d "$body" \
        "$API/repositories/$fmt/$type")
    [ "$code" = 201 ] || { log "creating $name failed (HTTP $code): $(cat /tmp/resp)"; exit 1; }
    log "created $fmt $type repo $name"
}

seed_repo() {  # name format
    name=$1 fmt=$2 dir=/mirror/$1
    if [ ! -d "$dir" ]; then log "skip $name: $dir not found"; return; fi
    if [ -e "$STATE/$name.done" ] && [ "${SEED_FORCE:-0}" != 1 ]; then
        log "skip $name: already seeded"; return
    fi
    create_repo "$name" "$fmt" hosted
    if [ "$fmt" = maven ]; then
        # Includes .sha1/.md5/... files: Nexus doesn't generate them for
        # artifacts uploaded with a plain PUT, and Maven clients expect them.
        find "$dir" -type f ! -name '*.part' -print0
    else
        find "$dir" -type f \( -name '*.whl' -o -name '*.tar.gz' -o -name '*.zip' \
            -o -name '*.tar.bz2' -o -name '*.egg' \) -print0
    fi > /tmp/files.$name
    total=$(tr -cd '\0' < /tmp/files.$name | wc -c)
    log "uploading $total files into $name ($JOBS parallel)"
    xargs -0 -P "$JOBS" -n 1 sh "$0" __upload "$fmt" "$name" \
        < /tmp/files.$name > "$STATE/$name.failed.txt"
    failed=$(wc -l < "$STATE/$name.failed.txt")
    if [ "$failed" -eq 0 ]; then
        rm -f "$STATE/$name.failed.txt"
        touch "$STATE/$name.done"
        log "$name: done ($total files)"
    else
        log "$name: $failed of $total failed, see seed-state volume $name.failed.txt"
        rc=1
    fi
}

rc=0
maven_members="" pypi_members=""
for pair in $SEED_REPOS; do
    name=${pair%%:*} fmt=${pair#*:}
    seed_repo "$name" "$fmt"
    # Only repos that exist can join a group (missing mirror dirs are skipped).
    [ "$(call "$API/repositories/$name")" = 200 ] || continue
    case $fmt in
        maven) maven_members="$maven_members $name" ;;
        pypi) pypi_members="$pypi_members $name" ;;
    esac
done

# Group repos: one URL per format, members in SEED_REPOS order (first wins).
# Created (or their member list updated) after all hosted repos exist.
[ -n "$maven_members" ] && [ -n "${MAVEN_GROUP:-}" ] && create_repo "$MAVEN_GROUP" maven group $maven_members
[ -n "$pypi_members" ] && [ -n "${PYPI_GROUP:-}" ] && create_repo "$PYPI_GROUP" pypi group $pypi_members

log "finished (exit $rc)"
exit $rc
