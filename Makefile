# One-command build. Run from Git Bash or Linux.
# Git Bash would rewrite Linux-style paths passed to docker; this turns that off.
export MSYS_NO_PATHCONV=1

.PHONY: deb clean

# build nginx from source in a clean debian:bookworm-slim, write the .deb files to ./out/
deb:
	docker build --target export --output type=local,dest=out build/

clean:
	rm -rf out/
