# Demo: fixing a CVE with Lightwell, without upgrading

`run_demo.sh` walks through a realistic remediation:

1. **Build.** `app/` is a Flask service that previews customer notification
   templates written by support staff. The templates are rendered in Jinja2's
   `SandboxedEnvironment`. `requirements.txt` pins `jinja2==3.1.5`, the
   version the platform team has certified.
2. **Detect.** `pip-audit` reports **CVE-2025-27516**
   (GHSA-cpwx-vrp4-4pq7): the `|attr` filter lets a template get around the
   sandbox. Upstream's fix is 3.1.6, which would be an unplanned upgrade.
   Checking the finding against Lightwell's OSV advisories shows a backported
   fix for the version in use: `3.1.5+rhlw.1` (`RHLW-2026-bbcf7d39b1fbb255`).
   The regression test `test_attr_filter_is_sandboxed` fails.
3. **Remediate.** Change one line, `jinja2==3.1.5` to `jinja2==3.1.5+rhlw.1`,
   and install from the offline Nexus (`pypi-lightwell`) instead of PyPI.
4. **Verify.**
   * The unchanged test suite now passes.
   * Diffing the installed packages shows Lightwell changed one function,
     `do_attr` in `filters.py`. That is the upstream 3.1.6 fix backported to
     3.1.5, with nothing else changed.
   * The SPDX SBOM inside the wheel records Red Hat as supplier, and
     `pkg:pypi/jinja2@3.1.5+rhlw.1 GENERATED_FROM pkg:pypi/jinja2@3.1.5`.
   * Plain `pip-audit` still flags the patched build. The Lightwell-aware
     check marks it **FIXED by RHLW-2026-bbcf7d39b1fbb255** and exits 0, so a
     CI security gate passes.
5. **Run.** Start the remediated app and call it.

```bash
podman compose up -d            # the seeded Nexus (see ../README.md)
./demo/run_demo.sh              # pauses between steps; DEMO_PAUSE=0 to run through
```

Requires [uv](https://docs.astral.sh/uv/), which provides Python 3.12 (what
Lightwell builds for) and `pip-audit`. Steps 1–2 use public PyPI and the OSV
database to show the "before" state. The remediated build in step 3 is
installed only from the local Nexus. Build output goes to `demo/build/`.

## Talking points

* **No upgrade, no code change.** The fix lands on the version you've already
  certified, so there's no new-release regression cycle.
* **Small, auditable patch.** The diff is exactly the upstream security fix.
* **Provenance.** Every Lightwell wheel ships an SBOM that links it to the
  upstream release it was built from.
* **Lightwell publishes its fixes as OSV data.** Each remediation has an
  `RHLW-*` OSV record listing the upstream CVEs it fixes, in the
  [lightwell-osv](https://github.com/project-lightwell/lightwell-osv) repo and
  on osv.dev, under the `Red Hat Lightwell:PyPI` / `Red Hat Lightwell:Maven`
  ecosystems.
* **Standard scanners don't read those records yet.** pip-audit (and
  osv-scanner) only query the `PyPI` ecosystem. OSV still flags `3.1.5+rhlw.1`
  because it ignores the local version label. pip-audit's default PyPI service
  is worse: it skips the package as "not found on PyPI" and reports clean.
  Lightwell has asked osv.dev to add plain `PyPI`/`Maven` entries to its
  records ([google/osv.dev#6105](https://github.com/google/osv.dev/issues/6105)).
  Until then, `lightwell_audit.py` fills the gap.

## lightwell_audit.py

A standard-library-only script that reconciles `pip-audit -f json` output with
Lightwell's OSV records:

```bash
pip-audit -s osv -f json -o audit.json --path <site-packages>
demo/lightwell_audit.py audit.json                        # RHLW records from osv.dev
demo/lightwell_audit.py audit.json --osv-dir lightwell-osv  # offline copy
```

* A finding on a `+rhlw` build whose CVE an RHLW record marks fixed is
  reported as **FIXED** with the RHLW ID.
* A finding on an upstream build that Lightwell has fixed is reported as
  **VULNERABLE**, with the Lightwell version to install.
* It exits 1 if anything is still open, so it can be used as a CI gate. It
  exits 2 if the audit lists no packages, because pip-audit given a wrong
  `--path` reports clean.

For the offline side, carry the feed across with the mirror
(`git clone https://github.com/project-lightwell/lightwell-osv`) and run the
demo with `LIGHTWELL_OSV_DIR=<path>`.

## Adapting it

The remediated repo also has `jinja2==3.1.4+rhlw.1`, which covers the older
sandbox and compiler CVEs as well. To demo another package, add it to
`projects` for `python-remediated` in `../repos.toml`, re-run
`mirror_repos.py`, `fetch_pypi_extras.sh` and the seed, then swap the app and
its regression test.
