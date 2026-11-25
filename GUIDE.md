# Lightwell + Renovate Python demo: step-by-step guide

This guide takes you from a fresh Linux machine to a running demonstration of
Red Hat Lightwell fixing a security vulnerability in a Python application,
with Renovate proposing the fix as a pull request.
It assumes you know Linux well (shell, podman, systemd, curl). It assumes no
Python development experience; terms are explained as they come up.

**Time needed:** about 30 minutes, most of it waiting for downloads and for
Nexus to start. The demo itself takes about 10 minutes.

---

## What you're going to show

A company runs a small web application written in Python. It uses a library
called **Jinja2** (a template engine) at version **3.1.5**. A security scan
finds a published vulnerability in that version, **CVE-2025-27516**.

The usual fix is "upgrade to the next version" (3.1.6). In many organisations
that's slow: a new version has to be re-tested and re-approved.

**Red Hat Lightwell** offers another route: a rebuilt **3.1.5** with only the
security fix added, versioned `3.1.5+rhlw.1`. The demo shows that:

1. the scanner finds the vulnerability;
2. Lightwell has a fix for the exact version in use;
3. **Renovate**, a bot that keeps dependencies up to date, opens a pull
   request with the one-line change, and a person reviews and merges it;
4. the app is rebuilt from your own local package server (no internet needed
   for that part);
5. the application's tests pass, the change is tiny and auditable, and the
   fix is traceable to a published Red Hat advisory.

## How the pieces fit together

```
  packages.redhat.com (Lightwell)           pypi.org (public)
            │                                     │
            │ 1. mirror_repos.py                  │ 2. fetch_pypi_extras.sh
            ▼                                     ▼
   ┌──────────────────────── ./mirror/ ───────────────────────┐
   │ python-remediated/  python-validated/   pypi-extras/     │
   └───────────────────────────┬──────────────────────────────┘
                               │ 3. podman compose (seed job uploads)
                               ▼
              Nexus Repository on localhost:8081
              "pypi-lightwell" = remediated → validated → extras
                    │                              ▲
                    │ 5. pip install               │ 4. Renovate looks up
                    ▼                              │    Lightwell builds
   demo app repo in Gitea on localhost:3000 ◄──────┘    and opens a PR
   (renovate-demo/lightwell-python-demo-app)
```

* **Package**: a library someone else wrote that the application uses
  (Jinja2, Flask, ...). Python packages are installed with `pip` from a
  **package index**. The public one is pypi.org.
* **Wheel** (`.whl`): the file format a Python package is shipped in, like an
  RPM.
* **Nexus Repository**: a package server you run yourself. Here it acts as a
  private, offline copy of the Lightwell repositories, a bit like a local
  dnf/yum mirror.
* **Lightwell repositories:**
  * *remediated*: patched builds of old versions (e.g. `jinja2 3.1.5+rhlw.1`).
    Needs a Red Hat service account.
  * *validated*: vetted, unmodified builds of current versions. The public
    demo set needs no login.
* **Extras**: libraries that Lightwell's packages depend on but Lightwell
  doesn't ship (e.g. Jinja2 needs MarkupSafe). We copy these from pypi.org so
  everything installs offline.
* **pypi-lightwell** is a *group* in Nexus: one URL that searches remediated
  first, then validated, then extras. A Lightwell build always wins.
* **Gitea**: a small git server, like a self-hosted GitHub. It holds the demo
  app's repository and the pull request.
* **Renovate**: a bot that reads a project's dependency pins, looks for newer
  versions, and opens pull requests. Here it's configured to propose only
  Lightwell rebuilds of the version already pinned. It runs as a container
  when you call it.

---

## Step 0: Prerequisites

Tested on Fedora 44. Other distributions work with the equivalent packages.

```bash
sudo dnf install -y git podman podman-compose uv python3-pip curl
```

