#!/usr/bin/env bash
# Lightwell + Renovate demo. A Flask app pinned to a vulnerable Jinja2 lives in
# an offline Gitea. A scanner finds the CVE, Renovate opens a PR that moves the
# pin to Lightwell's patched build of the *same* version, the PR is merged,
# and the app is rebuilt from the offline Nexus. No upgrade, no code change.
#
#   ./renovate-demo/run_demo.sh              # pauses between steps on a terminal
#   DEMO_PAUSE=0 ./renovate-demo/run_demo.sh # run straight through
#
# Needs: uv (Python 3.12 and pip-audit), podman, the nexus and gitea compose
# services, and internet access for public PyPI (step 1) and the OSV database
# (scans). Set LIGHTWELL_OSV_DIR to a lightwell-osv checkout to read
# Lightwell's advisories from disk instead of osv.dev.
# The demo starts from a fresh copy of the repo in Gitea every time.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

BUILD=$HERE/build
SRC=$BUILD/$REPO
PY=${PY:-3.12}            # Lightwell builds target CPython 3.12
OSV_DIR=${LIGHTWELL_OSV_DIR:-}
PAUSE=${DEMO_PAUSE:-$([ -t 0 ] && echo 1 || echo 0)}
export PIP_DISABLE_PIP_VERSION_CHECK=1 PYTHONDONTWRITEBYTECODE=1

pause() { [ "$PAUSE" = 1 ] && { read -rp "  [enter to continue] " _ </dev/tty; } || true; }
site() { echo "$BUILD/$1/lib/python$PY/site-packages"; }
# Scan an environment, then check the findings against Lightwell's advisories.
lw_audit() {
    uvx -q pip-audit -s osv -f json -o "$BUILD/$1-audit.json" --path "$(site "$1")" \
        >/dev/null 2>&1 || true
    run python3 -I "$ROOT/demo/lightwell_audit.py" "$BUILD/$1-audit.json" ${OSV_DIR:+--osv-dir "$OSV_DIR"}
}
open_prs() { gitea_api GET "/repos/$SLUG/pulls?state=open"; }
json() { python3 -c "import json,sys; d=json.load(sys.stdin); $1"; }
git_auth() {
    git -c http.extraHeader="Authorization: Basic $(printf '%s:%s' "$GITEA_ADMIN" "$(admin_password)" | base64 -w0)" "$@"
}

command -v uv >/dev/null || die "uv is required: https://docs.astral.sh/uv/"
curl -fsS -o /dev/null "$NEXUS/repository/pypi-lightwell/simple/" ||
    die "Nexus not reachable at $NEXUS (podman compose up -d)"
step "0. Reset the demo repository in Gitea"
"$HERE/setup-gitea.sh" --reset
rm -rf "$BUILD"; mkdir -p "$BUILD"
git_auth clone -q "$GITEA/$SLUG.git" "$SRC"

# --------------------------------------------------------------------------
step "1. The app as it is today"
say "A notification service that renders user-written templates in Jinja2's sandbox."
say "Repository: $GITEA/$SLUG"
say "requirements.txt pins Jinja2 to the certified version:"
grep -v '^#' "$SRC/requirements.txt" | sed 's/^/    /'
say "Built from public PyPI, as production is today:"
uv venv -q --seed --python "$PY" "$BUILD/before"
run env PIP_CONFIG_FILE=/dev/null "$BUILD/before/bin/pip" install -q \
    --index-url https://pypi.org/simple/ -r "$SRC/requirements.txt"
say "Installed: $("$BUILD/before/bin/python" -c 'import jinja2; print("jinja2", jinja2.__version__)')"
pause

# --------------------------------------------------------------------------
step "2. Security scan finds a known vulnerability"
run uvx -q pip-audit -s osv --desc on --path "$(site before)" || true
say "CVE-2025-27516: the |attr filter lets a template slip past the sandbox."
say "Upstream's fix is Jinja2 3.1.6, but we can't take a new release yet."
say "Check the findings against Red Hat Lightwell's OSV advisories:"
lw_audit before || true
say "The CVE regression test (test_attr_filter_is_sandboxed) fails:"
(cd "$SRC" && run "$BUILD/before/bin/python" -m pytest -q -p no:cacheprovider) &&
    echo "${red}unexpected: tests passed${r}" ||
    echo "${red}=> vulnerable: the sandbox regression test fails on jinja2 3.1.5${r}"
