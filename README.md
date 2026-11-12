# Lightwell offline mirror

Two parts:

1. `mirror_repos.py` downloads every artifact from Maven/PyPI repositories,
   public or authenticated, (configured in `repos.toml`), keeping each repo's folder
   layout under `mirror/<repo>/`.
2. `compose.yaml` runs Sonatype Nexus Repository Community Edition and
   loads `mirror/` into it.

## 1. Mirror (online host)

Requires Python 3.11+. Standard library only, nothing to install.
`repos.toml` is gitignored. Copy yours over from the original machine, or
recreate it from `repos.example.toml`, which is set up for the Lightwell
public demo.

The `public-lightwell-demo` repos need no credentials (`username_env = ""`
in the config). Only the full Lightwell repos, such as
`lightwell/python/remediated`, need a service account:

```bash
cp repos.example.toml repos.toml           # add your repositories
export MIRROR_USERNAME='<service account>' # only for repos that need it
read -rs MIRROR_PASSWORD && export MIRROR_PASSWORD

./mirror_repos.py -c repos.toml --dry-run   # list only, write manifests
./mirror_repos.py -c repos.toml             # download (re-run to resume)
./mirror_repos.py -c repos.toml -r python-validated   # a single repo
```

* Re-runs skip files already on disk (size match; `--verify-existing`
  re-hashes them instead). Files are written to `.part` first and renamed
  only after the size and hash checks pass.
* `mirror/_manifests/<repo>.jsonl` lists every file;
  `<repo>.failed.txt` lists failures (downloads *and* directories that
  couldn't be listed). If it exists, run the command again.
* Maven files are checked against the `.sha1`/`.sha256`/... files next to
  them. Mismatches on `maven-metadata.xml` only produce a warning, because
  upstream has some stale `.sha512` files.

### PyPI dependencies Lightwell doesn't ship

The Lightwell Python repos hold the packages themselves, not their whole
dependency tree (Jinja2 needs MarkupSafe, Flask needs Werkzeug, ...), so
an offline `pip install` fails without them. After mirroring:

```bash
./fetch_pypi_extras.sh          # reads pypi-extras.txt
```

This resolves `pypi-extras.txt` against the mirrored Lightwell files plus
public PyPI, and keeps only the projects Lightwell doesn't provide in
`mirror/pypi-extras/`. Wheels are picked for CPython 3.12 on manylinux
x86_64 (what Lightwell builds for); override with `PY_VERSION` and
`PLATFORMS`. Add anything your applications need to `pypi-extras.txt`.
`pypi-extras` is the last member of `pypi-lightwell`, so a Lightwell build
always wins.

## 2. Offline Nexus

On a connected machine, save the image and copy it across with the mirror:

```bash
podman pull docker.io/sonatype/nexus3:3.98.1-alpine
podman save -o nexus3.tar docker.io/sonatype/nexus3:3.98.1-alpine
tar -cf lightwell-mirror.tar mirror compose.yaml seed nexus.env.example
```

On the offline host:

```bash
podman load -i nexus3.tar
cp nexus.env.example .env        # set NEXUS_ADMIN_PASSWORD
podman compose up -d             # or: podman-compose up -d
podman compose logs -f seed      # exits 0 when everything is uploaded
```

Nexus OSS can't serve a plain directory as a repository. So the `seed`
container (the same Nexus image, nothing extra to download) does the
following:

* changes the generated admin password to `NEXUS_ADMIN_PASSWORD`;
* accepts the Community Edition EULA (required before Nexus can be used);
* sets anonymous access (`NEXUS_ANONYMOUS`, default `false`);
* creates a hosted repo for each mirror folder and uploads its files through
  the Nexus API;
* creates groups `maven-lightwell` and `pypi-lightwell`. Remediated comes
  before validated (then `pypi-extras`), so when both contain the same path
  the remediated artifact wins. On re-runs an existing group's member list
  is updated, so a repo added to `SEED_REPOS` later joins its group.

Artifacts end up in the `nexus-data` volume. After seeding, the `mirror/`
folder isn't needed by Nexus. Each repo is seeded once (a marker is stored
in the `seed-state` volume). To re-upload, run
`SEED_FORCE=1 podman compose up seed`.

Client URLs (port 8081 by default):

| Client | URL |
|---|---|
| Maven  | `http://<host>:8081/repository/maven-lightwell/` |
| pip    | `http://<host>:8081/repository/pypi-lightwell/simple/` |

Individual repos are under `/repository/java-remediated/`,
`/repository/python-validated/simple/`, and so on.

**Community Edition limits:** Sonatype caps CE usage by component count and
requests per day. Check the current limits against the size of the mirror
(`wc -l mirror/_manifests/*.jsonl` gives a file count; a Maven component is
typically 5–20 files).