| Tool | Why |
|---|---|
| `podman`, `podman-compose` | run Nexus, Gitea and Renovate in containers |
| `uv` | gives the demo its own Python 3.12 and runs the security scanner, without touching the system Python |
| `python3-pip` | used by `fetch_pypi_extras.sh` to download the extras |
| `git`, `curl` | fetch this repo; check things are working |

You also need:

* **Internet access** for steps 2–3 (downloads) and for parts of the demo.
* **Port 8081** free (Nexus) and **port 3000** free (Gitea).
* **About 4 GB of RAM** for Nexus and about 2 GB of disk.
* **A Lightwell service account** (username and token) for the remediated
  repository. Your Red Hat contact provides it.

Check podman works for your user:

```bash
podman run --rm registry.access.redhat.com/ubi9/ubi-minimal echo ok
```

## Step 1: Get the project

```bash
git clone git@github.com:jlapthorn/lightwell-mirror.git
cd lightwell-mirror
git checkout lightwell-python-demo     # until it's merged into main
```

All commands from here on are run from this `lightwell-mirror` directory.

## Step 2: Store your Lightwell credentials

The credentials go in a file in your home directory that only you can read.
They are never stored in the project folder.

```bash
read -rp  'Lightwell username: ' LW_USER
read -rsp 'Lightwell token: '    LW_PASS; echo
umask 077
printf 'export MIRROR_USERNAME=%q\nexport MIRROR_PASSWORD=%q\n' "$LW_USER" "$LW_PASS" > ~/.lightwell-creds
umask 022
unset LW_USER LW_PASS
ls -l ~/.lightwell-creds        # should show -rw-------
```

Usernames often contain a `|` character (e.g. `1234567|jsmith`). The `%q`
above quotes it safely.

Load them into your current shell whenever you need them:

```bash
source ~/.lightwell-creds
```

## Step 3: Configure and download (mirror) the Python repositories

Create the configuration from the example. It already has the right
Lightwell URLs and only downloads `jinja2` from the large remediated
repository:

```bash
cp repos.example.toml repos.toml
```

Download the two Python repositories (skip the Java ones):

```bash
source ~/.lightwell-creds
./mirror_repos.py -c repos.toml -r python-remediated -r python-validated
```

Expected result (takes under a minute):

```
[python-validated] public repo, connecting anonymously
[python-validated] 10/10  downloaded=10 skipped=0 failed=0  11.2 MiB
[python-validated] complete: mirror/python-validated
[python-remediated] 4/4  downloaded=4 skipped=0 failed=0  739.4 KiB
[python-remediated] complete: mirror/python-remediated
```

* `HTTP Error 401: Unauthorized` on python-remediated means the credentials
  are wrong or weren't loaded. Re-run `source ~/.lightwell-creds`.
* It's safe to re-run: files already downloaded are skipped.

## Step 4: Download the extras (dependencies)

```bash
./fetch_pypi_extras.sh
```

This works out every library the Lightwell packages need, downloads them from
pypi.org, then deletes anything Lightwell already provides. It ends with
something like:

```
Lightwell provides: boto3, certifi, cryptography, flask, jinja2, pillow, ...
25 extra files in mirror/pypi-extras:
  blinker-1.9.0-py3-none-any.whl
  ...
  markupsafe-3.0.4-cp312-cp312-manylinux2014_x86_64....whl
  ...
```

The files are built for **Python 3.12 on x86_64 Linux**, matching what
Lightwell builds for.

At this point `ls mirror/` should show `_manifests`, `pypi-extras`,
`python-remediated` and `python-validated`.

## Step 5: Start Nexus and Gitea, and load the packages

Download the three container images:

```bash
podman pull docker.io/sonatype/nexus3:3.98.1-alpine docker.io/gitea/gitea:28.4.0-rootless docker.io/renovate/renovate:44.257.3
```

Create the settings file with admin passwords for Nexus and Gitea. Anonymous
read access lets `pip` and Renovate read from Nexus without a login:

