#!/usr/bin/env python3
"""Reconcile pip-audit findings with Red Hat Lightwell's OSV advisories.

Version-based scanners query the "PyPI" OSV ecosystem, so they can't see
Lightwell's backported fixes: a patched build such as jinja2 3.1.5+rhlw.1 is
still reported as vulnerable. Lightwell publishes OSV records (RHLW-*) under
the "Red Hat Lightwell:PyPI" ecosystem that list the upstream CVEs each
patched build fixes. This script matches the two:

  * finding on a +rhlw build whose CVE an RHLW record marks fixed at or below
    the installed version  ->  "fixed by Lightwell" (with the RHLW id)
  * finding on an upstream build that Lightwell has a fix for
    ->  "vulnerable", plus which Lightwell build to install
  * anything else  ->  "vulnerable"

Usage:
  pip-audit -s osv -f json -o audit.json --path <site-packages>
  lightwell_audit.py audit.json                     # look up RHLW records on osv.dev
  lightwell_audit.py audit.json --osv-dir <dir>     # offline: a lightwell-osv checkout

Exits 1 if any finding is not fixed. Standard library only.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys
import urllib.request

ECOSYSTEM = "Red Hat Lightwell:PyPI"
OSV_QUERY = "https://api.osv.dev/v1/query"
RHLW_VERSION = re.compile(r"^(?P<base>.+)\+rhlw\.(?P<n>\d+)$")


def norm(name: str) -> str:
    return re.sub(r"[-_.]+", "-", name).lower()


def split_rhlw(version: str) -> tuple[str, int | None]:
    m = RHLW_VERSION.match(version)
    return (m["base"], int(m["n"])) if m else (version, None)


class Advisories:
    """RHLW records for a (package, upstream base version)."""

    def __init__(self, osv_dir: pathlib.Path | None):
        self.local: list[dict] | None = None
        if osv_dir:
            self.local = [json.loads(p.read_text())
                          for p in sorted(osv_dir.rglob("RHLW-*.json"))]
        self.cache: dict[tuple[str, str], list[dict]] = {}

    def for_package(self, name: str, base: str) -> list[dict]:
        key = (norm(name), base)
        if key not in self.cache:
            self.cache[key] = (self._from_local(*key) if self.local is not None
                               else self._from_osv_dev(*key))
        return self.cache[key]

    def _from_local(self, name: str, base: str) -> list[dict]:
        return [rec for rec in self.local
                if any(a["package"]["ecosystem"] == ECOSYSTEM
                       and norm(a["package"]["name"]) == name
                       and base in a.get("versions", [])
                       for a in rec.get("affected", []))]

    @staticmethod
    def _from_osv_dev(name: str, base: str) -> list[dict]:
        body = json.dumps({"package": {"ecosystem": ECOSYSTEM, "name": name},
                           "version": base}).encode()
        req = urllib.request.Request(OSV_QUERY, data=body,
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.load(r).get("vulns", [])


def fixes(record: dict, name: str) -> list[str]:
    """Remediated versions a record gives for this package."""
    out = []
    for a in record.get("affected", []):
        if a["package"]["ecosystem"] != ECOSYSTEM or norm(a["package"]["name"]) != norm(name):
            continue
        lw = a.get("database_specific", {}).get("lightwell", {})
        if lw.get("remediated_version"):
            out.append(lw["remediated_version"])
        out += [e["fixed"] for r in a.get("ranges", []) for e in r["events"] if "fixed" in e]
    return sorted(set(out))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("audit_json", type=pathlib.Path, help="pip-audit -f json output")
    ap.add_argument("--osv-dir", type=pathlib.Path,
                    help="local lightwell-osv checkout instead of querying osv.dev")
    args = ap.parse_args()

    audit = json.loads(args.audit_json.read_text())
    if not audit.get("dependencies"):
        # pip-audit pointed at a wrong --path scans nothing and reports clean.
        print(f"error: {args.audit_json} lists no packages; was pip-audit given "
              "the right --path?", file=sys.stderr)
        return 2
    advisories = Advisories(args.osv_dir)
    rows, open_findings, seen = [], 0, set()

    for dep in audit.get("dependencies", []):
        name, version = dep["name"], dep.get("version", "")
        base, rhlw_n = split_rhlw(version)
        for vuln in dep.get("vulns", []):
            ids = {vuln["id"], *vuln.get("aliases", [])}
            if (name, frozenset(ids)) in seen:     # pip-audit can list one vuln twice
                continue
            seen.add((name, frozenset(ids)))
            cve = sorted(i for i in ids if i.startswith("CVE-")) or [vuln["id"]]

            status, note = "VULNERABLE", f"upstream fix: {', '.join(vuln.get('fix_versions') or ['none'])}"
            for rec in advisories.for_package(name, base):
                if not ids & set(rec.get("upstream", []) + rec.get("aliases", [])):
                    continue
                fixed = fixes(rec, name)
                if rhlw_n is not None and any(
                        split_rhlw(f)[0] == base and (split_rhlw(f)[1] or 0) <= rhlw_n
                        for f in fixed):
                    status, note = "FIXED", f"by Lightwell ({rec['id']})"
                    break
                if fixed:
                    note += f"; Lightwell fix: {', '.join(fixed)} ({rec['id']})"
            open_findings += status != "FIXED"
            rows.append((name, version, cve[0], status, note))

    if not rows:
        print("No findings.")
        return 0
    widths = [max(len(str(r[i])) for r in rows + [("Package", "Version", "Vulnerability", "Status", "")])
              for i in range(4)]
    header = ("Package", "Version", "Vulnerability", "Status", "Details")
    for r in [header] + rows:
        print("  ".join(str(c).ljust(w) for c, w in zip(r[:4], widths)) + "  " + r[4])
    print(f"\n{open_findings} open, {len(rows) - open_findings} fixed by Lightwell "
          f"(source: {args.osv_dir or 'osv.dev'})")
    return 1 if open_findings else 0


if __name__ == "__main__":
    sys.exit(main())
