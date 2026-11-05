# nginx:1.25-bookworm drop-in replacement with CVE fixes

nginx 1.25.5 rebuilt from upstream source on Debian bookworm, packaged as `.deb` files and installed into
an image that's a drop-in replacement for `nginx:1.25-bookworm`. Two CVEs are fixed:

- **CVE-2026-15176**: backport of an upstream nginx fix
- **CVE-2024-5535**: version bump, OpenSSL 3.5.9 LTS built from source and linked into nginx

Both fixes and the drop-in claim are checked by automated tests (`make test`, `make check-image`,
`make check-cve`).

| Result | |
|---|---|
| CVEs fixed | CVE-2026-15176 (backport) and CVE-2024-5535 (bump), each with a stock-vs-ours check |
| Drop-in | image config, nginx file layout and user identical; 33/33 HTTP compatibility cases identical |
| Scan (Trivy) | 835 findings (21 critical) -> 465 (3 critical); none of the remaining ones has a fix available |
| Image size | 273 MB -> 283 MB |

## Run it

Used exactly like the original:

```
docker run -d -p 8080:80 echo-nginx:1.25.5
docker run -d -p 8080:80 -v "$PWD/my.conf:/etc/nginx/conf.d/default.conf:ro" echo-nginx:1.25.5
```

## Repo layout

| Path | What |
|---|---|
| `baseline/` | Trivy + Grype reports of the original image, `nginx -V`, `docker inspect`, package list |
| `triage/` | Per-finding triage table (`triage.py`), checks for the chosen CVEs, [reasoning](triage/README.md) |
| `build/` | `Dockerfile` + scripts that build the `.deb` files from source; `patches/` holds the backport |
| `Containerfile` | Final image from the `.deb` files |
| `test/` | Compatibility test, image comparison, per-CVE checks ([what they cover](test/README.md)) |
| `rescan/` | Trivy + Grype reports of the rebuilt image |
| `Makefile` | All entry points |

## Build and test

Needs Docker (with BuildKit, the default), `make`, bash and Python 3. On Windows, run from Git Bash.

```
make deb          # build nginx + modules from source in a clean debian:bookworm-slim -> out/*.deb
make image        # install the .debs into bookworm-slim -> echo-nginx:1.25.5
make test         # compatibility test: same requests to nginx:1.25-bookworm and echo-nginx, must match
make check-image  # compare image config, file layout, user and packages with the original
make check-cve    # per CVE: stock is vulnerable, ours is fixed
make scan         # rescan echo-nginx with the same pinned Trivy/Grype versions -> rescan/
```

Each target builds what it needs first. A first run from a fresh clone takes a few minutes; after that,
Docker's cache makes it much faster.

What the build does (`build/Dockerfile`):
1. Downloads nginx 1.25.5 and checks its sha256 and its gpg signature against pinned nginx developer keys.
2. Downloads OpenSSL 3.5.9 and checks it the same way against OpenSSL's release key, then builds it once as
   static libraries.
3. Downloads nginx's own packaging files (pkg-oss, tag `1.25.5-1`) for config files and maintainer scripts.
4. Applies `build/patches/*.patch` with `patch --fuzz=0`.
5. Configures with the exact `./configure` arguments of the original package (`build/configure-args`), plus
   `--with-openssl`, and builds nginx, nginx-debug and the geoip / image-filter / xslt modules.
6. Packages everything with `build/build-deb.sh` (`dpkg-deb`) using the same paths and metadata as the
   original packages.

## Image size

| Image | Size |
|---|---|
| `nginx:1.25-bookworm` | 273 MB |
| `echo-nginx:1.25.5` | 283 MB |

The extra 10 MB is OpenSSL: it's now inside `nginx` and `nginx-debug` (1.5 MB -> 8.5 MB each). njs isn't
shipped, which saves about 4 MB. Source: `docker image inspect`, see [`test/compare-image.txt`](test/compare-image.txt).

## CVEs fixed

