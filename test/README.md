# Tests

| Command | What it checks |
|---|---|
| `make test` | Compatibility test: same HTTP requests to `nginx:1.25-bookworm` and our image, responses must match |
| `make check-image` | Static comparison: image config, nginx file layout, nginx user, packages, size |
| `make check-cve` | Per-CVE checks: stock is vulnerable / ours is fixed (`cve-2026-15176/`, `cve-2024-5535/`) |

All of them build what they need first and exit non-zero on failure.

## What "working correctly" means

Our image is a drop-in replacement if, **given the same config and the same request bytes, it returns the
same response as `nginx:1.25-bookworm`**:

- the same status line
- the same headers, with the same names, values and order. The only exception is `Date`, which is the current time.
- the same body, byte for byte (large bodies compared by sha256)

This includes error responses: malformed requests must be rejected the same way, with the same error page.

On top of that, the image itself must look the same to anyone who runs it (`make check-image`): the same
entrypoint, command, port, stop signal, env, user (`nginx`, uid 101), working directory, and nginx file layout.

The only behaviour that is supposed to differ is the fixed CVE. The test asserts that this case **does**
differ, so it fails if the fix is ever missing.

## How the compatibility test works

`compat/compat_test.py` (Python, standard library only):

1. Generates test data in a temp folder: a deterministic 2 MB file and a self-signed TLS certificate.
2. Starts both images with identical arguments: random localhost ports, the same mounted config
   (`compat/conf.d/compat.conf`), template (`compat/templates/`), docroot and cert, and the same env.
   The normal entrypoint runs, so the entrypoint scripts are part of the test.
3. Sends each request as **raw bytes over a socket**. A normal HTTP library would clean up malformed
   requests; a socket sends exactly what's written.
4. Compares the full raw responses after removing the `Date` line, prints one line per case, and exits 1 if any
   case fails.

## What is covered

| Area | Cases |
|---|---|
| Default config (port 80, the image's own `default.conf`) | `GET /`, `HEAD /`, 404 page, `/50x.html`, `If-Modified-Since` -> 304 |
| HTTP versions and connections | HTTP/1.0, HTTP/0.9, two pipelined requests on one keep-alive connection |
| Malformed requests | garbage request line (400), HTTP/1.1 without Host (400), 9000-char URI (414), invalid header name (400), bare LF line endings, unknown method (405) |
| Static files (custom server) | text file, gzip, 2 MB file, single and multi range (206), ETag -> 304, directory redirect (301), directory index |
| Custom config | `return` with variables, `add_header` (incl. `always`), `rewrite`, regex location with capture, `try_files` fallback |
| Request bodies | small POST, POST over `client_max_body_size` (413), POST to a static file (405) |
| Entrypoint scripts | `/etc/nginx/templates/*.template` rendered with `envsubst` from an env var |
| TLS | HTTPS request; TLS version and cipher are printed (both TLSv1.3 `TLS_AES_256_GCM_SHA384`) |
| Fixed CVE | CVE-2026-15176 config: stock returns `/x` (path from a wrapped-around length), ours returns empty. Must differ. |

The test was also checked against itself: run with the stock image on both sides, the CVE case fails; with an extra
header added to one image, every affected case fails with the differing header shown.

## Known differences (intended)

- **CVE-2026-15176 case:** see above.
- **OpenSSL:** ours uses OpenSSL 3.5.9 instead of 3.0.11. Plain TLS 1.3 requests negotiate the same protocol and cipher.
  Clients that depend on very old ciphers or protocols may see differences, since defaults changed between 3.0 and 3.5.
- **njs is not rebuilt:** configs that `load_module` the njs module won't start (see `make check-image`).
- **Image labels:** ours has its own `org.opencontainers.image.*` labels instead of nginx's maintainer label.

## Not covered

- HTTP/2 and HTTP/3 framing: Python's standard library has no HTTP/2 client. `make check-cve` does one HTTP/2
  request with curl, and HTTP/3 isn't tested.
- Proxying to upstreams (`proxy_pass`, fastcgi, uwsgi, grpc), caching, the mail and stream modules
- The dynamic modules' behaviour (geoip, image-filter, xslt); `check-image` only checks they're present
- Performance, load, long-running behaviour, reloads (`nginx -s reload`) and graceful upgrades
