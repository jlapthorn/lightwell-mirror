# Lightwell + Renovate demo, one command at a time. Run every command from the
# root of the repo (~/git/lightwell-mirror). Not meant to be run as a script.

# --- Start over (skip on the very first run) ---------------------------------

# Reset the Gitea repo to its starting state and delete the scratch builds.
./renovate-demo/setup-gitea.sh --reset && rm -rf renovate-demo/build

# --- 1. Start the services ----------------------------------------------------

# Start Nexus (the offline package server) and Gitea (the offline git server) in the background.
podman compose up -d

# Check both are answering (Nexus takes a minute or two; ignore its "unhealthy" status label).
curl -fsS -o /dev/null http://localhost:8081/repository/pypi-lightwell/simple/ && echo "Nexus OK"; curl -fsS -o /dev/null http://localhost:3000/api/healthz && echo "Gitea OK"

# --- 2. Set up Gitea ----------------------------------------------------------

# Create the gitea-admin and renovate-bot users, the bot's token and the demo repo (safe to re-run).
./renovate-demo/setup-gitea.sh

# Show the gitea-admin password, for logging in at http://localhost:3000.
grep GITEA_ADMIN_PASSWORD .env

# --- 3. The app as it is today ------------------------------------------------

# Clone the app from Gitea, as a developer would.
git clone http://localhost:3000/demo/lightwell-python-demo-app.git renovate-demo/build/app

# Show the pins: Jinja2 is held at the certified version 3.1.5.
cat renovate-demo/build/app/requirements.txt

# Build the app the way production does today, from public PyPI.
uv venv -q --seed --python 3.12 renovate-demo/build/before && PIP_CONFIG_FILE=/dev/null renovate-demo/build/before/bin/pip install -q --index-url https://pypi.org/simple/ -r renovate-demo/build/app/requirements.txt

# Confirm the plain upstream jinja2 3.1.5 is installed.
renovate-demo/build/before/bin/python -c 'import jinja2; print("jinja2", jinja2.__version__)'

# --- 4. The security scan finds the CVE ---------------------------------------

# Scan the installed packages: pip-audit reports CVE-2025-27516 in jinja2 3.1.5 (fix: 3.1.6).
uvx -q pip-audit -s osv --desc on --path renovate-demo/build/before/lib/python3.12/site-packages

# Check the finding against Lightwell's advisories: Lightwell has a fix for 3.1.5, called 3.1.5+rhlw.1.
uvx -q pip-audit -s osv -f json -o renovate-demo/build/before-audit.json --path renovate-demo/build/before/lib/python3.12/site-packages; python3 -I demo/lightwell_audit.py renovate-demo/build/before-audit.json

# Run the tests: the CVE regression test fails (1 failed, 3 passed).
(cd renovate-demo/build/app && ../before/bin/python -m pytest -q -p no:cacheprovider)

# --- 5. Renovate proposes the Lightwell fix -----------------------------------

# Show the Renovate config: it only allows +rhlw rebuilds of the pinned version, looked up on Nexus.
cat renovate-demo/build/app/renovate.json

# Run Renovate once: it opens PR #1 "Update dependency jinja2 to 3.1.5+rhlw.1 (Red Hat Lightwell)".
./renovate-demo/run-renovate.sh

# Review the PR in the browser: title, labels, Lightwell note, one-line diff (also see Issues > Dependency Dashboard).
xdg-open http://localhost:3000/demo/lightwell-python-demo-app/pulls/1

# --- 6. Merge the PR ----------------------------------------------------------

# In the browser, log in as gitea-admin and click "Create merge commit" on the PR. Then pull main:
git -C renovate-demo/build/app pull --ff-only && grep '^jinja2' renovate-demo/build/app/requirements.txt

# --- 7. Rebuild from the offline Nexus and verify -----------------------------

# Show pip.conf: it points pip at the Nexus group pypi-lightwell (Lightwell builds first).
cat renovate-demo/build/app/pip.conf

# Rebuild with Nexus as the only package source; jinja2 3.1.5+rhlw.1 is installed.
uv venv -q --seed --python 3.12 renovate-demo/build/after && (cd renovate-demo/build/app && PIP_CONFIG_FILE=pip.conf ../after/bin/pip install -q -r requirements.txt) && renovate-demo/build/after/bin/python -c 'import jinja2; print("jinja2", jinja2.__version__)'

# Run the same, unchanged tests: all 4 pass.
(cd renovate-demo/build/app && ../after/bin/python -m pytest -q -p no:cacheprovider)

# --- 8. Proof and the security gate -------------------------------------------

# Show that filters.py is the only file Lightwell changed in Jinja2.
diff -rq -x __pycache__ renovate-demo/build/before/lib/python3.12/site-packages/jinja2 renovate-demo/build/after/lib/python3.12/site-packages/jinja2

# Show the change itself: the upstream 3.1.6 fix for the |attr filter, backported to 3.1.5.
diff -u renovate-demo/build/before/lib/python3.12/site-packages/jinja2/filters.py renovate-demo/build/after/lib/python3.12/site-packages/jinja2/filters.py

# The security gate: the Lightwell-aware check marks the CVE FIXED and exits 0, so CI passes.
uvx -q pip-audit -s osv -f json -o renovate-demo/build/after-audit.json --path renovate-demo/build/after/lib/python3.12/site-packages; python3 -I demo/lightwell_audit.py renovate-demo/build/after-audit.json; echo "exit code: $?"

# Run Renovate again: no new PR, because main is on the latest Lightwell build (it opens one when +rhlw.2 ships).
./renovate-demo/run-renovate.sh 2>&1 | grep -E 'PR created|Branch created|Repository finished'

# --- Shut down (optional) -----------------------------------------------------

# Stop and remove the containers and network; the data volumes are kept.
podman compose down
