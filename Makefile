# One-command build. Run from Git Bash or Linux.
# Git Bash would rewrite Linux-style paths passed to docker; this turns that off.
export MSYS_NO_PATHCONV=1

.PHONY: deb check-cve clean

# build nginx from source in a clean debian:bookworm-slim, write the .deb files to ./out/
deb:
	docker build --target export --output type=local,dest=out build/

# CVE-2026-15176: stock nginx must show the bug, our build must refuse the request.
# Output is saved as evidence in result.txt.
check-cve: deb
	bash test/cve-2026-15176/check.sh > test/cve-2026-15176/result.txt; \
	  status=$$?; cat test/cve-2026-15176/result.txt; exit $$status

clean:
	rm -rf out/
