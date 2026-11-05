#!/usr/bin/env bash
# Is echo-nginx a drop-in for nginx:1.25-bookworm? Compares:
#   1. image config (entrypoint, cmd, ports, stop signal, env, user, workdir) - must match
#   2. filesystem layout of nginx's files (path, type, mode, owner, link target) - must match,
#      except the njs module files (njs isn't rebuilt, see README)
#   3. the nginx user and group - must match
#   4. installed packages - informational
#   5. image size - informational
#   6. smoke test: start normally, GET / gives the same status + body, graceful stop
# Exits non-zero on any unexpected difference.
set -uo pipefail
export MSYS_NO_PATHCONV=1                      # Git Bash: don't rewrite container paths

ORIG=nginx:1.25-bookworm
OURS=${IMAGE:-echo-nginx:1.25.5}
fail=0
check() {   # check <title> <orig output> <ours output>
    if [ "$2" = "$3" ]; then echo "  OK    $1"
    else echo "  DIFF  $1"; diff <(echo "$2") <(echo "$3") | sed 's/^/        /'; fail=1; fi
}
run() { docker run --rm --entrypoint sh "$1" -c "$2"; }

echo "== 1. image config"
for f in Entrypoint Cmd ExposedPorts StopSignal Env User WorkingDir; do
    check "$f" "$(docker inspect --format "{{json .Config.$f}}" $ORIG)" \
               "$(docker inspect --format "{{json .Config.$f}}" $OURS)"
done
echo "  info  Labels differ on purpose: ours doesn't claim nginx's maintainer label"

echo "== 2. filesystem layout"
LAYOUT='find /etc/nginx /usr/share/nginx /usr/lib/nginx /var/cache/nginx /var/log/nginx \
  /docker-entrypoint.d /docker-entrypoint.sh /usr/sbin/nginx /usr/sbin/nginx-debug \
  /etc/default/nginx /etc/default/nginx-debug /etc/init.d/nginx /etc/init.d/nginx-debug \
  /etc/logrotate.d/nginx /lib/systemd/system/nginx.service /lib/systemd/system/nginx-debug.service \
  -printf "%p %y %m %u:%g %l\n" | sort'
NJS='/usr/lib/nginx/modules/ngx_(http|stream)_js_module'     # expected: njs not rebuilt
orig=$(run $ORIG "$LAYOUT")
check "nginx files (excluding njs)" "$(echo "$orig" | grep -Ev "$NJS")" "$(run $OURS "$LAYOUT")"
echo "  info  njs files only in original: $(echo "$orig" | grep -cE "$NJS")"

echo "== 3. nginx user and group"
check "user/group" "$(run $ORIG 'getent passwd nginx; getent group nginx')" \
                   "$(run $OURS 'getent passwd nginx; getent group nginx')"

echo "== 4. packages"
# expected: only njs and its dependency libedit2 are missing from ours
PKGS='dpkg-query -W -f "\${Package}\n" | sort'
pdiff=$(diff <(run $ORIG "$PKGS") <(run $OURS "$PKGS") | grep '^[<>]')
echo "$pdiff" | sed 's/^</  only in original:/; s/^>/  only in ours:    /'
check "package names (excluding njs, libedit2)" \
      "" "$(echo "$pdiff" | grep -Ev '^< (nginx-module-njs|libedit2)$' || true)"
echo "  nginx package: $(run $ORIG 'dpkg-query -W -f "\${Version}" nginx') -> $(run $OURS 'dpkg-query -W -f "\${Version}" nginx')"

echo "== 5. image size (informational)"
for i in $ORIG $OURS; do
    printf '  %-22s %s MB\n' $i "$(( $(docker image inspect --format '{{.Size}}' $i) / 1000000 ))"
done

echo "== 6. smoke test"
smoke() {   # start the image the normal way (entrypoint + cmd), request /, stop it
    docker rm -f smoke-test >/dev/null 2>&1
    docker run -d --name smoke-test "$1" >/dev/null
    for _ in $(seq 30); do docker exec smoke-test curl -sf -o /dev/null http://localhost/ && break; sleep 1; done
    docker exec smoke-test curl -s -w '\nstatus %{http_code}' http://localhost/ | md5sum | cut -c1-12
    docker stop smoke-test >/dev/null                      # sends SIGQUIT (graceful)
    echo "exit $(docker inspect --format '{{.State.ExitCode}}' smoke-test)"
    docker rm smoke-test >/dev/null
}
check "GET / (body+status md5) and exit code after docker stop" "$(smoke $ORIG)" "$(smoke $OURS)"

echo
[ $fail = 0 ] && echo "RESULT: drop-in (config, layout, user, behaviour match; njs not rebuilt)" \
              || echo "RESULT: FAIL, unexpected differences above"
exit $fail
