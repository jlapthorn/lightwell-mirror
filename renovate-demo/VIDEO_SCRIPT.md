# Recording the Lightwell + Renovate demo

A shot-by-shot script for a 9–10 minute screen recording: what to type, what
to show, and what to say. The commands are the ones in `commands.sh`, a few
trimmed so the output fits on screen. Run everything from the repo root.

**The story in one line:** a scanner finds a CVE, Renovate proposes Red Hat
Lightwell's patched build of the *same* version, a person merges one line, and
the app is fixed with no upgrade and no code change.

---

## Before you record

### 1. Do the slow parts off camera

Steps 0 and 1 of `commands.sh` (download, images, `.env`, seed), then:

```bash
./renovate-demo/setup-gitea.sh
```

### 2. Rehearse once, then reset

A full rehearsal also warms the caches (uv's Python, pip-audit, the PyPI
downloads), so nothing stalls on camera. Afterwards:

```bash
./renovate-demo/setup-gitea.sh --reset && rm -rf renovate-demo/build
```

Do this reset before **every** take.

### 3. Set up the screen

* **Terminal:** font size 16–18 pt, about 110 columns × 30 rows, dark theme.
  Use a short prompt so commands don't wrap, and clear the history:
  ```bash
  cd ~/tmp/lightwell-mirror     # your clone
  export PS1='\[\e[1;32m\]$\[\e[0m\] '
  clear
  ```
* **Browser:** zoom to 125–150 %. Log into Gitea as `gitea-admin` beforehand
  (`grep GITEA_ADMIN_PASSWORD .env`), then open two tabs:
  1. http://localhost:3000/demo/lightwell-python-demo-app
  2. http://localhost:3000/demo/lightwell-python-demo-app/pulls (empty for now)
* **Desktop:** turn on Do Not Disturb, close other windows, and hide the
  bookmarks bar.
* **Commands:** keep this file open on a second monitor (or printed) and
  copy-paste the commands rather than typing them live.

### 4. Optional: step through the commands with Ctrl+O

Instead of copy-pasting, load the demo commands into the recording
terminal's history:

```bash
source renovate-demo/video-shell.sh
```

Then press **Ctrl+R**, type `#s2a`, and run each command with **Ctrl+O**
instead of Enter. Bash runs it and puts the next demo command at the prompt.
The screen clears before each command, which is shown at the top without its
label. Labels match the scenes (`#s4b` is Scene 4, second command), so
Ctrl+R `#s5b` jumps straight to the Renovate run. The commands are in
`video-history.txt`; the `clear` lines in the scenes below aren't needed in
this mode. Your normal `~/.bash_history` isn't changed. Close the terminal
when you're done.

### 5. Choose a recorder

* **OBS Studio** (`flatpak install flathub com.obsproject.Studio`). Add a
  "Screen Capture (PipeWire)" source and record at 1920×1080, 30 fps, MKV
  (remux to MP4 afterwards). You can pause between scenes.
* **GNOME's built-in recorder:** press `Print`, switch to video, and select
  the screen or an area. It's quick, but you can't pause.

Record each scene as its own clip if you like. Every scene below starts from
a clean screen (`clear`), so the clips cut together cleanly.

---

## Scene 1: The problem (≈ 45 s)

**Show:** the browser, tab 1 (the repo in Gitea). Scroll to `requirements.txt`.

> "This is a small Python service. It previews customer notification
> templates, which support staff write themselves, so it renders them in
> Jinja2's sandbox. Jinja2 is pinned to 3.1.5, the version our platform team
> has certified. Moving to a new release means another round of testing and
> change approval.
>
> Everything you'll see runs locally. There's no GitHub and no public PyPI in
> the fix path. This could be an air-gapped site."

## Scene 2: The offline setup (≈ 45 s)

**Show:** the terminal.

```bash
podman ps --format '{{.Names}}\t{{.Image}}'
```

```bash
curl -s http://localhost:8081/repository/pypi-lightwell/simple/jinja2/ | grep -o 'jinja2-[0-9][^"<#]*\.whl' | sort -u
```

> "Two services: Nexus, holding packages mirrored from Red Hat Lightwell, and
> Gitea, our git server. For Jinja2, Nexus has upstream 3.1.6, and two
> Lightwell builds, 3.1.4 and 3.1.5 '+rhlw.1'. Those are the same upstream
> releases, rebuilt by Red Hat with security fixes backported."

## Scene 3: The app as it is today (≈ 1 min)

```bash
clear
git clone -q http://localhost:3000/demo/lightwell-python-demo-app.git renovate-demo/build/app
cat renovate-demo/build/app/requirements.txt
```

```bash
uv venv -q --seed --python 3.12 renovate-demo/build/before && PIP_CONFIG_FILE=/dev/null renovate-demo/build/before/bin/pip install -q --index-url https://pypi.org/simple/ -r renovate-demo/build/app/requirements.txt
renovate-demo/build/before/bin/python -c 'import jinja2; print("jinja2", jinja2.__version__)'
```

> "A developer clones the repo and builds it the way production does today,
> from public PyPI. We get plain upstream Jinja2 3.1.5."

## Scene 4: The scanner finds the CVE (≈ 1 min 30 s)

```bash
clear
uvx -q pip-audit -s osv --path renovate-demo/build/before/lib/python3.12/site-packages
```

> "The security scan flags CVE-2025-27516. Jinja2's `attr` filter lets a
> template escape the sandbox, which is exactly what we rely on. Upstream's
> fix is 3.1.6, an upgrade we can't take this week."

