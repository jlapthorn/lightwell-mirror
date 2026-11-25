# lightwell-python-demo-app

A demo application that shows how **Red Hat Lightwell** and **Renovate**
remediate the dependencies of a Python project. It's the Python counterpart of
[lightwell-java-demo-app](https://github.com/lightwell-experience/lightwell-java-demo-app).

The application is a small Flask service that previews customer notification
templates written by support staff. The templates are rendered in Jinja2's
`SandboxedEnvironment`. `requirements.txt` pins `jinja2==3.1.5`, the version
the platform team has certified, which has **CVE-2025-27516**: the `|attr`
filter lets a template get around the sandbox. Upstream's fix is 3.1.6, an
unplanned upgrade. Lightwell publishes `3.1.5+rhlw.1`, the same release with
the fix backported.

> ⚠️ **Do not deploy this application in production.** It intentionally pins
> a vulnerable dependency for demonstration purposes.

## How the demo works

1. **Baseline:** `requirements.txt` pins the vulnerable upstream `jinja2==3.1.5`.
   `test_attr_filter_is_sandboxed` is a regression test for the CVE and fails.
2. **Resolution:** [`pip.conf`](#pipconf) points pip at the offline Nexus,
   which serves the Lightwell builds first.
3. **Remediation PR:** Renovate (see [Renovate configuration](#renovate-configuration))
   checks the Lightwell index and opens a PR that changes
   `jinja2==3.1.5` to `jinja2==3.1.5+rhlw.1`.
4. **Verification:** after the merge, the unchanged test suite passes, and
   the Lightwell-aware audit reports the CVE as fixed by `RHLW-2026-bbcf7d39b1fbb255`.

## pip.conf

The Python equivalent of `.mvn/settings.xml` in the Java demo. It sets the
package index to the Nexus group `pypi-lightwell`, which searches its members
in this order:

| Order | Repository          | Contents                                                  |
|-------|---------------------|-----------------------------------------------------------|
| 1     | `python-remediated` | Lightwell rebuilds with backported CVE fixes (`+rhlw.N`)  |
| 2     | `python-validated`  | Upstream packages Lightwell has validated                 |
| 3     | `pypi-extras`       | Dependencies Lightwell doesn't ship                       |

pip doesn't read a project-local config by itself, so point it there:

```bash
PIP_CONFIG_FILE=pip.conf pip install -r requirements.txt
```

## Renovate configuration

[`renovate.json`](renovate.json) does what the
`github>lightwell-experience/renovate-config:java-remediated` preset does for
Maven:

- **Custom `regex` manager** for `requirements*.txt`, with the built-in
  `pip_requirements` manager disabled so the file isn't processed twice. It
  only matches exact `==` pins.
- **Versioning** `regex:^(?<compatibility>[^+]+)(\+rhlw\.(?<major>\d+))?$`
  makes the upstream version the compatibility key and the rebuild number the
  version. Renovate moves `3.1.5` → `3.1.5+rhlw.1` → `3.1.5+rhlw.2` and
  **never** proposes `3.1.6`, even though Nexus serves it too.
- **`packageRules`** point the lookup at the offline Nexus instead of
  `packages.redhat.com`, and label the PRs `security` and `lightwell`, with a
  note that links to the RHLW advisories.

### Why not the `python-manager` preset?

`lightwell-experience/renovate-config` also has a `python-manager` preset. It
only points the pypi datasource at the Lightwell index. Under PEP 440,
`==3.1.5` already matches `3.1.5+rhlw.1`, so that preset leaves the pin alone
and opens **no PR**: pip picks up the rebuild as long as it installs from the
Lightwell index. This demo pins the rebuild explicitly instead, because:

- the change is visible and reviewable, as a PR with an audit trail;
- an install against public PyPI fails, because `3.1.5+rhlw.1` doesn't exist
  there, rather than quietly installing the vulnerable build;
- scanners and SBOMs see the exact version that's deployed.

### Running Renovate

Renovate runs as a container against this repository's Gitea:
`demo/run-renovate.sh` in the lightwell-mirror
project. In the Java demo the same role is
played by a scheduled GitHub Action.

## Running the app

```bash
python3.12 -m venv .venv
PIP_CONFIG_FILE=pip.conf .venv/bin/pip install -r requirements.txt
.venv/bin/python -m pytest -q
.venv/bin/flask --app app run
curl -s localhost:5000/preview -H 'Content-Type: application/json' \
     -d '{"template": "Hi {{ customer.name }}, order {{ order.id }} has shipped."}'
```

## Repository layout

| Path               | Purpose                                                 |
|--------------------|---------------------------------------------------------|
| `app.py`           | Flask notification-template preview service             |
| `test_app.py`      | Tests, including the CVE-2025-27516 regression test     |
| `requirements.txt` | Pins, with the vulnerable `jinja2==3.1.5`               |
| `pip.conf`         | Points pip at the offline Nexus (Lightwell first)       |
| `renovate.json`    | Renovate config that proposes only `+rhlw` rebuilds     |
