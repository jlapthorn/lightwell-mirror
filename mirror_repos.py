#!/usr/bin/env python3
"""Mirror authenticated Maven and PyPI repositories to a local directory tree.

Every artifact is written to <output_dir>/<repo name>/<path inside the repo>,
so the result can be fed into an offline Nexus.

Listing methods:
  nexus        Nexus 3 REST API  (/service/rest/v1/assets)   - any format
  artifactory  Artifactory storage API (?list&deep=1)        - any format
  html         Recursive crawl of HTML directory listings    - Maven
  simple       PEP 503 / PEP 691 "simple" index              - PyPI

Standard library only; requires Python 3.11+.
"""

from __future__ import annotations

import argparse
import concurrent.futures as cf
import dataclasses
import fnmatch
import hashlib
import html.parser
import json
import logging
import os
import re
import ssl
import sys
import threading
import time
import tomllib
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

log = logging.getLogger("mirror")

USER_AGENT = "repo-mirror/1.0"
RETRY_HTTP_CODES = {408, 429, 500, 502, 503, 504}
HASH_PREFERENCE = ("sha512", "sha256", "sha1", "md5")
CHUNK = 1 << 20
PYPI_ACCEPT = (
    "application/vnd.pypi.simple.v1+json, "
    "application/vnd.pypi.simple.v1+html;q=0.2, text/html;q=0.01"
)


# --------------------------------------------------------------------------- #
# Data types
# --------------------------------------------------------------------------- #

@dataclasses.dataclass
class Entry:
    rel: str                      # path inside the repo, decoded, "/"-separated
    url: str                      # absolute download URL
    size: int | None = None
    hashes: dict[str, str] = dataclasses.field(default_factory=dict)

    def best_hash(self) -> tuple[str, str] | None:
        for algo in HASH_PREFERENCE:
            if self.hashes.get(algo):
                return algo, self.hashes[algo].lower()
        return None


@dataclasses.dataclass
class Repo:
    name: str
    format: str                   # "maven" | "pypi"
    url: str
    method: str = "auto"
    paths: list[str] = dataclasses.field(default_factory=list)
    projects: list[str] = dataclasses.field(default_factory=list)
    exclude: list[str] = dataclasses.field(default_factory=list)
    username_env: str = "MIRROR_USERNAME"
    password_env: str = "MIRROR_PASSWORD"
    ca_bundle: str | None = None
    insecure: bool = False
    timeout: float = 120.0
    retries: int = 4
    # Optional overrides when the URL layout can't be inferred.
    api_base: str | None = None   # nexus: server root; artifactory: .../artifactory
    repo_id: str | None = None    # repository name on the server
    pypi_root: str | None = None  # URL that local paths are made relative to

    def resolved_method(self) -> str:
        if self.method != "auto":
            return self.method
        if self.format == "pypi":
            return "simple"
        if "/repository/" in self.url:
            return "nexus"
        if "/artifactory/" in self.url:
            return "artifactory"
        return "html"


# --------------------------------------------------------------------------- #
# HTTP
# --------------------------------------------------------------------------- #

class Http:
    """urllib wrapper with retries and host-scoped preemptive basic auth.

    Credentials are only sent to the repository's own scheme+host. They are
    attached as an "unredirected" header, so a redirect to another host
    (e.g. a pre-signed S3 URL) never receives them.
    """

    def __init__(self, repo: Repo, username: str | None, password: str | None):
        if repo.insecure:
            ctx = ssl._create_unverified_context()
        else:
            ctx = ssl.create_default_context(cafile=repo.ca_bundle)
        handlers: list[urllib.request.BaseHandler] = [
            urllib.request.HTTPSHandler(context=ctx)
        ]
        if username:
            parts = urllib.parse.urlsplit(repo.url)
            mgr = urllib.request.HTTPPasswordMgrWithPriorAuth()
            mgr.add_password(None, f"{parts.scheme}://{parts.netloc}/",
                             username, password or "", is_authenticated=True)
            handlers.append(urllib.request.HTTPBasicAuthHandler(mgr))
        self.opener = urllib.request.build_opener(*handlers)
        self.timeout = repo.timeout
        self.retries = repo.retries
        self.listing_errors: list[tuple[str, str]] = []  # (url, error)

    def open(self, url: str, headers: dict[str, str] | None = None):
        req = urllib.request.Request(
            url, headers={"User-Agent": USER_AGENT, **(headers or {})})
        return self.opener.open(req, timeout=self.timeout)

    def retry(self, what: str, fn):
        delay = 2.0
        attempt = 0
        while True:
            try:
                return fn()
            except urllib.error.HTTPError as e:
                if e.code not in RETRY_HTTP_CODES or attempt >= self.retries:
                    raise
                err: Exception = e
            except (urllib.error.URLError, OSError) as e:  # timeouts, resets
                if attempt >= self.retries:
                    raise
                err = e
            attempt += 1
            log.warning("%s: %s (retry %d/%d in %.0fs)",
                        what, err, attempt, self.retries, delay)
            time.sleep(delay)
            delay = min(delay * 2, 60)

    def get(self, url: str, headers: dict[str, str] | None = None
            ) -> tuple[bytes, str, str]:
        """Return (body, final_url, content_type)."""
        def do():
            with self.open(url, headers) as r:
                return r.read(), r.geturl(), r.headers.get("Content-Type", "")
        return self.retry(f"GET {url}", do)

    def get_json(self, url: str):
        body, _, _ = self.get(url, {"Accept": "application/json"})
        return json.loads(body)


# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #

class _LinkParser(html.parser.HTMLParser):
    def __init__(self):
        super().__init__()
        self.links: list[tuple[str, dict[str, str | None]]] = []

    def handle_starttag(self, tag, attrs):
        if tag == "a":
            a = dict(attrs)
            if a.get("href"):
                self.links.append((a["href"], a))


def parse_links(body: bytes) -> list[tuple[str, dict[str, str | None]]]:
    p = _LinkParser()
    p.feed(body.decode("utf-8", errors="replace"))
    return p.links


def with_slash(url: str) -> str:
    return url if url.endswith("/") else url + "/"


def quote_path(rel: str) -> str:
    return urllib.parse.quote(rel, safe="/")


def safe_dest(root: Path, rel: str) -> Path:
    """Map a remote path to a local one, refusing anything that escapes root."""
    parts = [p for p in rel.replace("\\", "/").split("/") if p not in ("", ".")]
    if not parts or any(p == ".." or "\x00" in p for p in parts):
        raise ValueError(f"unsafe path from server: {rel!r}")
    return root.joinpath(*parts)


def normalize_project(name: str) -> str:
    return re.sub(r"[-_.]+", "-", name).lower()


def human(n: float) -> str:
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if n < 1024 or unit == "TiB":
            return f"{n:.1f} {unit}" if unit != "B" else f"{int(n)} B"
        n /= 1024
    return str(n)


# --------------------------------------------------------------------------- #
# Listers
# --------------------------------------------------------------------------- #

def list_nexus(repo: Repo, http: Http, workers: int):
    server, repo_id = repo.api_base, repo.repo_id
    if not (server and repo_id):
        head, sep, tail = repo.url.partition("/repository/")
        if not sep:
            raise SystemExit(f"[{repo.name}] can't infer Nexus server/repo from "
                             f"{repo.url}; set api_base and repo_id")
        server = server or head
        repo_id = repo_id or tail.split("/")[0]
    base = with_slash(f"{server.rstrip('/')}/repository/{repo_id}")
    token = None
    while True:
        q = {"repository": repo_id}
        if token:
            q["continuationToken"] = token
        data = http.get_json(f"{server.rstrip('/')}/service/rest/v1/assets?"
                             + urllib.parse.urlencode(q))
        for item in data.get("items", []):
            rel = item["path"].lstrip("/")
            # Build the URL ourselves: downloadUrl uses Nexus' configured
            # base URL, which may not be reachable from here.
            yield Entry(rel, base + quote_path(rel), item.get("fileSize"),
                        {k: v for k, v in (item.get("checksum") or {}).items()
                         if k in HASH_PREFERENCE and v})
        token = data.get("continuationToken")
        if not token:
            break


def list_artifactory(repo: Repo, http: Http, workers: int):
    api, repo_id = repo.api_base, repo.repo_id
    if not (api and repo_id):
        head, sep, tail = repo.url.partition("/artifactory/")
        if not sep:
            raise SystemExit(f"[{repo.name}] can't infer Artifactory repo from "
                             f"{repo.url}; set api_base and repo_id")
        api = api or head + "/artifactory"
        repo_id = repo_id or tail.split("/")[0]
    api = api.rstrip("/")
    base = with_slash(f"{api}/{repo_id}")
    data = http.get_json(f"{api}/api/storage/{repo_id}?list&deep=1&listFolders=0")
    for f in data.get("files", []):
        rel = urllib.parse.unquote(f["uri"]).lstrip("/")
        hashes = {}
        if f.get("sha2"):
            hashes["sha256"] = f["sha2"]
        if f.get("sha1"):
            hashes["sha1"] = f["sha1"]
        yield Entry(rel, base + quote_path(rel), f.get("size"), hashes)


