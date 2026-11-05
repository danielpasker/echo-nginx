"""Compatibility test: original nginx:1.25-bookworm vs our rebuilt image.

Starts both images with the same config, sends the same raw HTTP requests to
each, and compares the responses byte for byte (status line, headers, body).
Only the Date header is ignored. Exits 1 on any unexpected difference.

Usage (repo root):  python -I test/compat/compat_test.py
Env: IMAGE (ours, default echo-nginx:1.25.5), ORIG_IMAGE (default nginx:1.25-bookworm)
See test/README.md for what "working correctly" means and what is covered.
"""
import hashlib
import os
import re
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ORIG = os.environ.get("ORIG_IMAGE", "nginx:1.25-bookworm")
OURS = os.environ.get("IMAGE", "echo-nginx:1.25.5")
HERE = Path(__file__).resolve().parent
PORTS = [80, 8080, 8081, 8443]
TIMEOUT = 10


# ------------------------------------------------------------------ test cases
# (name, port, raw request bytes, expectation)
# expectation "same": responses must be identical (ignoring Date)
# expectation "differ": responses must differ (documented intended difference)
def req(line, *headers, body=b"", host="localhost"):
    head = [line] + ([f"Host: {host}"] if host else []) + list(headers) + ["Connection: close"]
    return ("\r\n".join(head) + "\r\n\r\n").encode() + body


CASES = [
    # default server (image's own default.conf), port 80
    ("GET / (default page)",         80,   req("GET / HTTP/1.1"), "same"),
    ("HEAD /",                       80,   req("HEAD / HTTP/1.1"), "same"),
    ("GET /missing (404 page)",      80,   req("GET /missing HTTP/1.1"), "same"),
    ("GET /50x.html",                80,   req("GET /50x.html HTTP/1.1"), "same"),
    ("If-Modified-Since -> 304",     80,   req("GET / HTTP/1.1", "If-Modified-Since: Tue, 16 Apr 2024 14:29:59 GMT"), "same"),
    ("HTTP/1.0 request",             80,   b"GET / HTTP/1.0\r\n\r\n", "same"),
    ("keep-alive, 2 pipelined",      80,   b"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n"
                                           b"GET /missing HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n", "same"),
    # malformed / unusual requests, port 80
    ("malformed request line",       80,   b"GARBAGE\r\n\r\n", "same"),
    ("HTTP/1.1 without Host",        80,   req("GET / HTTP/1.1", host=None), "same"),
    ("URI too long (9000 chars)",    80,   req("GET /" + "a" * 9000 + " HTTP/1.1"), "same"),
    ("invalid header name",          80,   req("GET / HTTP/1.1", "Bad Header: x"), "same"),
    ("bare LF line endings",         80,   b"GET / HTTP/1.1\nHost: localhost\nConnection: close\n\n", "same"),
    ("unknown method",               80,   req("BREW / HTTP/1.1"), "same"),
    ("HTTP/0.9 request",             80,   b"GET /\r\n", "same"),
    # custom config (conf.d/compat.conf), port 8080
    ("static text file",             8080, req("GET /hello.txt HTTP/1.1"), "same"),
    ("gzip",                         8080, req("GET /hello.txt HTTP/1.1", "Accept-Encoding: gzip"), "same"),
    ("large file (2 MB)",            8080, req("GET /big.bin HTTP/1.1"), "same"),
    ("Range: single",                8080, req("GET /big.bin HTTP/1.1", "Range: bytes=100-199"), "same"),
    ("Range: multiple",              8080, req("GET /big.bin HTTP/1.1", "Range: bytes=0-9,500-509"), "same"),
    ("ETag -> 304",                  8080, None, "same"),   # request built at runtime from the ETag
    ("directory without slash (301)", 8080, req("GET /dir HTTP/1.1"), "same"),
    ("directory index",              8080, req("GET /dir/ HTTP/1.1"), "same"),
    ("return with variables",        8080, req("GET /echo?a=1&b=2 HTTP/1.1"), "same"),
    ("add_header",                   8080, req("GET /headers HTTP/1.1"), "same"),
    ("rewrite",                      8080, req("GET /old/thing HTTP/1.1"), "same"),
    ("regex location",               8080, req("GET /item/42 HTTP/1.1"), "same"),
    ("try_files fallback",           8080, req("GET /spa/route HTTP/1.1"), "same"),
    ("POST small body (2 KB)",       8080, req("POST /echo HTTP/1.1", "Content-Length: 2048", body=b"x" * 2048), "same"),
    ("POST too large (413)",         8080, req("POST /echo HTTP/1.1", f"Content-Length: {2 * 1024 * 1024}"), "same"),
    ("POST to static file (405)",    8080, req("POST /hello.txt HTTP/1.1", "Content-Length: 3", body=b"abc"), "same"),
    # entrypoint: templates/*.template rendered with envsubst, port 8081
    ("envsubst template",            8081, req("GET / HTTP/1.1"), "same"),
    # TLS, port 8443
    ("HTTPS GET",                    8443, req("GET /hello.txt HTTP/1.1"), "same"),
    # intended difference: CVE-2026-15176 is fixed in our image
    ("CVE-2026-15176 alias+rewrite", 8080, req("GET /foo/1 HTTP/1.1"), "differ"),
]


