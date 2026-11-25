# Demo: Lightwell remediation through a Renovate PR (offline)

The same Flask/Jinja2 app as `../demo/`, but the fix arrives the way it would
in a real team. A scanner finds CVE-2025-27516, **Renovate opens a pull
request** that moves `jinja2==3.1.5` to Lightwell's `3.1.5+rhlw.1`, someone
merges it, and the app is rebuilt from the offline Nexus. Everything runs
locally: Nexus serves the packages, and Gitea hosts the repo and the PR.

```
  Gitea (:3000)                     Renovate container               Nexus (:8081)
  demo/lightwell-python-demo-app <- reads renovate.json, opens PR -> pypi-lightwell
        |                                                            ^
        +-- merged main --> pip install (pip.conf) ------------------+
```

| Path | Purpose |
|---|---|
| `lightwell-python-demo-app/` | The app repo that gets pushed to Gitea (see its README) |
| `setup-gitea.sh` | Creates the Gitea users, the Renovate token and the repo. `--reset` starts over |
| `run-renovate.sh` | One Renovate run against the repo (the Java demo's scheduled Action) |
| `run_demo.sh` | The guided walkthrough |
| `commands.sh` | The same walkthrough as individual commands, each with a one-line explanation, for running by hand |
| `VIDEO_SCRIPT.md` | Shot-by-shot script for recording the demo: commands, what to show, what to say |
| `video-shell.sh`, `video-history.txt` | Load the video's commands into a terminal's history, to step through them with Ctrl+O |

## Setup

From a blank machine, steps 0 and 1 of [`commands.sh`](commands.sh) download
the two Lightwell Python repos and their dependencies into `./mirror`, pull
the images, write `.env`, and load Nexus. In short:

```bash
source ~/.lightwell-creds
cp repos.example.toml repos.toml
./mirror_repos.py -c repos.toml -r python-remediated -r python-validated
./fetch_pypi_extras.sh
# .env: NEXUS_ADMIN_PASSWORD, GITEA_ADMIN_PASSWORD and NEXUS_ANONYMOUS=true
podman compose up -d nexus gitea
podman compose run --rm --no-deps seed   # load ./mirror into Nexus
./renovate-demo/setup-gitea.sh
```

`NEXUS_ANONYMOUS=true` matters: pip, Renovate and `git clone` all read from
Nexus and Gitea without logging in. `seed` is run by hand with `--no-deps`
because `podman compose up -d` makes it wait for Nexus to report healthy,
which never happens on hosts where podman can't run health checks. `seed.sh`
waits for Nexus on its own.

`setup-gitea.sh` creates:

* `gitea-admin`, the admin you log in as, with `GITEA_ADMIN_PASSWORD`;
* `renovate-bot`, with write access to the repo. Its API token is in
  `renovate-demo/.renovate-token` (gitignored, mode 0600);
* the org `demo` and the repo `demo/lightwell-python-demo-app`, with the
  labels `security` and `lightwell`.

It's safe to re-run. Gitea's CLI runs in a throwaway container that shares
the `gitea` volumes, so it doesn't need `podman exec`.

## Run the demo

```bash
./renovate-demo/run_demo.sh              # pauses between steps
DEMO_PAUSE=0 ./renovate-demo/run_demo.sh # straight through
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

Things worth showing in Gitea (http://localhost:3000, log in as `gitea-admin`):
the PR body with its Lightwell note, the one-line diff, and the **Dependency
Dashboard** issue Renovate keeps up to date.

Network access: steps 1–2 use public PyPI and api.osv.dev for the "before"
state, as in `../demo/`. Renovate itself only talks to Gitea and Nexus. Set
`LIGHTWELL_OSV_DIR` to read Lightwell's advisories from a local checkout.

## Running Renovate by hand

```bash
./renovate-demo/run-renovate.sh
LOG_LEVEL=debug ./renovate-demo/run-renovate.sh
```

It runs `renovate/renovate` with `--network host` and `RENOVATE_PLATFORM=gitea`,
and passes the bot token through the environment. It also sets the global
host rule `allowInternal` for `localhost`, which Renovate only accepts in
self-hosted config and needs in order to reach Gitea and Nexus.

## Air-gapped site

Add the two images to what you carry across:

```bash
podman save -o renovate-demo-images.tar \
    docker.io/gitea/gitea:28.4.0-rootless docker.io/renovate/renovate:44.257.3
```

`renovate.json` only extends `config:recommended`, which is built into
Renovate, so no presets are fetched from GitHub.