```bash
cat > .env <<EOF
NEXUS_ADMIN_PASSWORD=$(head -c 18 /dev/urandom | base64 | tr -d '/+=')
GITEA_ADMIN_PASSWORD=$(head -c 18 /dev/urandom | base64 | tr -d '/+=')
NEXUS_ANONYMOUS=true
EOF
chmod 600 .env
```

Start the two servers:

```bash
podman compose up -d nexus gitea
```

* **nexus**: the package server. The first start takes **3–5 minutes**.
* **gitea**: the git server. Ready in a few seconds.

Then load the packages into Nexus:

```bash
podman compose run --rm --no-deps seed
```

The **seed** job waits until Nexus is up, creates the repositories, uploads
everything from `mirror/`, then exits. Success looks like this:

```
seed: skip java-remediated: /mirror/java-remediated not found
seed: skip java-validated: /mirror/java-validated not found
seed: created pypi hosted repo python-remediated
seed: python-remediated: done (4 files)
seed: created pypi hosted repo python-validated
seed: python-validated: done (10 files)
seed: created pypi hosted repo pypi-extras
seed: pypi-extras: done (25 files)
seed: created pypi group repo pypi-lightwell
seed: finished (exit 0)
```

The two "skip java" lines are expected, because only Python was mirrored.

> **Why not just `podman compose up -d`?** That also starts `seed`, but only
> once podman reports Nexus as *healthy*. On some hosts podman can't run
> health checks (`podman ps` shows Nexus as "unhealthy" even though it
> works), so it waits forever. Starting `seed` with `--no-deps` skips that
> wait; the job checks Nexus itself.

> **If `podman compose` says "Cannot connect to the Docker daemon"**: your
> system is using `docker-compose` as the backend, which needs the podman API
> socket. Either install `podman-compose` (step 0), or run
> `systemctl --user enable --now podman.socket` and try again.

## Step 6: Check Nexus is serving the packages

```bash
# The patched Jinja2 should be listed
curl -s http://localhost:8081/repository/pypi-lightwell/simple/jinja2/ | grep -o 'jinja2-[^"<#]*\.whl' | sort -u
```

Expected:

```
jinja2-3.1.4+rhlw.1-1-py3-none-any.whl     <- Lightwell remediated (older line)
jinja2-3.1.5+rhlw.1-1-py3-none-any.whl     <- Lightwell remediated (used in the demo)
jinja2-3.1.6-0-py3-none-any.whl            <- Lightwell validated (current release)
```

You can also browse it in a web browser at **http://localhost:8081**. Log in
as `admin` with the password from `grep NEXUS_ADMIN_PASSWORD .env`, then go to
*Browse* → *pypi-lightwell*.

The setup is done. From here on, Nexus keeps the packages in a podman volume,
so the `mirror/` folder is no longer needed by it.

---

## Step 7: Set up Gitea

```bash
./renovate-demo/setup-gitea.sh
```

This creates:

* **gitea-admin**: you, the developer who reviews and merges. The password is
  `GITEA_ADMIN_PASSWORD` in `.env`.
* **renovate-bot**: the account Renovate uses. Its access token is saved to
  `renovate-demo/.renovate-token`, readable only by you.
* **demo/lightwell-python-demo-app**: the app repository, pushed from
  `renovate-demo/lightwell-python-demo-app/`, with `jinja2==3.1.5` pinned.

Open **http://localhost:3000/demo/lightwell-python-demo-app** in a browser and
log in as `gitea-admin` (`grep GITEA_ADMIN_PASSWORD .env`). There's one commit
and no pull requests yet.

---

## Step 8: Run the demo

Run the commands in `renovate-demo/commands.sh` from step 3 onwards, one at a
time, or let a script walk through them:

```bash
./renovate-demo/run_demo.sh
```

