#!/usr/bin/env bash
# Install bad-app's deliberately vulnerable dependencies into a local venv,
# scan them with pip-audit, then reconcile the findings with Red Hat
# Lightwell's OSV advisories to show which CVEs Lightwell has fixes for.
#
#   ./demo/bad-app/scan.sh
#   LIGHTWELL_OSV_DIR=<dir> ./demo/bad-app/scan.sh  # Lightwell records from disk
#
# Needs: uv, and internet access to pypi.org (install) and api.osv.dev
# (pip-audit always queries osv.dev; it has no offline mode).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
BUILD=$HERE/build
PY=${PY:-3.12}
OSV_DIR=${LIGHTWELL_OSV_DIR:-}
SITE=$BUILD/venv/lib/python$PY/site-packages
export PIP_CONFIG_FILE=/dev/null UV_INDEX_URL=https://pypi.org/simple

b=$(tput bold 2>/dev/null || true); r=$(tput sgr0 2>/dev/null || true)
step() { echo; echo "${b}━━━ $* ━━━${r}"; }
run()  { echo "${b}\$ $*${r}"; "$@"; }

command -v uv >/dev/null || { echo "uv is required: https://docs.astral.sh/uv/" >&2; exit 1; }
rm -rf "$BUILD"; mkdir -p "$BUILD"

step "Install bad-app's dependencies"
uv venv -q --python "$PY" "$BUILD/venv"
run uv pip install -q --python "$BUILD/venv/bin/python" -r "$HERE/requirements.txt"

step "Scan with pip-audit (OSV, PyPI ecosystem)"
run uvx -q pip-audit -s osv --path "$SITE" || true
uvx -q pip-audit -s osv -f json -o "$BUILD/audit.json" --path "$SITE" >/dev/null 2>&1 || true

step "Check the findings against Red Hat Lightwell's OSV advisories"
run python3 -I "$HERE/../lightwell_audit.py" "$BUILD/audit.json" ${OSV_DIR:+--osv-dir "$OSV_DIR"} || true