```bash
uvx -q pip-audit -s osv -f json -o renovate-demo/build/before-audit.json --path renovate-demo/build/before/lib/python3.12/site-packages; python3 -I demo/lightwell_audit.py renovate-demo/build/before-audit.json
```

> "Red Hat Lightwell publishes its fixes as OSV advisories. Checking against
> them shows a fix for the version we're actually on: 3.1.5 plus rhlw.1."

```bash
(cd renovate-demo/build/app && ../before/bin/python -m pytest -q -p no:cacheprovider --tb=line)
```

> "The security team has added a regression test for the CVE, and it fails.
> The sandbox can be bypassed."

## Scene 5: Renovate proposes the fix (≈ 1 min 30 s)

```bash
clear
grep -E '"versioningTemplate"|"http://localhost:8081' renovate-demo/build/app/renovate.json
```

> "Renovate is configured in the repo. Two lines matter. The versioning rule
> keeps the upstream version fixed and only lets the Lightwell rebuild number
> go up. So 3.1.5 can become 3.1.5+rhlw.1, but never 3.1.6. And it looks
> packages up on our offline Nexus."

```bash
./renovate-demo/run-renovate.sh 2>&1 | grep -E 'Renovate started|(Branch|PR) created|"prTitle"|"labels"|Repository finished'
```

> "In real life Renovate runs on a schedule. Here we run it once. It's opened
> a pull request."

**Show:** the browser. Refresh tab 2, open PR #1, and point out:

* the title "Update dependency jinja2 to 3.1.5+rhlw.1 (Red Hat Lightwell)"
  and the `security` and `lightwell` labels;
* the **Red Hat Lightwell remediation** note in the body;
* **Files changed:** one line.

> "One line: 3.1.5 becomes 3.1.5+rhlw.1. Same upstream version, patched
> build. Renovate explains what it is and links to the advisories."

## Scene 6: Review and merge (≈ 45 s)

**Show:** the browser. On the PR, click **Create merge commit** and confirm
(tick "Delete branch").

> "A person still reviews and merges. Renovate proposes, we decide."

```bash
clear
git -C renovate-demo/build/app pull -q --ff-only && grep '^jinja2' renovate-demo/build/app/requirements.txt
```

## Scene 7: Rebuild from Nexus and verify (≈ 2 min)

```bash
clear
grep -v '^#' renovate-demo/build/app/pip.conf
uv venv -q --seed --python 3.12 renovate-demo/build/after && (cd renovate-demo/build/app && PIP_CONFIG_FILE=pip.conf ../after/bin/pip install -q -r requirements.txt) && renovate-demo/build/after/bin/python -c 'import jinja2; print("jinja2", jinja2.__version__)'
```

> "The repo's pip config points at Nexus, and Nexus serves the Lightwell
> builds first. We rebuild with nothing but the offline mirror and get
> 3.1.5+rhlw.1. That pin can't quietly fall back to the vulnerable build,
> because it doesn't exist on public PyPI."

```bash
(cd renovate-demo/build/app && ../after/bin/python -m pytest -q -p no:cacheprovider)
```

> "Same tests, no code changes, all passing."

```bash
clear
diff -rq -x __pycache__ renovate-demo/build/before/lib/python3.12/site-packages/jinja2 renovate-demo/build/after/lib/python3.12/site-packages/jinja2
diff -u renovate-demo/build/before/lib/python3.12/site-packages/jinja2/filters.py renovate-demo/build/after/lib/python3.12/site-packages/jinja2/filters.py | grep -E '^[-+]' | grep -vE '^(\+\+\+|---) ' | grep -vE '^[-+]\s*#|"""|``|\.$'
```

> "What did Red Hat actually change? Two files. `__init__.py` only has the
> new version string. In `filters.py`, one function changed: the `attr`
> filter now goes through the sandbox. It's the upstream 3.1.6 fix,
> backported to 3.1.5, and nothing else. A small, auditable patch."
>
> (The diff is trimmed to code lines, leaving out comments and docstrings.)

```bash
clear
uvx -q pip-audit -s osv -f json -o renovate-demo/build/after-audit.json --path renovate-demo/build/after/lib/python3.12/site-packages; python3 -I demo/lightwell_audit.py renovate-demo/build/after-audit.json; echo "exit code: $?"
```

> "And the security gate: the Lightwell-aware check finds the published
> advisory, marks the CVE fixed, and exits zero. CI goes green."

## Scene 8: Wrap-up (≈ 30 s)

```bash
clear
./renovate-demo/run-renovate.sh 2>&1 | grep -E '(Branch|PR) created|Repository finished'
```

> "Renovate keeps watching. Nothing to do now, but when Lightwell publishes
> rhlw.2, the next run opens that PR.
>
> To recap: a CVE was found, Renovate proposed Red Hat Lightwell's patched
> build of the same version, we merged one line, and the app was fixed,
> without an upgrade and without touching application code."

**Show (optional):** the browser, Issues → **Dependency Dashboard**, as the
closing shot.

---

## If something goes wrong on camera

| Symptom | Fix |
|---|---|
| Renovate opens no PR | The repo wasn't reset. Run `./renovate-demo/setup-gitea.sh --reset && rm -rf renovate-demo/build` and retake from Scene 3 |
| `git clone` says the destination already exists | `rm -rf renovate-demo/build` |
| pip or Renovate gets `401` from Nexus | `NEXUS_ANONYMOUS=true` is missing from `.env`; add it and re-run `podman compose run --rm --no-deps seed` |
| A long pause during pip-audit or uv | Caches were cold; rehearse first, or cut the pause in editing |
| Nexus shows "unhealthy" in `podman ps` | Ignore it; health checks can't run on some hosts. Check with the `curl` in Scene 2 |