The script pauses after each step. Press **Enter** to continue. (To run
without pauses, for a dry run: `DEMO_PAUSE=0 ./renovate-demo/run_demo.sh`.) It
resets the Gitea repository first, so it can be run any number of times.

### What you'll see, and what to say

**1. The app as it is today**

The app is cloned from Gitea and installed into an isolated Python
environment (a *virtual environment*: a private folder with its own Python and
libraries, so nothing touches the system), from the public pypi.org, exactly
as it's configured today:

```
flask==3.1.3
jinja2==3.1.5
> Installed: jinja2 3.1.5
```

*Say:* "This is our application as it runs in production. Jinja2 is pinned at
3.1.5 because that's the version we've certified."

**2. Security scan finds a known vulnerability**

```
jinja2 3.1.5   PYSEC-2026-1471 3.1.6   Jinja2 vulnerable to sandbox breakout ...
```

`pip-audit` is a standard scanner. It checks every installed library against
the public OSV vulnerability database and suggests upgrading to 3.1.6.

Then the finding is checked against **Red Hat Lightwell's advisories**:

```
jinja2   3.1.5   CVE-2025-27516  VULNERABLE  upstream fix: 3.1.6; Lightwell fix: 3.1.5+rhlw.1 (RHLW-2026-bbcf7d39b1fbb255)
```

Finally the app's tests run, including one written for this CVE. It fails:

```
1 failed, 3 passed
```

*Say:* "The scanner's only advice is to upgrade. But Lightwell has published a
fix for the exact version we run."

**3. Renovate proposes the Lightwell fix**

Renovate's configuration lives in the app repo (`renovate.json`). It only
allows Lightwell rebuilds of the version already pinned: `3.1.5` can become
`3.1.5+rhlw.1`, but never `3.1.6`. It looks packages up on the local Nexus.
Renovate runs once and opens a pull request:

```
INFO: PR created (repository=demo/lightwell-python-demo-app, branch=renovate/jinja2-lightwell)
      "prTitle": "Update dependency jinja2 to 3.1.5+rhlw.1 (Red Hat Lightwell)",
```

Show the PR in Gitea: the `security` and `lightwell` labels, the note in the
description explaining the Lightwell rebuild, and **Files changed**:

```
-jinja2==3.1.5
+jinja2==3.1.5+rhlw.1
```

*Say:* "In real life Renovate runs on a schedule. It has proposed one line:
same version, patched build. Nobody had to go looking for the fix."

**4. Review and merge**

Click **Create merge commit** on the PR (or let the script do it).

*Say:* "A person still reviews and merges. Renovate proposes, we decide."

**5. Rebuild from Nexus and verify**

The repo's `pip.conf` points pip at the local Nexus. The merged app is rebuilt
from there, with no internet:

```
> Installed: jinja2 3.1.5+rhlw.1
```

* **a) Tests:** the same, unchanged tests now pass: `4 passed`.
* **b) What changed:** comparing the old and new Jinja2 files, only one
  function (`do_attr` in `filters.py`) changed, and it's the official upstream
  fix copied back onto 3.1.5. The only other change is the version string.
* **c) Security gate:** a plain scanner *still* reports the vulnerability. It
  only compares version numbers and doesn't know about backported fixes. The
  Lightwell-aware check reads Red Hat's published advisory and reports:

  ```
  jinja2   3.1.5+rhlw.1  CVE-2025-27516  FIXED   by Lightwell (RHLW-2026-bbcf7d39b1fbb255)
  ```

*Say:* "We can prove what changed and that it closes the CVE, and a CI
pipeline can check that automatically."

**6. Renovate keeps watching**

Renovate runs again and opens nothing new. When Lightwell publishes
`3.1.5+rhlw.2`, the next run opens a PR for it.

*Say:* "A CVE was found, Renovate proposed Lightwell's patched build of the
same version, we merged one line, and the app was fixed, without an upgrade
and without touching application code."

---

## Day-to-day operations