# ------------------------------------------------------------------ helpers
def sh(*args, check=True):
    return subprocess.run(args, capture_output=True, text=True, check=check).stdout.strip()


def send(port, data, tls=False):
    """Send raw bytes, read until the server closes. Returns (bytes, tls_info)."""
    sock = socket.create_connection(("127.0.0.1", port), timeout=TIMEOUT)
    info = ""
    if tls:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE            # self-signed test cert
        sock = ctx.wrap_socket(sock, server_hostname="localhost")
        info = f"{sock.version()} {sock.cipher()[0]}"
    with sock:
        sock.sendall(data)
        chunks = []
        while True:
            try:
                chunk = sock.recv(65536)
            except (ConnectionResetError, socket.timeout):
                break
            if not chunk:
                break
            chunks.append(chunk)
    return b"".join(chunks), info


def normalize(resp):
    """Drop the Date header (it's the current time, always different)."""
    return re.sub(rb"(?im)^Date: [^\r\n]*\r?\n", b"", resp)


def describe(resp):
    """Short readable form: status line + headers, body as length + sha256."""
    head, sep, body = resp.partition(b"\r\n\r\n")
    if not sep:
        head, body = b"", resp
    text = head.decode("latin-1")
    return f"{text}\n<body {len(body)} bytes sha256={hashlib.sha256(body).hexdigest()[:16]}>"


def first_diff(a, b):
    la, lb = describe(a).splitlines(), describe(b).splitlines()
    for i in range(max(len(la), len(lb))):
        x = la[i] if i < len(la) else "<missing>"
        y = lb[i] if i < len(lb) else "<missing>"
        if x != y:
            return f"original: {x!r}\n        ours:     {y!r}"
    return "responses differ"


# ------------------------------------------------------------------ containers
def prepare_data(tmp):
    """Docroot for the custom server (html/ + a generated 2 MB file) and a TLS cert."""
    docroot = tmp / "docroot"
    shutil.copytree(HERE / "html", docroot)
    # deterministic 2 MB file: same bytes every run, no need to commit it
    block = hashlib.sha256(b"compat").digest() * 2048           # 64 KB
    (docroot / "big.bin").write_bytes(block * 32)               # 2 MB
    tls = tmp / "tls"
    tls.mkdir()
    sh("docker", "run", "--rm", "--entrypoint", "openssl",
       "--mount", f"type=bind,src={tls},dst=/tls", ORIG,
       "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=localhost",
       "-days", "2", "-keyout", "/tls/key.pem", "-out", "/tls/cert.pem")
    # one fixed mtime for everything mounted, so Last-Modified/ETag are stable
    for p in list(tmp.rglob("*")):
        os.utime(p, (1713277799, 1713277799))
    return docroot, tls


