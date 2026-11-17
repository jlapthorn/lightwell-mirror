# Every command run by demo/run_demo.sh, with all variables expanded, for
# copying and pasting into a shell one step at a time. Values are the
# script's defaults on this machine:
#   app      /home/jlapthor/git/lightwell-mirror/demo/app
#   build    /home/jlapthor/git/lightwell-mirror/demo/build
#   Nexus    http://localhost:8081  (index .../repository/pypi-lightwell/simple/)
#   Python   3.12, app port 5055, Lightwell advisories from osv.dev
# The script's exported PIP_* settings are replaced by pip's --isolated and
# --disable-pip-version-check flags (ignore any local pip config).
#
# Needs: uv, the seeded Nexus running, internet access to pypi.org and osv.dev.

# --- Preflight ---------------------------------------------------------------
command -v uv
curl -fsS -o /dev/null http://localhost:8081/repository/pypi-lightwell/simple/ && echo "Nexus OK"
rm -rf /home/jlapthor/git/lightwell-mirror/demo/build
mkdir -p /home/jlapthor/git/lightwell-mirror/demo/build

# --- 1. Build the app as it is today (public PyPI) ---------------------------
# requirements.txt pins Jinja2 to the certified version:
grep -v '^#' /home/jlapthor/git/lightwell-mirror/demo/app/requirements.txt

uv venv -q --seed --python 3.12 /home/jlapthor/git/lightwell-mirror/demo/build/before

/home/jlapthor/git/lightwell-mirror/demo/build/before/bin/pip install --isolated --disable-pip-version-check -q --index-url https://pypi.org/simple/ -r /home/jlapthor/git/lightwell-mirror/demo/app/requirements.txt

/home/jlapthor/git/lightwell-mirror/demo/build/before/bin/python -c 'import jinja2; print("jinja2", jinja2.__version__)'

# --- 2. Security scan finds a known vulnerability ----------------------------
uvx -q pip-audit -s osv --desc on --path /home/jlapthor/git/lightwell-mirror/demo/build/before/lib/python3.12/site-packages

# Check the findings against Red Hat Lightwell's OSV advisories
# (scan to JSON, then reconcile):
uvx -q pip-audit -s osv -f json -o /home/jlapthor/git/lightwell-mirror/demo/build/before-audit.json --path /home/jlapthor/git/lightwell-mirror/demo/build/before/lib/python3.12/site-packages

python3 -I /home/jlapthor/git/lightwell-mirror/demo/lightwell_audit.py /home/jlapthor/git/lightwell-mirror/demo/build/before-audit.json

# Run the app's tests, including the CVE regression test (expect 1 failed, 3 passed):
(cd /home/jlapthor/git/lightwell-mirror/demo/app && /home/jlapthor/git/lightwell-mirror/demo/build/before/bin/python -B -m pytest -q -p no:cacheprovider)

# --- 3. Remediate with Lightwell: same version, patched build ----------------
sed 's/^jinja2==3\.1\.5$/jinja2==3.1.5+rhlw.1/' /home/jlapthor/git/lightwell-mirror/demo/app/requirements.txt > /home/jlapthor/git/lightwell-mirror/demo/build/requirements.txt

# The whole change is one line:
diff -u --label requirements.txt --label requirements.txt /home/jlapthor/git/lightwell-mirror/demo/app/requirements.txt /home/jlapthor/git/lightwell-mirror/demo/build/requirements.txt | tail -n +3

# Install only from the offline Nexus (no PyPI access):
uv venv -q --seed --python 3.12 /home/jlapthor/git/lightwell-mirror/demo/build/after

/home/jlapthor/git/lightwell-mirror/demo/build/after/bin/pip install --isolated --disable-pip-version-check -q --index-url http://localhost:8081/repository/pypi-lightwell/simple/ -r /home/jlapthor/git/lightwell-mirror/demo/build/requirements.txt

/home/jlapthor/git/lightwell-mirror/demo/build/after/bin/python -c 'import jinja2; print("jinja2", jinja2.__version__)'

# --- 4. Verify the fix -------------------------------------------------------
# a) The same test suite, unchanged, now passes (expect 4 passed):
(cd /home/jlapthor/git/lightwell-mirror/demo/app && /home/jlapthor/git/lightwell-mirror/demo/build/after/bin/python -B -m pytest -q -p no:cacheprovider)

# b) Exactly what Lightwell changed, comparing the installed packages:
(cd /home/jlapthor/git/lightwell-mirror/demo/build/before/lib/python3.12/site-packages && diff -rq -x __pycache__ jinja2 /home/jlapthor/git/lightwell-mirror/demo/build/after/lib/python3.12/site-packages/jinja2)

diff -u /home/jlapthor/git/lightwell-mirror/demo/build/before/lib/python3.12/site-packages/jinja2/filters.py /home/jlapthor/git/lightwell-mirror/demo/build/after/lib/python3.12/site-packages/jinja2/filters.py

# c) Provenance from the SBOM that ships inside the wheel:
/home/jlapthor/git/lightwell-mirror/demo/build/after/bin/python - /home/jlapthor/git/lightwell-mirror/demo/build/after/lib/python3.12/site-packages <<'EOF'
import json, pathlib, sys
sbom = next(pathlib.Path(sys.argv[1]).glob("jinja2-*.dist-info/sboms/*.spdx.json"))
doc = json.loads(sbom.read_text())
pkgs = {p["SPDXID"]: p for p in doc["packages"]}
print(f"{sbom.name}: created {doc['creationInfo']['created']} by "
      f"{', '.join(doc['creationInfo']['creators'])}")
for rel in doc["relationships"]:
    if rel["relationshipType"] == "GENERATED_FROM":
        a, b = pkgs[rel["spdxElementId"]], pkgs[rel["relatedSpdxElement"]]
        purl = lambda p: p["externalRefs"][0]["referenceLocator"].split("?")[0]
        print(f"{purl(a)} (supplier: {a['supplier']})\n  GENERATED_FROM {purl(b)}")
EOF

# d) Re-scan the patched build. A plain version-based scan still flags it:
uvx -q pip-audit -s osv --path /home/jlapthor/git/lightwell-mirror/demo/build/after/lib/python3.12/site-packages

# The Lightwell-aware check reads the RHLW advisory (expect FIXED, exit 0):
uvx -q pip-audit -s osv -f json -o /home/jlapthor/git/lightwell-mirror/demo/build/after-audit.json --path /home/jlapthor/git/lightwell-mirror/demo/build/after/lib/python3.12/site-packages

python3 -I /home/jlapthor/git/lightwell-mirror/demo/lightwell_audit.py /home/jlapthor/git/lightwell-mirror/demo/build/after-audit.json

# --- 5. Run the remediated app -----------------------------------------------
# Start it in the background:
(cd /home/jlapthor/git/lightwell-mirror/demo/app && exec /home/jlapthor/git/lightwell-mirror/demo/build/after/bin/flask --app app run --port 5055 > /home/jlapthor/git/lightwell-mirror/demo/build/flask.log 2>&1) &

# Wait until it answers:
until curl -fsS -o /dev/null http://127.0.0.1:5055/healthz 2>/dev/null; do sleep 0.3; done

curl -sS http://127.0.0.1:5055/healthz; echo

curl -sS -H 'Content-Type: application/json' http://127.0.0.1:5055/preview -d '{"template": "Hi {{ customer.name }}, your order {{ order.id }} has shipped."}'; echo

# Stop the app:
kill %1
