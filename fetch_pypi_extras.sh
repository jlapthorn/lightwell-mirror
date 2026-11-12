#!/bin/sh
# Download the dependencies of the mirrored Lightwell Python packages that
# Lightwell doesn't ship itself (MarkupSafe for Jinja2, Werkzeug for Flask,
# ...) from public PyPI into $MIRROR_DIR/pypi-extras/. The seed container
# loads that folder as the last member of the pypi-lightwell group, so a
# Lightwell build always wins over a PyPI one.
#
#   ./fetch_pypi_extras.sh [requirements-file]     (default: pypi-extras.txt)
#
# Run on the online host after mirror_repos.py. Wheels are selected for the
# target platform, not this machine: Lightwell builds for CPython 3.12 on
# manylinux x86_64. Override with PY_VERSION / PLATFORMS.
set -eu

MIRROR=${MIRROR_DIR:-./mirror}
OUT=$MIRROR/pypi-extras
REQ=${1:-pypi-extras.txt}
PY_VERSION=${PY_VERSION:-3.12}
PLATFORMS=${PLATFORMS:-manylinux_2_28_x86_64 manylinux_2_17_x86_64 manylinux2014_x86_64}
INDEX=${PYPI_INDEX:-https://pypi.org/simple}

# Resolve against the mirrored Lightwell files too, so the exact Lightwell
# versions pinned in $REQ (e.g. requests 2.34.0.dev1) can be found.
find_links=$(find "$MIRROR"/python-* -type f \( -name '*.whl' -o -name '*.tar.gz' \) \
    -exec dirname {} \; 2>/dev/null | sort -u | sed 's/^/--find-links=/')
[ -n "$find_links" ] || { echo "no Lightwell Python files under $MIRROR/python-*; run mirror_repos.py first" >&2; exit 1; }
platform_args=$(for p in $PLATFORMS; do printf -- '--platform=%s ' "$p"; done)

rm -rf "$OUT"
mkdir -p "$OUT"
# shellcheck disable=SC2086  # word splitting of the arg lists is intended
python3 -m pip download --disable-pip-version-check \
    --dest "$OUT" --index-url "$INDEX" $find_links \
    --only-binary=:all: --python-version "$PY_VERSION" --implementation cp \
    $platform_args -r "$REQ"

# Drop every project Lightwell ships (pip copies them in from --find-links,
# or fetched the PyPI build), leaving only the gaps.
python3 -I - "$MIRROR" "$OUT" <<'EOF'
import pathlib, re, sys

def project(filename):
    return re.sub(r"[-_.]+", "-", filename.split("-", 1)[0]).lower()

mirror, out = map(pathlib.Path, sys.argv[1:])
lightwell = {project(f.name) for d in mirror.glob("python-*")
             for f in d.rglob("*") if f.suffix in (".whl", ".gz", ".zip")}
kept = []
for f in sorted(out.iterdir()):
    if project(f.name) in lightwell:
        f.unlink()
    else:
        kept.append(f.name)
print(f"\nLightwell provides: {', '.join(sorted(lightwell))}")
print(f"{len(kept)} extra files in {out}:")
for name in kept:
    print(f"  {name}")
EOF
