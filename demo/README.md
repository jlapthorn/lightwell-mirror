# Demo: Lightwell remediation through a Renovate PR (offline)

A Flask app pins `jinja2==3.1.5`, which has **CVE-2025-27516**. A scanner
finds it, **Renovate opens a pull request** that moves the pin to Red Hat
Lightwell's `3.1.5+rhlw.1` (the same release with the fix backported),
someone merges it, and the app is rebuilt from the offline Nexus. There's no
upgrade and no code change. Everything runs locally: Nexus serves the
packages, and Gitea hosts the repo and the PR. It's the Python counterpart of
[lightwell-java-demo-app](https://github.com/lightwell-experience/lightwell-java-demo-app).

```
  Gitea (:3000)                     Renovate container               Nexus (:8081)
  demo/lightwell-python-demo-app <- reads renovate.json, opens PR -> pypi-lightwell
        |                                                            ^
        +-- merged main --> pip install (pip.conf) ------------------+
```

For a full walkthrough from a blank machine, with what to say at each step,
see [../GUIDE.md](../GUIDE.md).

| Path | Purpose |
|---|---|
| `lightwell-python-demo-app/` | The app repo that gets pushed to Gitea: app, tests, `renovate.json`, `pip.conf` (see its README) |
| `setup-gitea.sh` | Creates the Gitea users, the Renovate token and the repo. `--reset` starts over |
| `run-renovate.sh` | One Renovate run against the repo (the Java demo's scheduled Action) |
| `run_demo.sh` | The whole demo as a guided script, pausing between steps |
| `commands.sh` | The same demo as individual commands, each with a one-line explanation |
| `lightwell_audit.py` | Reconciles pip-audit findings with Lightwell's advisories (the security gate) |
| `lib.sh` | Settings and helpers shared by the scripts |

## Setup

Steps 0 and 1 of [`commands.sh`](commands.sh) go from a blank machine to a
loaded Nexus and Gitea. In short:

```bash
source ~/.lightwell-creds
cp repos.example.toml repos.toml
./mirror_repos.py -c repos.toml -r python-remediated -r python-validated
./fetch_pypi_extras.sh
# .env: NEXUS_ADMIN_PASSWORD, GITEA_ADMIN_PASSWORD and NEXUS_ANONYMOUS=true
podman compose up -d nexus gitea
podman compose run --rm --no-deps seed   # load ./mirror into Nexus
./demo/setup-gitea.sh
```

* `NEXUS_ANONYMOUS=true` matters: pip and Renovate read from Nexus without
  logging in.
* `seed` is run by hand with `--no-deps` because `podman compose up -d` makes
  it wait for Nexus to report healthy, which never happens on hosts where
  podman can't run health checks. `seed.sh` waits for Nexus on its own.

`setup-gitea.sh` creates:

* `gitea-admin`, the admin you log in as, with `GITEA_ADMIN_PASSWORD`;
* `renovate-bot`, with write access to the repo. Its API token is in
  `demo/.renovate-token` (gitignored, mode 0600);
* the org `demo` and the public repo `demo/lightwell-python-demo-app`, with
  the labels `security` and `lightwell`.

It's safe to re-run. Gitea's CLI runs in a throwaway container that shares
the `gitea` volumes, so it doesn't need `podman exec`.

## Run the demo

By hand, one command at a time: follow [`commands.sh`](commands.sh) from step 2.
Or as a guided script:

```bash
./demo/run_demo.sh              # pauses between steps
DEMO_PAUSE=0 ./demo/run_demo.sh # straight through
```

| Step | What happens |
|---|---|
| 0 | The repo in Gitea is reset to its starting state |
| 1 | The app is built from public PyPI, as production is today: `jinja2 3.1.5` |
| 2 | pip-audit reports CVE-2025-27516; `lightwell_audit.py` shows Lightwell has `3.1.5+rhlw.1`; the regression test fails |
| 3 | Renovate opens PR #1 **Update dependency jinja2 to 3.1.5+rhlw.1 (Red Hat Lightwell)**: one line in `requirements.txt` |
| 4 | The script pauses. Open the PR in Gitea and click **Merge**, or let the script merge it |
| 5 | Main is rebuilt from Nexus only. The tests pass, the `filters.py` diff shows the backported fix, and the Lightwell-aware audit reports **FIXED** |
| 6 | Renovate runs again and opens nothing new; it will open the next PR when `+rhlw.2` ships |

To start over: `./demo/setup-gitea.sh --reset && rm -rf demo/build`.

Things worth showing in Gitea (http://localhost:3000, log in as `gitea-admin`):
the PR body with its Lightwell note, the one-line diff, and the **Dependency
Dashboard** issue Renovate keeps up to date.

Network access: steps 1–2 use public PyPI and api.osv.dev for the "before"
state. Renovate itself only talks to Gitea and Nexus.

## Talking points

* **No upgrade, no code change.** The fix lands on the version you've already
  certified, so there's no new-release regression cycle.
* **Renovate proposes, people decide.** The remediation arrives as a normal,
  reviewable PR, and Renovate keeps watching for the next rebuild.
* **Only Lightwell rebuilds, never upgrades.** `renovate.json` keeps the
  upstream version fixed: `3.1.5` → `3.1.5+rhlw.1` → `+rhlw.2`, never `3.1.6`.
* **Small, auditable patch.** The package diff is the upstream security fix
  in `filters.py`, plus the new version string in `__init__.py`.
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
demo/lightwell_audit.py audit.json                         # RHLW records from osv.dev
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
(`git clone https://github.com/project-lightwell/lightwell-osv`) and set
`LIGHTWELL_OSV_DIR=<path>` for `run_demo.sh`.

## Running Renovate by hand

```bash
./demo/run-renovate.sh
LOG_LEVEL=debug ./demo/run-renovate.sh
```

It runs `renovate/renovate` with `--network host` and `RENOVATE_PLATFORM=gitea`,
and passes the bot token through the environment. It also sets the global
host rule `allowInternal` for `localhost`, which Renovate only accepts in
self-hosted config and needs in order to reach Gitea and Nexus.

## Adapting it

The remediated repo also has `jinja2==3.1.4+rhlw.1`. To demo another package,
add it to `projects` for `python-remediated` in `repos.toml`, re-run
`mirror_repos.py`, `fetch_pypi_extras.sh` and the seed
(`SEED_FORCE=1 podman compose run --rm --no-deps seed`), then change the pin
and the regression test in `lightwell-python-demo-app/` and run
`setup-gitea.sh --reset`.
