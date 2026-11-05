# Final image: our nginx .debs (from `make deb`) installed into a clean
# bookworm-slim, laid out exactly like nginx:1.25-bookworm.
# Mirrors nginx/docker-nginx mainline/debian/Dockerfile at tag 1.25.5.
FROM debian:bookworm-slim@sha256:734a72b3d6142a71993b4bc580ca01d8ca687f77a2c422d96a961d3376b179bc

LABEL org.opencontainers.image.title="echo-nginx" \
      org.opencontainers.image.version="1.25.5" \
      org.opencontainers.image.description="nginx 1.25.5 rebuilt from source with CVE fixes, drop-in for nginx:1.25-bookworm" \
      org.opencontainers.image.source="https://github.com/danielpasker/echo-nginx"

# same values as the original image (scripts may read them)
ENV NGINX_VERSION=1.25.5
ENV NJS_VERSION=0.8.4
ENV NJS_RELEASE=3~bookworm
ENV PKG_RELEASE=1~bookworm

# nginx user/group with the same fixed ids as upstream (101), created before
# the package so its preinst doesn't pick a random id
RUN groupadd --system --gid 101 nginx \
 && useradd --system --gid nginx --no-create-home --home /nonexistent \
      --comment "nginx user" --shell /bin/false --uid 101 nginx

# install our packages; out/ is bind-mounted only for this step so the .deb
# files never end up in an image layer.
# gettext-base: envsubst for 20-envsubst-on-templates.sh; curl and
# ca-certificates (CA bundle for HTTPS upstreams) are in the original too.
RUN --mount=type=bind,source=out,target=/debs \
    apt-get update \
 && apt-get install --no-install-recommends --no-install-suggests -y \
      /debs/*.deb gettext-base curl ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
# forward request and error logs to docker log collector
 && ln -sf /dev/stdout /var/log/nginx/access.log \
 && ln -sf /dev/stderr /var/log/nginx/error.log \
 && mkdir /docker-entrypoint.d

# upstream entrypoint scripts, pinned to docker-nginx tag 1.25.5 and checked
# against the sha256 of the files in nginx:1.25-bookworm
ARG ENTRYPOINT_URL=https://raw.githubusercontent.com/nginx/docker-nginx/29d5001c15e7a2c7b34402c35254cc55199f8cc8/mainline/debian
ADD --chmod=755 --checksum=sha256:3372fd90162da30d09f62c245e9c6bfd620fb0bb5b48ab54b16e804c2b9e8aae \
    ${ENTRYPOINT_URL}/docker-entrypoint.sh /docker-entrypoint.sh
ADD --chmod=755 --checksum=sha256:8c5d2c912416126c7d65651600b166c00ad9ca3e3af82487ddd5a5da94fb8fb5 \
    ${ENTRYPOINT_URL}/10-listen-on-ipv6-by-default.sh /docker-entrypoint.d/10-listen-on-ipv6-by-default.sh
ADD --chmod=755 --checksum=sha256:3659a4a271496f6a8f0785a1d7e57a9348803e90c08fe57431fe3ee19b010644 \
    ${ENTRYPOINT_URL}/15-local-resolvers.envsh /docker-entrypoint.d/15-local-resolvers.envsh
ADD --chmod=755 --checksum=sha256:253c8724acff9f5c0d0e8938e71fe7c33097d40031a5bc9c7f59dfd2ba5f1377 \
    ${ENTRYPOINT_URL}/20-envsubst-on-templates.sh /docker-entrypoint.d/20-envsubst-on-templates.sh
ADD --chmod=755 --checksum=sha256:1f068aa49da8df46bfd5a917debf110af9b115370739e3be34af83ebf583fbce \
    ${ENTRYPOINT_URL}/30-tune-worker-processes.sh /docker-entrypoint.d/30-tune-worker-processes.sh

ENTRYPOINT ["/docker-entrypoint.sh"]

EXPOSE 80

# graceful shutdown: finish in-flight requests
STOPSIGNAL SIGQUIT

# no USER / WORKDIR, same as upstream: the master runs as root to bind :80,
# workers drop to "nginx" via `user nginx;` in nginx.conf
CMD ["nginx", "-g", "daemon off;"]
