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
| CVE-2024-5535 | OpenSSL `SSL_select_next_proto()` | Low / Critical | OpenSSL 3.0.15 | bump to OpenSSL 3.0.22, linked statically into nginx | [check-cve-2024-5535.sh](check-cve-2024-5535.sh), [output](evidence/CVE-2024-5535.txt) |

### CVE-2026-15176: backport

A buffer overflow when a location uses `alias` and the URI is changed by `rewrite`. nginx then maps the shorter
rewritten URI as if it still had the location prefix. Reproducer from the fix commit:

```nginx
location /foo/ { alias /bar/; rewrite ^/foo/.*$ /x; return 200 $request_filename; }
```

Why this one:
- Grype flags it, so I can show it disappearing with VEX later.
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
- nginx calls this function itself, in its ALPN callback (http, stream and mail SSL modules). That
  callback runs during the TLS handshake on every HTTPS connection. So it's code nginx actually runs.

Why 3.0.22: it's the last 3.0.x release, so it's the same API nginx 1.25.5 was built against (3.0.9). It
also covers every libssl3 CVE in the scan. The downside is that 3.0 is now out of support upstream (see below).

Same bump also fixes CVE-2024-6119 (crash in certificate hostname checks, reachable with `proxy_ssl_verify`).

Evidence: the sha256 of `openssl-3.0.22.tar.gz` matches the published one. nginx 1.25.5 calls
`SSL_select_next_proto` in 3 places. OpenSSL's own `CHANGES.md` lists the fix under 3.0.15.

Limitation: OpenSSL compiled into nginx is invisible to scanners. The `libssl3` package stays in the image
because curl and the base need it. Proof for the bump is `nginx -V` ("built with OpenSSL 3.0.22") and
`ldd` showing nginx no longer loads `libssl.so`.

## Scanner blind spots

- Trivy reports **0** nginx CVEs. nginx.org lists 22 advisories that affect 1.25.5. My understanding is
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
- OpenSSL 3.5 LTS: supported until 2030, but a bigger jump for nginx 1.25.5. It's the next step.

## Open items

- CVE-2026-93479 (Grype: Critical on nginx) not investigated. Affected range needs checking.
- Upstream fix versions for the other ~840 rows not looked up.