def start(name, image, docroot, tls):
    sh("docker", "rm", "-f", name, check=False)
    args = ["docker", "run", "-d", "--name", name, "-e", "COMPAT_GREETING=hello"]
    for p in PORTS:
        args += ["-p", f"127.0.0.1::{p}"]                       # random free host port
    mounts = [
        (HERE / "conf.d" / "compat.conf", "/etc/nginx/conf.d/compat.conf"),
        (HERE / "templates", "/etc/nginx/templates"),
        (docroot, "/srv/compat"),
        (tls, "/etc/nginx/tls"),
    ]
    for src, dst in mounts:
        args += ["--mount", f"type=bind,src={src},dst={dst},readonly"]
    sh(*args, image)
    ports = {}
    for p in PORTS:
        mapping = sh("docker", "port", name, f"{p}/tcp").splitlines()[0]   # e.g. 127.0.0.1:49153
        ports[p] = int(mapping.rsplit(":", 1)[1])
    return ports


def wait_ready(ports):
    for _ in range(30):
        try:
            if send(ports[80], req("GET / HTTP/1.1"))[0].startswith(b"HTTP/1.1 200") and \
               send(ports[8081], req("GET / HTTP/1.1"))[0].startswith(b"HTTP/1.1 200"):
                return
        except OSError:
            pass
        time.sleep(1)
    raise SystemExit("containers did not become ready")


def etag_request(ports):
    resp, _ = send(ports[8080], req("HEAD /hello.txt HTTP/1.1"))
    etag = re.search(rb"(?im)^ETag: ([^\r\n]+)", resp).group(1).decode()
    return req("GET /hello.txt HTTP/1.1", f"If-None-Match: {etag}")


# ------------------------------------------------------------------ main
def main():
    print(f"original: {ORIG}\nours:     {OURS}\n")
    failures = 0
    with tempfile.TemporaryDirectory() as t:
        tmp = Path(t)
        docroot, tls = prepare_data(tmp)
        names = {"orig": "compat-orig", "ours": "compat-ours"}
        try:
            ports = {"orig": start(names["orig"], ORIG, docroot, tls),
                     "ours": start(names["ours"], OURS, docroot, tls)}
            for side in ports.values():
                wait_ready(side)

            for name, port, data, expect in CASES:
                use_tls = port == 8443
                results = {}
                for side in ("orig", "ours"):
                    payload = data if data is not None else etag_request(ports[side])
                    resp, info = send(ports[side][port], payload, tls=use_tls)
                    results[side] = (normalize(resp), info)
                same = results["orig"][0] == results["ours"][0]
                # first line of the response (HTTP/0.9 has no status line, so this is body text)
                status = results["ours"][0].split(b"\n", 1)[0].strip().decode("latin-1")[:40] or "<empty>"
                ok = same if expect == "same" else not same
                label = "OK " if ok else "FAIL"
                note = "" if expect == "same" else "  (differs as expected)" if ok else "  (expected a difference)"
                print(f"[{label}] {name:32} {status}{note}")
                if use_tls:
                    print(f"       tls: original {results['orig'][1]} | ours {results['ours'][1]}")
                if not ok:
                    failures += 1
                    if expect == "same":
                        print("        " + first_diff(results["orig"][0], results["ours"][0]))
                elif expect == "differ":
                    for side in ("orig", "ours"):
                        body = results[side][0].partition(b"\r\n\r\n")[2]
                        print(f"        {side:4} body: {body!r}")
        finally:
            for n in names.values():
                sh("docker", "rm", "-f", n, check=False)

    print(f"\n{len(CASES) - failures}/{len(CASES)} cases passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
