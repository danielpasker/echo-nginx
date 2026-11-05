# Triage

Input: the baseline scans in `../baseline/` (Trivy 0.76.1, Grype 0.121.1, DBs from 2026-11-04).

## How the table was made

`triage.py` merges both JSON reports on (CVE, package) and writes:

- `all-findings.csv`: one row per finding (844 rows: 780 found by both scanners, 55 Trivy only, 9 Grype only)
- `summary.md`: counts per method, component and package

```
python -I triage/triage.py
```

Each package is mapped to the reason it's in the image. I worked this out by running
`apt-cache rdepends --installed` inside `nginx:1.25-bookworm`. Then every row gets one method:

| Method | Rows | Meaning |
|---|---|---|
| base-refresh | 276 | Debian already ships a fix, so rebuilding on a current `bookworm-slim` picks it up. Not claimed as our fix. |
| remove-candidate | 240 | No fix. The package is only there for the image-filter / xslt modules or curl. Kept so the image stays a drop-in. |
| accept (no fix) | 215 | Base OS packages with no fix (glibc, perl, systemd libs...). Residual risk. |
| bump (static openssl) | 98 | `libssl3` + `openssl` (49 each, same source). |
| backport-candidate | 8 | nginx itself |
| bump-candidate (not chosen) | 7 | pcre2, zlib |

Note: `fixed_version` is the **Debian** fixed version, because that's what the scanners report.
I only looked up upstream fix versions for the CVEs I picked.

Most of the count isn't nginx. The image-filter module's image libraries (203) and curl (173) make up
about half of all findings. nginx's own code has 8.

## Chosen CVEs

| CVE | Where | Severity (vendor / Grype) | Upstream fix | Method | Evidence |
|---|---|---|---|---|---|
| CVE-2026-15176 | nginx, `ngx_http_core_module.c` | medium / Critical | nginx 1.31.7, commit [`f8a23425`](https://github.com/nginx/nginx/commit/f8a23425bd6840c4c36b4264edf576ba3646156f) | backport | [check-cve-2026-15176.sh](check-cve-2026-15176.sh), [output](evidence/CVE-2026-15176.txt), [patch](../build/patches/CVE-2026-15176.patch), [runtime check](../test/cve-2026-15176/result.txt) |
| CVE-2024-5535 | OpenSSL `SSL_select_next_proto()` | Low / Critical | OpenSSL 3.0.15 / 3.3.2 | bump to OpenSSL 3.5.9 LTS, linked statically into nginx | [check-cve-2024-5535.sh](check-cve-2024-5535.sh), [output](evidence/CVE-2024-5535.txt), [runtime check](../test/cve-2024-5535/result.txt) |

### CVE-2026-15176: backport

A buffer overflow when a location uses `alias` and the URI is changed by `rewrite`. nginx then maps the shorter
rewritten URI as if it still had the location prefix. Reproducer from the fix commit:

```nginx
location /foo/ { alias /bar/; rewrite ^/foo/.*$ /x; return 200 $request_filename; }
```

Why this one:
- Grype flags it (Critical), so fixing it addresses a finding a real scanner reports.
- The fix is a single condition: `if (alias && !r->valid_location)` becomes `if (alias && (!r->valid_location || r->uri_changed))`.
  `uri_changed` already exists in 1.25.5, so nothing else needs backporting.
- It can be tested at runtime with the config above (stock vs patched behave differently).

Evidence: the buggy line is in the 1.25.5 source (line 1887), and the upstream commit applies with
`patch --fuzz=0` (offset -103 lines, which only means the same code sits higher up in the older file).

Shipped as [`build/patches/CVE-2026-15176.patch`](../build/patches/CVE-2026-15176.patch) (diff regenerated
against 1.25.5). `make check-cve` runs the same config on stock and on our build
([result](../test/cve-2026-15176/result.txt)):
- stock: `malloc(18446744073709551606) failed` in the error log, i.e. a length of -10 wrapped around to 2^64-10
- ours: `"alias" cannot be used in location ... where URI was rewritten`, no bad length computed. The response is still
  200 because the config uses `return 200`; only `$request_filename` comes out empty.

### CVE-2024-5535: bump

`SSL_select_next_proto()` with an empty client protocol list reads past the buffer and can send up to
255 bytes of memory to the peer. The image runs OpenSSL 3.0.11. The fix is in 3.0.15.

Why this one:
- nginx calls this function itself, in its ALPN callback (http, stream and mail SSL modules), during
  the TLS handshake.
- How exploitable it is through nginx: low. The bug needs an *empty* client protocol list, and OpenSSL's
  server side rejects an empty ALPN extension before nginx's callback runs (`tls_parse_ctos_alpn`
  requires at least 2 bytes). OpenSSL's advisory says the same: "In the case of ALPN the list of protocols
  supplied by the client is guaranteed by libssl to never be zero in length", which is why it's rated Low.
  I still count it as eliminated: the vulnerable library version is gone from nginx.