def list_html(repo: Repo, http: Http, workers: int):
    """Breadth-first crawl of HTML directory listings, never leaving repo.url."""
    base = with_slash(repo.url)
    frontier = [with_slash(urllib.parse.urljoin(base, p.lstrip("/")))
                for p in repo.paths] or [base]
    seen: set[str] = set()

    def fetch_dir(dir_url: str):
        body, _, _ = http.get(dir_url)
        dirs, files = [], []
        for href, _ in parse_links(body):
            u, _ = urllib.parse.urldefrag(urllib.parse.urljoin(dir_url, href))
            # Only descend: drops parent links, sorting links, other hosts.
            if "?" in u or not u.startswith(dir_url) or u == dir_url:
                continue
            (dirs if u.endswith("/") else files).append(u)
        return dirs, files

    with cf.ThreadPoolExecutor(workers) as ex:
        while frontier:
            batch = [d for d in frontier if d not in seen]
            seen.update(batch)
            frontier = []
            futures = {ex.submit(fetch_dir, d): d for d in batch}
            for fut in cf.as_completed(futures):
                try:
                    dirs, files = fut.result()
                except Exception as e:
                    log.error("[%s] listing %s failed: %s",
                              repo.name, futures[fut], e)
                    http.listing_errors.append((futures[fut], str(e)))
                    continue
                frontier.extend(dirs)
                for u in files:
                    yield Entry(urllib.parse.unquote(u[len(base):]), u)
            log.info("[%s] crawled %d directories", repo.name, len(seen))


def list_simple(repo: Repo, http: Http, workers: int):
    index = with_slash(repo.url)
    if repo.pypi_root:
        root = with_slash(repo.pypi_root)
    elif index.rstrip("/").endswith("/simple"):
        root = index.rstrip("/")[: -len("simple")]
    else:
        root = index

    def get_page(url):
        body, final, ctype = http.get(url, {"Accept": PYPI_ACCEPT})
        return body, with_slash(final), ctype

    if repo.projects:
        project_urls = [urllib.parse.urljoin(index, normalize_project(p) + "/")
                        for p in repo.projects]
    else:
        body, final, ctype = get_page(index)
        if "json" in ctype:
            project_urls = [urllib.parse.urljoin(final, normalize_project(p["name"]) + "/")
                            for p in json.loads(body)["projects"]]
        else:
            project_urls = [urllib.parse.urljoin(final, h) for h, _ in parse_links(body)]
        log.info("[%s] index lists %d projects", repo.name, len(project_urls))

    def to_entry(file_url: str, hashes: dict, size) -> Entry:
        file_url, frag = urllib.parse.urldefrag(file_url)
        if not hashes and "=" in frag:
            algo, _, val = frag.partition("=")
            hashes = {algo: val}
        if file_url.startswith(root):
            rel = urllib.parse.unquote(file_url[len(root):])
        else:  # e.g. a proxy that links straight to files.pythonhosted.org
            p = urllib.parse.urlsplit(file_url)
            rel = f"_external/{p.netloc}{urllib.parse.unquote(p.path)}"
        return Entry(rel, file_url, size,
                     {k: v for k, v in hashes.items() if k in HASH_PREFERENCE})

    def fetch_project(url):
        body, final, ctype = get_page(url)
        if "json" in ctype:
            return [to_entry(urllib.parse.urljoin(final, f["url"]),
                             f.get("hashes") or {}, f.get("size"))
                    for f in json.loads(body).get("files", [])]
        return [to_entry(urllib.parse.urljoin(final, h), {}, None)
                for h, _ in parse_links(body)]

    with cf.ThreadPoolExecutor(workers) as ex:
        futures = {ex.submit(fetch_project, u): u for u in project_urls}
        for i, fut in enumerate(cf.as_completed(futures), 1):
            try:
                yield from fut.result()
            except Exception as e:
                log.error("[%s] project page %s failed: %s",
                          repo.name, futures[fut], e)
                http.listing_errors.append((futures[fut], str(e)))
            if i % 500 == 0:
                log.info("[%s] read %d/%d project pages",
                         repo.name, i, len(project_urls))


LISTERS = {
    "nexus": list_nexus,
    "artifactory": list_artifactory,
    "html": list_html,
    "simple": list_simple,
}


# --------------------------------------------------------------------------- #
# Download
# --------------------------------------------------------------------------- #

def file_hash(path: Path, algo: str) -> str:
    h = hashlib.new(algo)
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(CHUNK), b""):
            h.update(chunk)
    return h.hexdigest()


