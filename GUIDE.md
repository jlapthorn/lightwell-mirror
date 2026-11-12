# Lightwell Python demo: step-by-step guide

This guide takes you from a fresh Linux machine to a running demonstration of
Red Hat Lightwell fixing a security vulnerability in a Python application.
It assumes you know Linux well (shell, podman, systemd, curl). It assumes no
Python development experience; terms are explained as they come up.

**Time needed:** about 30 minutes, most of it waiting for downloads and for
Nexus to start.

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
3. switching to it is a one-line change, installed from your own local
   package server (no internet needed for that part);
4. the application's tests pass, the change is tiny and auditable, and the
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
                               │
                               │ 4. pip install
                               ▼
                     demo application (demo/)
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

---

## Step 0: Prerequisites

Tested on Fedora 44. Other distributions work with the equivalent packages.

```bash
sudo dnf install -y git podman podman-compose uv python3-pip curl
```

| Tool | Why |
|---|---|
| `podman`, `podman-compose` | run Nexus in containers |
| `uv` | gives the demo its own Python 3.12 and runs the security scanner, without touching the system Python |
| `python3-pip` | used by `fetch_pypi_extras.sh` to download the extras |
| `git`, `curl` | fetch this repo; check things are working |

You also need:

* **Internet access** for steps 2–3 (downloads) and for parts of the demo.
* **Port 8081** free (Nexus) and **port 5055** free (the demo app).
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

## Step 5: Start Nexus and load the packages into it

Create the settings file with an admin password of your choice. Anonymous
read access lets `pip` install without a login:

```bash
cat > .env <<EOF
NEXUS_ADMIN_PASSWORD=$(head -c 18 /dev/urandom | base64 | tr -d '/+=')
NEXUS_ANONYMOUS=true
EOF
chmod 600 .env
```

Start everything:

```bash
podman compose up -d
```

This starts two containers:

* **nexus**: the package server. The first start takes **3–5 minutes**.
* **seed**: waits until Nexus is healthy, creates the repositories, uploads
  everything from `mirror/`, then exits.

Follow the seed job:

```bash
podman compose logs -f seed
```

Success looks like this (Ctrl-C to stop following):

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

## Step 7: Run the demo

```bash
./demo/run_demo.sh
```

The script pauses after each step. Press **Enter** to continue. (To run
without pauses, for a dry run: `DEMO_PAUSE=0 ./demo/run_demo.sh`.)

It creates everything it needs under `demo/build/` and removes the previous
run's files each time it starts, so it can be run any number of times.

### What you'll see, and what to say

**Step 1: Build the app as it is today**

The script creates an isolated Python environment (a *virtual environment*:
a private folder with its own Python and libraries, so nothing touches the
system) and installs the app's libraries from the public pypi.org, exactly
as the app is configured today:

```
flask==3.1.3
jinja2==3.1.5
> Installed: jinja2 3.1.5
```

*Say:* "This is our application as it runs in production. Jinja2 is pinned at
3.1.5 because that's the version we've certified."

**Step 2: Security scan finds a known vulnerability**

```
jinja2 3.1.5   PYSEC-2026-1471 3.1.6   Jinja2 vulnerable to sandbox breakout ...
```

`pip-audit` is a standard scanner. It checks every installed library against
the public OSV vulnerability database and suggests upgrading to 3.1.6.

Then the script checks the finding against **Red Hat Lightwell's advisories**:

```
jinja2   3.1.5   CVE-2025-27516  VULNERABLE  upstream fix: 3.1.6; Lightwell fix: 3.1.5+rhlw.1 (RHLW-2026-bbcf7d39b1fbb255)
```

Finally the app's tests run, including one written for this CVE. It fails:

```
1 failed, 3 passed
=> vulnerable: the sandbox regression test fails on jinja2 3.1.5
```

*Say:* "The scanner's only advice is to upgrade. But Lightwell has published a
fix for the exact version we run."

**Step 3: Remediate with Lightwell**

```
-jinja2==3.1.5
+jinja2==3.1.5+rhlw.1
$ pip install --index-url http://localhost:8081/repository/pypi-lightwell/simple/ ...
> Installed: jinja2 3.1.5+rhlw.1
```

