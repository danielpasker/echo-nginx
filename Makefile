# One-command build. Run from Git Bash or Linux.
# Git Bash would rewrite Linux-style paths passed to docker; this turns that off.
export MSYS_NO_PATHCONV=1

IMAGE = echo-nginx:1.25.5
export IMAGE

PYTHON ?= python

.PHONY: deb image test check-image check-cve scan clean

# build nginx from source in a clean debian:bookworm-slim, write the .deb files to ./out/
deb:
	docker build --target export --output type=local,dest=out build/

# final image: install the .debs into bookworm-slim (Containerfile)
image: deb
	docker build -f Containerfile -t $(IMAGE) .

# compatibility test: same requests to nginx:1.25-bookworm and our image, responses
# must match (see test/README.md). Exits non-zero on any mismatch.
test: image
	$(PYTHON) -I test/compat/compat_test.py

# compare our image with nginx:1.25-bookworm (config, layout, user, size, smoke test)
check-image: image
	bash test/compare-image.sh > test/compare-image.txt; \
	  status=$$?; cat test/compare-image.txt; exit $$status

# Per-CVE checks, stock vs our image. Output saved as evidence in result.txt.
#   CVE-2026-15176 (backport): stock shows the bug, ours refuses the mapping
#   CVE-2024-5535  (bump):     ours is built with OpenSSL 3.5.9, loads no system libssl
CVES = cve-2026-15176 cve-2024-5535

check-cve: image
	@status=0; for c in $(CVES); do \
	  bash test/$$c/check.sh > test/$$c/result.txt || status=1; \
	  cat test/$$c/result.txt; echo; \
	done; exit $$status

# rescan our image with the same pinned scanners as baseline/ (input for the
# README's residual risk section). Reports go to rescan/.
TRIVY = aquasec/trivy:0.76.1
GRYPE = anchore/grype:v0.121.1
HOSTDIR := $(shell pwd -W 2>/dev/null || pwd)
SOCK = -v /var/run/docker.sock:/var/run/docker.sock
TRIVY_RUN = docker run --rm $(SOCK) -v trivy-cache:/root/.cache -v "$(HOSTDIR)/rescan:/out" $(TRIVY)
GRYPE_RUN = docker run --rm $(SOCK) -v grype-db:/grype-db -e GRYPE_DB_CACHE_DIR=/grype-db -v "$(HOSTDIR)/rescan:/out" $(GRYPE)

scan: image
	mkdir -p rescan
	$(TRIVY_RUN) image -q --format table --output /out/trivy.txt $(IMAGE)
	$(TRIVY_RUN) image -q --format json --output /out/trivy.json $(IMAGE)
	$(GRYPE_RUN) -q $(IMAGE) -o table --file /out/grype.txt
	$(GRYPE_RUN) -q $(IMAGE) -o json --file /out/grype.json
	{ docker run --rm -v trivy-cache:/root/.cache $(TRIVY) version; \
	  docker run --rm -v grype-db:/grype-db -e GRYPE_DB_CACHE_DIR=/grype-db $(GRYPE) db status; \
	  date -u; } > rescan/scanner-versions.txt

clean:
	rm -rf out/