def is_current(dest: Path, e: Entry, verify_existing: bool) -> bool:
    if not dest.is_file():
        return False
    if e.size is not None and dest.stat().st_size != e.size:
        return False
    bh = e.best_hash()
    if bh and (verify_existing or e.size is None):
        return file_hash(dest, bh[0]) == bh[1]
    return True


def download(e: Entry, dest: Path, http: Http) -> int:
    dest.parent.mkdir(parents=True, exist_ok=True)
    part = dest.with_name(dest.name + ".part")
    bh = e.best_hash()

    def attempt():
        h = hashlib.new(bh[0]) if bh else None
        n = 0
        with http.open(e.url) as r, open(part, "wb") as f:
            for chunk in iter(lambda: r.read(CHUNK), b""):
                f.write(chunk)
                n += len(chunk)
                if h:
                    h.update(chunk)
        if e.size is not None and n != e.size:
            raise OSError(f"size mismatch: got {n}, expected {e.size}")
        if h and h.hexdigest() != bh[1]:
            raise ValueError(f"{bh[0]} mismatch: got {h.hexdigest()}, "
                             f"expected {bh[1]}")
        return n

    try:
        n = http.retry(f"download {e.rel}", attempt)
    except BaseException:
        part.unlink(missing_ok=True)
        raise
    os.replace(part, dest)
    return n


def verify_sidecars(root: Path, rels: list[str]) -> list[str]:
    """For Maven: check files against downloaded .sha1/.sha256/... siblings."""
    bad = []
    for rel in rels:
        for algo in ("sha512", "sha256", "sha1", "md5"):
            if rel.endswith("." + algo):
                break
        else:
            continue
        sidecar = safe_dest(root, rel)
        target = sidecar.with_name(sidecar.name[: -len(algo) - 1])
        if not (sidecar.is_file() and target.is_file()):
            continue
        txt = sidecar.read_text(errors="replace").split()
        if not txt or not re.fullmatch(r"[0-9a-fA-F]+", txt[0]):
            continue
        if file_hash(target, algo) != txt[0].lower():
            bad.append(str(target.relative_to(root)))
    return bad


# --------------------------------------------------------------------------- #
# Driver
# --------------------------------------------------------------------------- #

def mirror(repo: Repo, out_root: Path, workers: int, dry_run: bool,
           verify_existing: bool) -> bool:
    method = repo.resolved_method()
    if method not in LISTERS:
        raise SystemExit(f"[{repo.name}] unknown method {method!r}")
    user = os.environ.get(repo.username_env)
    password = os.environ.get(repo.password_env)
    if not user:
        log.warning("[%s] $%s not set; connecting anonymously",
                    repo.name, repo.username_env)
    http = Http(repo, user, password)
    root = out_root / repo.name
    manifests = out_root / "_manifests"

    log.info("[%s] listing %s via %s", repo.name, repo.url, method)
    entries: dict[str, Entry] = {}
    prefixes = [p.strip("/") + "/" for p in repo.paths]
    for e in LISTERS[method](repo, http, workers):
        if method in ("nexus", "artifactory") and prefixes and \
                not any(e.rel.startswith(p) for p in prefixes):
            continue
        if any(fnmatch.fnmatch(e.rel, pat) for pat in repo.exclude):
            continue
        try:
            safe_dest(root, e.rel)
        except ValueError as err:
            log.error("[%s] skipping: %s", repo.name, err)
            continue
        if e.rel in entries and entries[e.rel].url != e.url:
            log.warning("[%s] duplicate path %s (%s vs %s), keeping first",
                        repo.name, e.rel, entries[e.rel].url, e.url)
            continue
        entries[e.rel] = e

    known = [e.size for e in entries.values() if e.size is not None]
    log.info("[%s] %d files%s", repo.name, len(entries),
             f", {human(sum(known))} across {len(known)} with known size"
             if known else "")

    manifests.mkdir(parents=True, exist_ok=True)
    with open(manifests / f"{repo.name}.jsonl", "w") as f:
        for e in entries.values():
            f.write(json.dumps(dataclasses.asdict(e)) + "\n")
    if dry_run:
        return True

    lock = threading.Lock()
    stats = {"done": 0, "skipped": 0, "bytes": 0}
    # Directories/pages that couldn't be listed: their files are missing.
    failures: list[tuple[str, str]] = [
        (url, f"listing failed, contents not mirrored: {err}")
        for url, err in http.listing_errors]
    total = len(entries)
    started = time.monotonic()

    def work(e: Entry):
        dest = safe_dest(root, e.rel)
        if is_current(dest, e, verify_existing):
            with lock:
                stats["skipped"] += 1
            return
        n = download(e, dest, http)
        with lock:
            stats["done"] += 1
            stats["bytes"] += n

    with cf.ThreadPoolExecutor(workers) as ex:
        futures = {ex.submit(work, e): e for e in entries.values()}
        for i, fut in enumerate(cf.as_completed(futures), 1):
            try:
                fut.result()
            except Exception as err:
                e = futures[fut]
                failures.append((e.rel, str(err)))
                log.error("[%s] %s: %s", repo.name, e.rel, err)
            if i % 200 == 0 or i == total:
                rate = stats["bytes"] / max(time.monotonic() - started, 1e-6)
                log.info("[%s] %d/%d  downloaded=%d skipped=%d failed=%d  "
                         "%s  (%s/s)", repo.name, i, total, stats["done"],
                         stats["skipped"], len(failures),
                         human(stats["bytes"]), human(rate))

    if repo.format == "maven":
        for rel in verify_sidecars(root, list(entries)):
            if rel.rsplit("/", 1)[-1] == "maven-metadata.xml":
                # Seen upstream (stale .sha512); Nexus regenerates metadata.
                log.warning("[%s] %s does not match a checksum sidecar file "
                            "(metadata only, not treated as failure)",
                            repo.name, rel)
                continue
            failures.append((rel, "does not match its checksum sidecar file"))
            log.error("[%s] %s does not match its checksum sidecar file",
                      repo.name, rel)

    fail_file = manifests / f"{repo.name}.failed.txt"
    if failures:
        fail_file.write_text("".join(f"{r}\t{m}\n" for r, m in failures))
        log.error("[%s] %d failures, see %s", repo.name, len(failures), fail_file)
    else:
        fail_file.unlink(missing_ok=True)
        log.info("[%s] complete: %s", repo.name, root)
    return not failures


