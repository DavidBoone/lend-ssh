#!/usr/bin/env bash
# Runs the tests in Docker, with only Docker here. "run" runs test/run.sh in
# a container that has sshd, so nothing is skipped; "real" runs test/real.sh,
# which lends access between real machines, containers on a network of their
# own:
#
#   lender     runs lend-ssh as "me", with this Docker's socket
#   host1      sshd, with the accounts lent: dave and deploy
#   agentbox   sshd, with user agent: an agent at ssh://
#   agentc     a container running as agent: an agent at docker://
#   a volume   agent's home: an agent at docker-volume://
#
# With neither, it runs both; arguments after "real" go to test/real.sh, to
# run only the test files whose names contain one.
#
# The containers are siblings in the Docker the docker command here uses.
# Everything it creates carries the label lend-ssh-test-PID-RANDOM, and the
# containers, volume and network go when it ends; the image, lend-ssh-test,
# stays as a cache.
#
#   LEND_SSH_TEST_SOCKET  the Docker socket, as a path on the Docker host
#                         (default /var/run/docker.sock)
set -euo pipefail

root=$(cd "${0%/*}/.." && pwd)
what=${1:-both}
case $what in
  run | both) ;;
  real) shift ;;
  *) echo "usage: test/docker.sh [run | real [FILE...]]" >&2; exit 2 ;;
esac
image=lend-ssh-test
id=lend-ssh-test-$$-$RANDOM
socket=${LEND_SSH_TEST_SOCKET:-/var/run/docker.sock}
ctx=$(mktemp -d)

# shellcheck disable=SC2317,SC2329  # the EXIT trap runs it
cleanup() {
  local ids
  rm -rf "$ctx"
  ids=$(docker ps -aq --filter "label=$id")
  # shellcheck disable=SC2086  # container ids are words
  [[ -z $ids ]] || docker rm -f $ids >/dev/null
  docker volume rm -f "$id-home" >/dev/null 2>&1 || true
  docker network rm "$id" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# The files git has or would add, as they are now.
git -C "$root" ls-files -co --exclude-standard -z |
  while IFS= read -rd '' f; do [[ ! -e $root/$f ]] || printf '%s\0' "$f"; done |
  tar -C "$root" --null -T - -cf - | tar -C "$ctx" -xf -
docker build -q -t "$image" -f "$ctx/test/Dockerfile" "$ctx" >/dev/null

status=0
if [[ $what != real ]]; then
  docker run --rm --label "$id" -u me -e SSHD=/usr/sbin/sshd "$image" test/run.sh || status=1
fi
[[ $what != run ]] || exit "$status"

# start NAME ARGS...: starts container NAME, $id-NAME, on the network, also
# reachable there as NAME.
start() {
  local name=$1
  shift
  docker run -d --label "$id" --name "$id-$name" --hostname "$name" \
    --network "$id" --network-alias "$name" "$@" >/dev/null
}

docker network create --label "$id" "$id" >/dev/null
# A new volume takes the files of the directory it's mounted on, so agent's
# home in it is agent's.
docker volume create --label "$id" "$id-home" >/dev/null
docker run --rm --label "$id" -v "$id-home:/home/agent" "$image" true
start host1 "$image"
start agentbox "$image"
start agentc -u agent "$image" sleep infinity
gid=$(docker run --rm --label "$id" -v "$socket:/var/run/docker.sock" "$image" stat -c %g /var/run/docker.sock)
start lender -v "$socket:/var/run/docker.sock" --group-add "$gid" "$image" sleep infinity

# me logs in to dave, deploy and agent with its own key, and knows the hosts.
lender=$id-lender
docker exec -u me "$lender" ssh-keygen -q -t ed25519 -N '' -C me@lender -f /home/me/.ssh/id_ed25519
pub=$(docker exec "$lender" cat /home/me/.ssh/id_ed25519.pub)
for c in host1:dave host1:deploy agentbox:agent; do
  docker exec -i "$id-${c%%:*}" sh -c 'u=$1; install -d -m 700 -o "$u" -g "$u" "/home/$u/.ssh"
    cat >>"/home/$u/.ssh/authorized_keys"; chown "$u:" "/home/$u/.ssh/authorized_keys"' _ "${c#*:}" <<<"$pub"
done
tries=0
until docker exec -u me "$lender" sh -c 'ssh-keyscan -t ed25519 host1 agentbox 2>/dev/null | grep -v "^#" >~/.ssh/known_hosts; [ "$(wc -l <~/.ssh/known_hosts)" -eq 2 ]'; do
  ((++tries < 50)) || { echo "test/docker.sh: sshd didn't start" >&2; exit 1; }
  sleep 0.2
done

docker exec -u me -e "LEND_SSH_TEST_ID=$id" -e "LEND_SSH_TEST_IMAGE=$image" "$lender" test/real.sh "$@" || status=1
exit "$status"
