# Builds nginx from upstream source and packages it as .deb files.
# Run via `make deb`; the .deb files end up in ./out/
FROM debian:bookworm-slim@sha256:734a72b3d6142a71993b4bc580ca01d8ca687f77a2c422d96a961d3376b179bc AS build

# fail a RUN if any command in a pipe fails, not just the last one
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# compilers, download/verify tools, and the -dev headers nginx + modules compile against
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential ca-certificates curl gnupg \
      libpcre2-dev zlib1g-dev libssl-dev \
      libgeoip-dev libgd-dev libxslt1-dev libxml2-dev \
 && rm -rf /var/lib/apt/lists/*

ARG NGINX_VERSION=1.25.5
ARG NGINX_SHA256=2fe2294f8af4144e7e842eaea884182a84ee7970e11046ba98194400902bbec0
# nginx developers allowed to sign the release (Arutyunyan, Kandaurov)
ARG NGINX_GPG_FPRS="43387825DDB1BB97EC36BA5D007C8D7C15D87369 D6786CE303D9A9022998DC6CC8464D549AF75C0A"
# nginx's own packaging repo at tag 1.25.5-1: config files + maintainer scripts
ARG PKG_OSS_COMMIT=aaeb9a946f0dc8eb9848b3361e34db3d5424b234
ARG PKG_OSS_SHA256=f770921bd9636cf3897a7d265f7f4c24c10e407d5fe62d6496d46e25043cbcef

WORKDIR /src

# download nginx, check the checksum, check the signature is from a pinned key
RUN curl -fsSLO "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" \
 && curl -fsSLO "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz.asc" \
 && echo "${NGINX_SHA256}  nginx-${NGINX_VERSION}.tar.gz" | sha256sum -c - \
 && curl -fsSL https://nginx.org/keys/arut.key https://nginx.org/keys/pluknet.key | gpg --batch --import \
 && signer=$(gpg --batch --status-fd 1 --verify "nginx-${NGINX_VERSION}.tar.gz.asc" "nginx-${NGINX_VERSION}.tar.gz" 2>/dev/null \
             | awk '$2 == "VALIDSIG" {print $NF}') \
 && case " ${NGINX_GPG_FPRS} " in *" ${signer} "*) echo "signed by ${signer}" ;; *) echo "bad signature" >&2; exit 1 ;; esac \
 && tar xzf "nginx-${NGINX_VERSION}.tar.gz" \
 && mv "nginx-${NGINX_VERSION}" nginx

# download pkg-oss at the pinned commit and check its checksum
RUN curl -fsSL "https://codeload.github.com/nginx/pkg-oss/tar.gz/${PKG_OSS_COMMIT}" -o pkg-oss.tar.gz \
 && echo "${PKG_OSS_SHA256}  pkg-oss.tar.gz" | sha256sum -c - \
 && tar xzf pkg-oss.tar.gz \
 && mv "pkg-oss-${PKG_OSS_COMMIT}" pkg-oss

# apply our CVE patches (build/patches/*.patch); exact match only
COPY patches/ /patches/
RUN shopt -s nullglob; cd /src/nginx \
 && for p in /patches/*.patch; do echo "applying $p"; patch -p1 --fuzz=0 < "$p"; done

# four builds, same args as the original package:
#   nginx + nginx-debug, and the dynamic modules (built separately so they
#   don't show up in the main binary's `nginx -V`, same as upstream does)
COPY configure-args compile.sh /build/
ARG MODULE_ARGS="--with-http_geoip_module=dynamic --with-stream_geoip_module=dynamic --with-http_image_filter_module=dynamic --with-http_xslt_module=dynamic"
RUN /build/compile.sh nginx
RUN /build/compile.sh nginx-debug --with-debug
RUN MAKE_TARGET=modules /build/compile.sh modules ${MODULE_ARGS}
RUN MAKE_TARGET=modules /build/compile.sh modules-debug ${MODULE_ARGS} --with-debug

# turn the build output into .deb packages in /out
COPY build-deb.sh /build/
RUN /build/build-deb.sh

# empty final stage holding only the packages; `docker build --output` writes it to ./out
FROM scratch AS export
COPY --from=build /out/ /