Why 3.5.9 and not 3.0.x: I first planned 3.0.22 (same 3.0 API nginx was built against). But when I
built from source, today's bookworm already ships `libssl3 3.0.22-1~deb12u2`, so a plain rebuild already
gets 3.0.22 and that would only be a base refresh, not a bump. 3.5.9 is the current LTS (supported until
April 2030), newer than anything bookworm ships, and 3.0 is out of support upstream.

Same bump also fixes CVE-2024-6119 (crash in certificate hostname checks, reachable with `proxy_ssl_verify`).

How it's built: `--with-openssl=/src/openssl` in `build/configure-args`. The OpenSSL tarball is checked
against its sha256 and OpenSSL's release signing key, built once as static libraries, and linked into
`nginx` / `nginx-debug`. `libssl3` is no longer in the nginx package's `Depends`.

Evidence:
- [triage check](evidence/CVE-2024-5535.txt): the sha256 of `openssl-3.5.9.tar.gz` matches the published
  one, nginx 1.25.5 calls `SSL_select_next_proto` in 3 places, and OpenSSL 3.5.9's `CHANGES.md` has the fix
  (under 3.3.2; the 3.0 branch got it in 3.0.15).
- [runtime check](../test/cve-2024-5535/result.txt) (`make check-cve`): stock is built with 3.0.9 and loads
  `libssl.so.3` 3.0.11; ours is built with OpenSSL 3.5.9 and `ldd` shows no `libssl`/`libcrypto`. A TLS
  request with ALPN h2 over HTTP/2 works on ours.

Limitations:
- OpenSSL compiled into nginx is invisible to scanners. They only see the `libssl3` package, which stays in
  the image because curl and the base need it.
- Debian's OpenSSL updates no longer reach nginx. A new OpenSSL fix means rebuilding.
- The nginx package grows from ~0.85 MB to ~5 MB (OpenSSL is now inside `nginx` and `nginx-debug`).

## Scanner blind spots

- Trivy reports **0** nginx CVEs. nginx.org lists 28 advisories that affect 1.25.5. My understanding is
  that Trivy compares the nginx.org package version (`1.25.5-1~bookworm`) against Debian's own nginx
  package, sees a newer version and treats it as fixed.
- Example: CVE-2024-7347 (mp4 module) affects 1.25.5 and nginx publishes a patch for it, but neither
  scanner reports it. I checked it but didn't ship it, to keep the scope at two fixes.
- Severity differs between sources: Grype rates the nginx CVEs Critical, nginx rates them medium. OpenSSL
  rates CVE-2024-5535 Low, Grype rates it Critical.

## Not chosen

- pcre2 / zlib bumps: possible, but OpenSSL has more CVEs and one nginx clearly uses.
- Removing image-filter / xslt / curl: would drop a lot of findings but breaks drop-in compatibility.
  Removal also doesn't count for the assignment.
- CVE-2026-97629 (TLS ticket keys, 1-line fix) and CVE-2026-95101 (HTTP/3, 4 lines): both apply to 1.25.5,
  but they're harder to demonstrate than CVE-2026-15176.
- OpenSSL 3.0.22: already what current bookworm ships, so it's a base refresh, not a bump (see above).

## Open items

- CVE-2026-93479 (Grype: Critical on nginx) is a false positive for 1.25.5: nginx.org lists it as vulnerable only in 1.30.0-1.30.5 and 1.31.2-1.31.6 (a regression in newer releases).
- Upstream fix versions for the other ~840 rows not looked up.