*Say:* "That is the whole change: one line, and pointing at our own package
server. This install never touched the internet."

**Step 4: Verify the fix**

* **a) Tests:** the same, unchanged tests now pass: `4 passed`.
* **b) What changed:** the script compares the old and new Jinja2 files. Only
  one function (`do_attr` in `filters.py`) changed, and it's the official
  upstream fix copied back onto 3.1.5.
* **c) Provenance:** the package carries an **SBOM** (Software Bill of
  Materials, a machine-readable label) stating Red Hat built it from upstream
  `jinja2 3.1.5`.
* **d) Re-scan:** the plain scanner *still* reports the vulnerability. It only
  compares version numbers and doesn't know about backported fixes. The
  Lightwell-aware check reads Red Hat's published advisory and reports:

  ```
  jinja2   3.1.5+rhlw.1  CVE-2025-27516  FIXED   by Lightwell (RHLW-2026-bbcf7d39b1fbb255)
  => security gate passes
  ```

*Say:* "We can prove what changed, who built it, and that it closes the CVE,
and a CI pipeline can check that automatically."

**Step 5: Run the remediated app**

The app is started briefly and called with `curl`, showing it runs on the
patched library:

```
{"jinja2":"3.1.5+rhlw.1","status":"ok"}
{"body":"Hi Ada Lovelace, your order A-1042 has shipped."}
```

---

## Day-to-day operations

| Task | Command |
|---|---|
| Stop Nexus (keeps data) | `podman compose stop` |
| Start it again | `podman compose start` (ready in about a minute) |
| Check status | `podman compose ps` |
| Nexus logs | `podman compose logs -f nexus` |
| Re-upload everything | `SEED_FORCE=1 podman compose up seed` |
| **Delete everything** (containers *and* stored packages) | `podman compose down -v` |
| Remove demo build output | `rm -rf demo/build` |

To add another Lightwell package later, add it to `projects` under
`python-remediated` in `repos.toml`, then re-run steps 3 and 4 and
`podman compose up seed`. Only new repositories are uploaded. To re-upload a
repository that's already loaded, use `SEED_FORCE=1`.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `401 Unauthorized` in step 3 | Credentials missing or wrong. `source ~/.lightwell-creds` and check the token hasn't expired. |
| Mirror listing seems to hang | Without `projects = [...]`, the full remediated index is huge and very slow. Keep the `projects` line in `repos.toml`. |
| `Cannot connect to the Docker daemon` | See the note in step 5. |
| Seed log stuck on `waiting for http://nexus:8081` | Nexus is still starting (up to 5 minutes the first time). Check `podman compose logs nexus` for errors such as running out of memory. |
| `admin login failed` in the seed log | `.env` password changed after Nexus was first set up. Use the original password, or start over with `podman compose down -v`. |
| Demo: `Nexus not reachable` | Nexus isn't running: `podman compose up -d`. |
| Demo: `No matching distribution found for MarkupSafe` (or another library) | The extras weren't loaded. Re-run step 4, then `podman compose up seed`. |
| Demo: `uv is required` | `sudo dnf install uv`. |
| Demo step 2 or 4d errors or hangs | They need internet access to pypi.org and osv.dev. Check proxy and firewall. |
| `Address already in use` | Port 8081 or 5055 is taken. Set `NEXUS_PORT=` in `.env`, or `PORT=5056 ./demo/run_demo.sh`. |

## Taking it to an air-gapped site (optional)

On the connected machine, after steps 3–4:

```bash
podman save -o nexus3.tar docker.io/sonatype/nexus3:3.98.1-alpine
git clone https://github.com/project-lightwell/lightwell-osv   # Lightwell's advisories
tar -cf lightwell-mirror.tar mirror compose.yaml seed nexus.env.example demo lightwell-osv
```

Copy both files across, then on the offline machine:

```bash
podman load -i nexus3.tar
tar -xf lightwell-mirror.tar
# then step 5 onwards
```

On a fully offline machine, demo steps 1, 2 and 4d can't reach pypi.org or
osv.dev, and `uv` can't download Python 3.12 or the scanner the first time. Run the demo on a connected laptop that can reach the offline Nexus,
or point the Lightwell check at the local advisories with
`LIGHTWELL_OSV_DIR=./lightwell-osv`.