def load_config(path: Path) -> tuple[dict, list[Repo]]:
    with open(path, "rb") as f:
        cfg = tomllib.load(f)
    defaults = cfg.get("defaults", {})
    repo_fields = {f.name for f in dataclasses.fields(Repo)}
    global_keys = {"output_dir", "workers"}
    unknown = set(defaults) - repo_fields - global_keys
    if unknown:
        raise SystemExit(f"unknown keys in [defaults]: {sorted(unknown)}")
    repos = []
    for raw in cfg.get("repo", []):
        unknown = set(raw) - repo_fields
        if unknown:
            raise SystemExit(f"unknown keys in repo {raw.get('name')}: "
                             f"{sorted(unknown)}")
        merged = {k: v for k, v in defaults.items() if k in repo_fields} | raw
        r = Repo(**merged)
        if r.format not in ("maven", "pypi"):
            raise SystemExit(f"[{r.name}] format must be 'maven' or 'pypi'")
        if not re.fullmatch(r"[A-Za-z0-9._-]+", r.name):
            raise SystemExit(f"invalid repo name {r.name!r}")
        repos.append(r)
    if len({r.name for r in repos}) != len(repos):
        raise SystemExit("repo names must be unique")
    return defaults, repos


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-c", "--config", type=Path, default=Path("repos.toml"))
    ap.add_argument("-o", "--output-dir", type=Path,
                    help="overrides defaults.output_dir")
    ap.add_argument("-r", "--repo", action="append", default=[],
                    help="only mirror this repo (repeatable)")
    ap.add_argument("-w", "--workers", type=int, help="parallel requests")
    ap.add_argument("-n", "--dry-run", action="store_true",
                    help="list and write manifests, download nothing")
    ap.add_argument("--verify-existing", action="store_true",
                    help="re-hash files already on disk instead of trusting size")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)-7s %(message)s",
                        datefmt="%H:%M:%S")
    defaults, repos = load_config(args.config)
    if args.repo:
        missing = set(args.repo) - {r.name for r in repos}
        if missing:
            raise SystemExit(f"not in config: {sorted(missing)}")
        repos = [r for r in repos if r.name in args.repo]

    out = args.output_dir or Path(defaults.get("output_dir", "mirror"))
    workers = args.workers or int(defaults.get("workers", 8))
    ok = True
    for r in repos:
        try:
            ok &= mirror(r, out, workers, args.dry_run, args.verify_existing)
        except urllib.error.HTTPError as e:
            log.error("[%s] %s %s: %s", r.name, e.code, e.reason, e.url)
            if e.code in (401, 403):
                log.error("[%s] check $%s / $%s", r.name,
                          r.username_env, r.password_env)
            ok = False
        except urllib.error.URLError as e:
            log.error("[%s] %s", r.name, e.reason)
            ok = False
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
