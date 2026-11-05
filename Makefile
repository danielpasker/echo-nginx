# One-command build. Run from Git Bash or Linux.
# Git Bash would rewrite Linux-style paths passed to docker; this turns that off.
export MSYS_NO_PATHCONV=1

.PHONY: deb check-cve clean

# build nginx from source in a clean debian:bookworm-slim, write the .deb files to ./out/
deb:
	docker build --target export --output type=local,dest=out build/

# Per-CVE checks, stock vs our build. Output saved as evidence in result.txt.
#   CVE-2026-15176 (backport): stock shows the bug, ours refuses the mapping
#   CVE-2024-5535  (bump):     ours is built with OpenSSL 3.5.9, loads no system libssl
CVES = cve-2026-15176 cve-2024-5535

check-cve: deb
	@status=0; for c in $(CVES); do \
	  bash test/$$c/check.sh > test/$$c/result.txt || status=1; \
	  cat test/$$c/result.txt; echo; \
	done; exit $$status

clean:
	rm -rf out/