| CVE | Severity (vendor / Trivy / Grype) | Where | Fix method | Evidence |
|---|---|---|---|---|
| CVE-2026-15176 | medium / not reported / Critical | nginx, `alias` + `rewrite` path mapping | **backport** of upstream commit [`f8a23425`](https://github.com/nginx/nginx/commit/f8a23425bd6840c4c36b4264edf576ba3646156f) (nginx 1.31.7) | [PR #4](https://github.com/danielpasker/echo-nginx/pull/4), [patch](build/patches/CVE-2026-15176.patch), [applies to 1.25.5](triage/evidence/CVE-2026-15176.txt), [stock vs ours](test/cve-2026-15176/result.txt) |
| CVE-2024-5535 | Low / Low / Critical | OpenSSL `SSL_select_next_proto()` | **version bump**: OpenSSL 3.0.11 (Debian, loaded at runtime) -> 3.5.9 LTS built from source, linked statically | [PR #5](https://github.com/danielpasker/echo-nginx/pull/5), [configure-args](build/configure-args), [fixed in 3.5.9](triage/evidence/CVE-2024-5535.txt), [stock vs ours](test/cve-2024-5535/result.txt) |

**CVE-2026-15176.** In a location with `alias`, a `rewrite` to a URI shorter than the location prefix makes
nginx compute a negative path length. Lengths are unsigned, so it wraps around. On the stock image the
error log shows `malloc(18446744073709551606) failed` (that's -10). The upstream fix is one condition: refuse the
mapping if the URI was rewritten. I regenerated the diff against 1.25.5 so it applies without offset.
On our image the same request logs `"alias" cannot be used in location ... where URI was rewritten` instead.

**CVE-2024-5535.** Fixed upstream in OpenSSL 3.0.15. My first plan was OpenSSL 3.0.22, but today's
bookworm already ships `libssl3 3.0.22`, so that would only be a base refresh. 3.5.9 is the current LTS
(supported until 2030). nginx calls the affected function in its ALPN callback, but OpenSSL rejects the empty
protocol list the bug needs before the callback runs, so the real risk through nginx was low (OpenSSL rates it
Low). On the stock image `nginx -V` says `built with OpenSSL 3.0.9 (running with 3.0.11)` and `ldd` shows
`libssl.so.3`; ours says `built with OpenSSL 3.5.9` and loads no system libssl. TLS with ALPN h2 works.

Why these two and not others: [triage/README.md](triage/README.md). The full per-finding table is
[`triage/all-findings.csv`](triage/all-findings.csv).

## How "drop-in" was verified

- `make check-image`: entrypoint, cmd, ports, stop signal, env, user and workdir are identical. The nginx file
  layout (paths, modes, owners, symlinks) and the `nginx` user (uid/gid 101) are identical. Packages are identical
  except njs and its dependency libedit2. Result: [`test/compare-image.txt`](test/compare-image.txt)
- `make test`: 33 HTTP cases sent as raw bytes to both images, including malformed requests, large bodies,
  ranges, gzip, custom config, the entrypoint's template rendering and TLS. Responses must match byte for byte
  (only `Date` is ignored). The CVE-2026-15176 case must differ.
- `make check-cve`: the two per-CVE checks above.

What "working correctly" means and what isn't covered: [test/README.md](test/README.md).

## Residual risk

Rescan of `echo-nginx:1.25.5` with the same scanner versions as the baseline (`make scan`, [rescan/](rescan/)).
The vulnerability DB is one day newer than the baseline's.

| | Original | Ours |
|---|---|---|
| Trivy findings | 835 (21 critical, 176 high) | 465 (3 critical, 79 high) |
| Findings with a fix available | 379 | 0 |

**What's still there:**
- **Debian packages with no fix** (all 465 remaining Trivy findings are `affected`, `fix_deferred` or
  `will_not_fix`). Most come from the image-filter module's image libraries (libheif, libtiff, libaom), curl, and
  glibc. They're kept because the original image has them; removing them would break drop-in compatibility.
- **The 3 remaining criticals:** libaom3 CVE-2023-6879 (AV1 encoder, image-filter dependency), libxml2
  CVE-2026-6653 (xslt dependency, fix deferred by Debian), zlib1g CVE-2023-45853 (in minizip, which isn't part of
  the zlib library nginx uses; Debian won't fix).
- **nginx itself:** nginx.org lists 28 advisories whose vulnerable range includes 1.25.5, and I fixed one.
  1.25 is an old mainline branch that gets no more fixes. Grype still reports 8 CVEs on the `nginx` package:
  CVE-2026-15176 is fixed but still matched by version string, and CVE-2026-93479 doesn't affect 1.25.5 at all
  (nginx lists it only for 1.30.0-1.30.5 and 1.31.2-1.31.6).
- **OpenSSL is now ours to maintain.** Debian's OpenSSL updates no longer reach nginx; a new OpenSSL fix
  means a rebuild. Scanners can't see the static OpenSSL either way.
- **njs** isn't rebuilt. Configs that load it won't start.

**What I'd do next, in order:**
1. Move to a supported nginx line (1.30.x stable) instead of carrying 1.25.5. Backporting 28 advisories
   isn't sustainable.
2. If staying on 1.25.5: backport the small ones next (CVE-2026-97629 is one line and applies cleanly;
   CVE-2026-95101 is 4 lines).
3. Publish a VEX document for CVE-2026-15176 so scanners stop reporting it.
4. Offer a slim variant without image-filter / xslt / geoip for users who don't load them. That removes most
   of the remaining findings.

## Surprises

- **Trivy finds 0 nginx CVEs** in the original image, while nginx.org lists 28 for 1.25.5. As far as I can tell,
  scanners compare the nginx.org package version against Debian's own nginx package (1.22), see "newer", and
  treat it as fixed. CVE-2024-7347 (mp4 module) is a clear example: it affects 1.25.5 and has an official patch,
  but no scanner reports it.
- **The planned bump was already done by Debian.** Rebuilding on current bookworm gave OpenSSL 3.0.22, which made
  my 3.0.22 bump pointless and moved it to 3.5.9.
- **I overstated CVE-2024-5535 at first.** Reading OpenSSL's source and advisory showed the ALPN path can't pass
  an empty list. The Grype "Critical" vs OpenSSL "Low" difference makes sense after that.
- **The first build's binaries were 8.4 MB instead of 1.5 MB:** the original build flags include `-g` and
  upstream strips at packaging time.
- **The first image was missing `ca-certificates`.** Upstream installs it to fetch its apt key and it stays in
  the image. The package comparison caught it.
- **`ETag`/`Last-Modified` differed on the default page** because our html files were dated at build time.
  Fixed with `install -p`.
- **nginx's `--with-openssl` rebuilt OpenSSL, including all of its test programs, in each of the 4 builds.**
  Building it once without tests took the build from 5+ minutes to about 1.5.
- Windows-specific: `core.autocrlf=true` would have broken scripts and patches in Linux containers
  (`.gitattributes` forces LF), Git Bash rewrites Linux paths passed to docker (`MSYS_NO_PATHCONV=1`), and a full
  disk made Docker's filesystem read-only mid-build.

## With more time

- VEX (OpenVEX) for CVE-2026-15176, and a rescan showing it gone.
- CI running `make deb`, `make image`, `make test` and a scan on every push.
- More nginx backports, or the move to a supported nginx line.
- Rebuild njs, so the image is a drop-in for configs that use it too.
- HTTP/2 and proxy (`proxy_pass` to an upstream) cases in the compatibility test.
- Smaller image: share one OpenSSL build between `nginx` and `nginx-debug` instead of two static copies.

## How AI tools were used

I used Claude Code (in the terminal) throughout.

What I used it for:
- explaining concepts I hadn't worked with before (Debian packaging, static vs dynamic linking, scanners, patch files)
- researching nginx advisories and finding the upstream fix commits
- drafting scripts, the Dockerfile, the Containerfile, the tests and the docs, which I then went through and changed
- running builds and checks, and reading the output

Where it helped: getting to a working from-source build and test setup much faster than I would have alone, and
explaining every command and flag so I could defend it.

Where it hurt or needed checking: it made confident guesses that were wrong and only came out when we verified:
- it relied on a summarized read of nginx's advisory page that miscounted the advisories affecting 1.25.5
  (22 instead of 28); reading the page directly fixed it
- it predicted the fixed build would return 500 (it returns 200 with an empty body)
- it overstated how reachable CVE-2024-5535 is through nginx
- it planned an OpenSSL 3.0.22 bump without checking what Debian already ships

Every claim in this repo is backed by a check that can be rerun, partly because of this.

Decisions I made: which CVEs to fix and keeping it to two, OpenSSL 3.5.9, keeping the image a strict drop-in
rather than smaller, and skipping the VEX bonus and CI to focus on the required parts.