| Task | Command |
|---|---|
| Stop Nexus and Gitea (keeps data) | `podman compose stop` |
| Start them again | `podman compose start` (Nexus ready in about a minute) |
| Check status | `podman compose ps` |
| Nexus logs | `podman compose logs -f nexus` |
| Re-upload everything | `SEED_FORCE=1 podman compose run --rm --no-deps seed` |
| Start the demo over | `./renovate-demo/setup-gitea.sh --reset && rm -rf renovate-demo/build` |
| Run Renovate by hand | `./renovate-demo/run-renovate.sh` (`LOG_LEVEL=debug` for detail) |
| **Delete everything** (containers, stored packages *and* Gitea data) | `podman compose down -v` |

To add another Lightwell package later, add it to `projects` under
`python-remediated` in `repos.toml`, then re-run steps 3 and 4 and
`podman compose run --rm --no-deps seed`. Only new repositories are uploaded. To re-upload a
repository that's already loaded, use `SEED_FORCE=1`.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `401 Unauthorized` in step 3 | Credentials missing or wrong. `source ~/.lightwell-creds` and check the token hasn't expired. |
| Mirror listing seems to hang | Without `projects = [...]`, the full remediated index is huge and very slow. Keep the `projects` line in `repos.toml`. |
| `Cannot connect to the Docker daemon` | See the note in step 5. |
| Seed log stuck on `waiting for http://nexus:8081` | Nexus is still starting (up to 5 minutes the first time). Check `podman compose logs nexus` for errors such as running out of memory. |
| `admin login failed` in the seed log | `.env` password changed after Nexus was first set up. Use the original password, or start over with `podman compose down -v`. |
| `podman compose up -d` never finishes ("Waiting" on nexus) | Health checks can't run on this host. Ctrl-C (the containers keep running) and use the commands in step 5. |
| Nexus shows "unhealthy" in `podman ps` | Same cause, harmless. Check it with the `curl` in step 6. |
| Demo: `Nexus not reachable` | Nexus isn't running: `podman compose up -d nexus gitea`. |
| Demo: `401` from Nexus | `NEXUS_ANONYMOUS=true` is missing from `.env`. Add it and re-run the seed command. |
| Demo: `No matching distribution found for MarkupSafe` (or another library) | The extras weren't loaded. Re-run step 4, then the seed command. |
| Renovate opens no PR | The repo was already remediated. Start the demo over (see above). |
| `git clone` says the destination already exists | `rm -rf renovate-demo/build` |
| Demo: `uv is required` | `sudo dnf install uv`. |
| Demo steps 1, 2 or the final audit error or hang | They need internet access to pypi.org and osv.dev. Check proxy and firewall. |
| `Address already in use` | Port 8081 or 3000 is taken. Set `NEXUS_PORT=` or `GITEA_PORT=` in `.env`. |

## Taking it to an air-gapped site (optional)

On the connected machine, after steps 3–4:

```bash
podman save -o images.tar docker.io/sonatype/nexus3:3.98.1-alpine \
    docker.io/gitea/gitea:28.4.0-rootless docker.io/renovate/renovate:44.257.3
git clone https://github.com/project-lightwell/lightwell-osv   # Lightwell's advisories
tar -cf lightwell-mirror.tar mirror compose.yaml seed nexus.env.example renovate-demo lightwell-osv
```

Copy both files across, then on the offline machine:

```bash
podman load -i images.tar
tar -xf lightwell-mirror.tar
# then step 5 onwards (skip the podman pull)
```

Renovate needs nothing from the internet: it only talks to Gitea and Nexus.
On a fully offline machine, demo steps 1, 2 and the final audit can't reach
pypi.org or osv.dev, and `uv` can't download Python 3.12 or the scanner the
first time. Run the demo on a connected laptop that can reach the offline Nexus,
or point the Lightwell check at the local advisories with
`LIGHTWELL_OSV_DIR=./lightwell-osv`.
