#!/usr/bin/env bash
# Lightwell remediation demo: a Flask app pinned to a vulnerable Jinja2 is
# found by a scanner, then fixed by swapping in Lightwell's patched build of
# the *same* version from the offline Nexus. No upgrade, no code change.
#
#   ./demo/run_demo.sh              # pauses between steps on a terminal
#   DEMO_PAUSE=0 ./demo/run_demo.sh # run straight through
#
# Needs: uv (for Python 3.12 and pip-audit), the seeded Nexus from
# compose.yaml, and internet access for public PyPI (step 1) and the OSV
# database (scans). Set LIGHTWELL_OSV_DIR to a lightwell-osv checkout to read
# Lightwell's advisories from disk instead of osv.dev.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
APP=$HERE/app
BUILD=$HERE/build
NEXUS=${NEXUS:-http://localhost:8081}
LIGHTWELL_INDEX=$NEXUS/repository/pypi-lightwell/simple/
PUBLIC_INDEX=https://pypi.org/simple/
PY=${PY:-3.12}            # Lightwell builds target CPython 3.12
PORT=${PORT:-5055}
OSV_DIR=${LIGHTWELL_OSV_DIR:-}
PAUSE=${DEMO_PAUSE:-$([ -t 0 ] && echo 1 || echo 0)}
export PIP_CONFIG_FILE=/dev/null PIP_DISABLE_PIP_VERSION_CHECK=1 PYTHONDONTWRITEBYTECODE=1

b=$(tput bold 2>/dev/null || true); r=$(tput sgr0 2>/dev/null || true)
red=$(tput setaf 1 2>/dev/null || true); grn=$(tput setaf 2 2>/dev/null || true)
step() { echo; echo "${b}━━━ $* ━━━${r}"; }
say()  { echo "${b}>${r} $*"; }
run()  { echo "${b}\$ $*${r}"; "$@"; }
pause() { [ "$PAUSE" = 1 ] && { read -rp "  [enter to continue] " _ </dev/tty; } || true; }
site() { echo "$BUILD/$1/lib/python$PY/site-packages"; }
# Scan an environment, then check the findings against Lightwell's advisories.
lw_audit() {
    uvx -q pip-audit -s osv -f json -o "$BUILD/$1-audit.json" --path "$(site "$1")" \
        >/dev/null 2>&1 || true
    run python3 -I "$HERE/lightwell_audit.py" "$BUILD/$1-audit.json" ${OSV_DIR:+--osv-dir "$OSV_DIR"}
}

command -v uv >/dev/null || { echo "uv is required: https://docs.astral.sh/uv/" >&2; exit 1; }
curl -fsS -o /dev/null "$LIGHTWELL_INDEX" ||
    { echo "Nexus not reachable at $LIGHTWELL_INDEX (podman compose up -d)" >&2; exit 1; }
rm -rf "$BUILD"; mkdir -p "$BUILD"

# --------------------------------------------------------------------------
step "1. Build the app as it is today (public PyPI)"
say "A notification service that renders user-written templates in Jinja2's sandbox."
say "requirements.txt pins Jinja2 to the certified version:"
grep -v '^#' "$APP/requirements.txt" | sed 's/^/    /'
uv venv -q --seed --python "$PY" "$BUILD/before"
run "$BUILD/before/bin/pip" install -q --index-url "$PUBLIC_INDEX" -r "$APP/requirements.txt"
say "Installed: $("$BUILD/before/bin/python" -c 'import jinja2; print("jinja2", jinja2.__version__)')"
pause

# --------------------------------------------------------------------------
step "2. Security scan finds a known vulnerability"
run uvx -q pip-audit -s osv --desc on --path "$(site before)" || true
say "CVE-2025-27516: the |attr filter lets a template slip past the sandbox."
say "Upstream's fix is Jinja2 3.1.6, but we can't take a new release yet."
say "Check the findings against Red Hat Lightwell's OSV advisories:"
lw_audit before || true
say "Lightwell has a backported fix for the version we're on: 3.1.5+rhlw.1."
say "The security team adds a regression test for the CVE (test_attr_filter_is_sandboxed):"
(cd "$APP" && run "$BUILD/before/bin/python" -m pytest -q -p no:cacheprovider) &&
    echo "${red}unexpected: tests passed${r}" ||
    echo "${red}=> vulnerable: the sandbox regression test fails on jinja2 3.1.5${r}"
pause

# --------------------------------------------------------------------------
step "3. Remediate with Lightwell: same version, patched build"
sed 's/^jinja2==3\.1\.5$/jinja2==3.1.5+rhlw.1/' "$APP/requirements.txt" > "$BUILD/requirements.txt"
say "The whole change is one line in requirements.txt, plus the package index:"
diff -u --label requirements.txt --label requirements.txt \
    "$APP/requirements.txt" "$BUILD/requirements.txt" | tail -n +3 | sed 's/^/    /' || true
say "Install only from the offline Nexus (no PyPI access):"
uv venv -q --seed --python "$PY" "$BUILD/after"
run "$BUILD/after/bin/pip" install -q --index-url "$LIGHTWELL_INDEX" -r "$BUILD/requirements.txt"
say "Installed: $("$BUILD/after/bin/python" -c 'import jinja2; print("jinja2", jinja2.__version__)')"
pause

# --------------------------------------------------------------------------
step "4. Verify the fix"
say "a) The same test suite, unchanged, now passes:"
(cd "$APP" && run "$BUILD/after/bin/python" -m pytest -q -p no:cacheprovider) &&
    echo "${grn}=> fixed: all tests pass on jinja2 3.1.5+rhlw.1${r}"
pause

say "b) Exactly what Lightwell changed, comparing the installed packages:"
(cd "$(site before)" && diff -rq -x __pycache__ jinja2 "$(site after)/jinja2") |
    sed -E 's#^Files (\S+) and .* differ#    changed: \1#' || true
diff -u "$(site before)/jinja2/filters.py" "$(site after)/jinja2/filters.py" \
    | grep -E '^[-+@]' | grep -v -E '^(\+\+\+|---) ' | sed 's/^/    /' || true
say "Only the |attr filter changed: the upstream 3.1.6 fix, backported to 3.1.5."
pause

say "c) Provenance from the SBOM that ships inside the wheel:"
"$BUILD/after/bin/python" - "$(site after)" <<'EOF'
import json, pathlib, sys
sbom = next(pathlib.Path(sys.argv[1]).glob("jinja2-*.dist-info/sboms/*.spdx.json"))
doc = json.loads(sbom.read_text())
pkgs = {p["SPDXID"]: p for p in doc["packages"]}
print(f"    {sbom.name}: created {doc['creationInfo']['created']} by "
      f"{', '.join(doc['creationInfo']['creators'])}")
for rel in doc["relationships"]:
    if rel["relationshipType"] == "GENERATED_FROM":
        a, b = pkgs[rel["spdxElementId"]], pkgs[rel["relatedSpdxElement"]]
        purl = lambda p: p["externalRefs"][0]["referenceLocator"].split("?")[0]
        print(f"    {purl(a)} (supplier: {a['supplier']})\n      GENERATED_FROM {purl(b)}")
EOF
pause

say "d) Re-scan the patched build. A plain version-based scan still flags it:"
run uvx -q pip-audit -s osv --path "$(site after)" || true
cat <<EOF
    pip-audit queries the "PyPI" ecosystem and drops the "+rhlw.1" local
    version, so it matches upstream 3.1.5. (Its default PyPI service is worse:
    it can't find 3.1.5+rhlw.1 on PyPI, skips it and reports "no known
    vulnerabilities".) Lightwell publishes the fix as an OSV record in the
    "Red Hat Lightwell:PyPI" ecosystem, which the Lightwell-aware check reads:
EOF
lw_audit after &&
    echo "${grn}=> security gate passes: the CVE is closed by a published Lightwell advisory${r}"
pause

# --------------------------------------------------------------------------
step "5. Run the remediated app"
(cd "$APP" && exec "$BUILD/after/bin/flask" --app app run --port "$PORT" >"$BUILD/flask.log" 2>&1) &
trap 'kill $! 2>/dev/null || true' EXIT
until curl -fsS -o /dev/null "http://127.0.0.1:$PORT/healthz" 2>/dev/null; do sleep 0.3; done
run curl -sS "http://127.0.0.1:$PORT/healthz"
run curl -sS -H 'Content-Type: application/json' "http://127.0.0.1:$PORT/preview" \
    -d '{"template": "Hi {{ customer.name }}, your order {{ order.id }} has shipped."}'
echo
say "${grn}Done: CVE-2025-27516 fixed without upgrading Jinja2 or touching application code.${r}"