pause

# --------------------------------------------------------------------------
step "3. Renovate proposes the Lightwell fix"
say "renovate.json only allows +rhlw rebuilds of the version already pinned"
say "(3.1.5 -> 3.1.5+rhlw.1, never 3.1.6), looked up on the offline Nexus:"
python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); print("    versioning:", c["customManagers"][0]["versioningTemplate"]); print("    registry:  ", c["packageRules"][0]["registryUrls"][0])' "$SRC/renovate.json"
say "Run Renovate (on a schedule in real life):"
"$HERE/run-renovate.sh" 2>&1 | grep -E '(Branch|PR) created|"prTitle"|ERROR|WARN' || true
PR=$(open_prs | json 'print(next(p["number"] for p in d if p["head"]["ref"].startswith("renovate/")))') ||
    die "Renovate didn't open a PR; rerun with LOG_LEVEL=debug ./renovate-demo/run-renovate.sh"
open_prs | json "p=next(p for p in d if p['number']==$PR); print('    PR #%d: %s\n    labels: %s\n    %s' % (p['number'], p['title'], ', '.join(l['name'] for l in p['labels']), p['html_url']))"
say "The whole change:"
gitea_api GET "/repos/$SLUG/pulls/$PR.diff" | grep -E '^[-+][^-+]' | sed 's/^/    /'
pause

# --------------------------------------------------------------------------
step "4. Review and merge the PR"
say "Open $GITEA/$SLUG/pulls/$PR (log in as $GITEA_ADMIN) and click Merge,"
say "or just continue and the script merges it for you."
pause
if gitea_api GET "/repos/$SLUG/pulls/$PR" | json 'sys.exit(0 if d["merged"] else 1)'; then
    say "PR #$PR was merged in Gitea."
else
    run gitea_api POST "/repos/$SLUG/pulls/$PR/merge" '{"Do": "merge", "delete_branch_after_merge": true}'
    say "PR #$PR merged."
fi
git_auth -C "$SRC" pull -q --ff-only
grep '^jinja2' "$SRC/requirements.txt" | sed 's/^/    main: /'
pause

# --------------------------------------------------------------------------
step "5. Rebuild from the offline Nexus and verify"
say "pip.conf in the repo points pip at Nexus (pypi-lightwell), like .mvn/settings.xml in the Java demo:"
grep -v '^#' "$SRC/pip.conf" | sed 's/^/    /'
uv venv -q --seed --python "$PY" "$BUILD/after"
(cd "$SRC" && run env PIP_CONFIG_FILE=pip.conf "$BUILD/after/bin/pip" install -q -r requirements.txt)
say "Installed: $("$BUILD/after/bin/python" -c 'import jinja2; print("jinja2", jinja2.__version__)')"
say "a) The same test suite, unchanged, now passes:"
(cd "$SRC" && run "$BUILD/after/bin/python" -m pytest -q -p no:cacheprovider) &&
    echo "${grn}=> fixed: all tests pass on jinja2 3.1.5+rhlw.1${r}"
pause
say "b) Exactly what Lightwell changed, comparing the installed packages:"
diff -u "$(site before)/jinja2/filters.py" "$(site after)/jinja2/filters.py" \
    | grep -E '^[-+@]' | grep -v -E '^(\+\+\+|---) ' | sed 's/^/    /' || true
say "Only the |attr filter changed: the upstream 3.1.6 fix, backported to 3.1.5."
pause
say "c) The security gate: the Lightwell-aware check marks the CVE fixed:"
lw_audit after &&
    echo "${grn}=> security gate passes: the CVE is closed by a published Lightwell advisory${r}"
pause

# --------------------------------------------------------------------------
step "6. Renovate keeps watching"
"$HERE/run-renovate.sh" >/dev/null 2>&1 || true
say "Renovate run again: $(open_prs | json 'print(len([p for p in d if p["head"]["ref"].startswith("renovate/")]))') open Renovate PRs."
say "When Lightwell publishes 3.1.5+rhlw.2, the next run opens a PR for it."
say "Dependency Dashboard: $GITEA/$SLUG/issues"
echo
say "${grn}Done: CVE-2025-27516 fixed by a Renovate PR, without upgrading Jinja2 or touching application code.${r}"
