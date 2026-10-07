# shellcheck shell=bash disable=SC2154  # lend_ssh and the rest are test/real.sh's
# Agents at docker://CONTAINER/PATH (agentc) and docker-volume://VOLUME/PATH
# (agent's home in the volume), against the real Docker daemon.

# docker_files WHERE PATH...: prints owner, mode and name of each PATH, as
# root in agentc ("agentc") or in a container with the volume as agent's
# home ("volume"), one per line.
docker_files() {
  local where=$1
  shift
  case $where in
    agentc) docker exec -u root "$id-agentc" stat -c '%U %a %n' "$@" ;;
    volume) docker run --rm --label "$id" -v "$id-home:/home/agent" "$image" stat -c '%U %a %n' "$@" ;;
  esac
}

# docker_reset: takes agent's ~/.ssh out of agentc and the volume, starts
# agentc if it's stopped, and removes the setup on host1.
docker_reset() {
  docker start "$id-agentc" >/dev/null
  docker exec -u root "$id-agentc" rm -rf /home/agent/.ssh
  docker run --rm --label "$id" -v "$id-home:/home/agent" "$image" rm -rf /home/agent/.ssh
  "$lend_ssh" account rm dave@host1 >/dev/null 2>&1
  "$lend_ssh" account rm deploy@host1 >/dev/null 2>&1
}

# oneline COMMAND...: COMMAND's output and errors as one line, and its status.
oneline() {
  "$@" 2>&1 | tr '\n' ' '
  return "${PIPESTATUS[0]}"
}

# The containers lend-ssh's volume runs left: any using the volume.
volume_containers() {
  docker ps -aq --filter "volume=$id-home"
}

real_docker_container() {
  local loc=docker://$id-agentc/~/.ssh/id_ed25519.pub
  make_ca
  "$lend_ssh" account add dave@host1 deploy@host1 >/dev/null
  expect "docker: agent add creates a key in a container" 0 \
    "^created a key at docker://$id-agentc/~/.ssh/id_ed25519, without a passphrase$" "$lend_ssh" agent add c "$loc"
  expect "... it belongs to the container's user, in a .ssh only it reads" 0 \
    '^agent 700 /home/agent/.ssh agent 600 /home/agent/.ssh/id_ed25519 agent 644 /home/agent/.ssh/id_ed25519.pub $' \
    oneline docker_files agentc /home/agent/.ssh /home/agent/.ssh/id_ed25519 /home/agent/.ssh/id_ed25519.pub
  expect "... agent lists it at its location" 0 "^c	$loc$" "$lend_ssh" agent
  expect "docker: grant to an agent in a container" 0 '^c: dave@host1 \(new\), deploy@host1 \(new\) until ' \
    "$lend_ssh" grant -t 1h c dave@host1 deploy@host1
  expect "... writes the certificate there, the agent's" 0 '^agent 644 /home/agent/.ssh/id_ed25519-cert.pub$' \
    docker_files agentc /home/agent/.ssh/id_ed25519-cert.pub
  expect "... the agent logs in from the container" 0 '^dave$' agent_ssh agentc dave whoami
  expect "... to both accounts" 0 '^deploy$' agent_ssh agentc deploy whoami
  expect "docker: revoke narrows the certificate in the container" 0 '^c: revoked deploy@host1; keeps dave@host1' \
    "$lend_ssh" revoke c deploy@host1
  expect "... the agent can't log in to the account revoked" fail 'Permission denied' agent_ssh agentc deploy whoami
  expect "... and still logs in to the other" 0 '^dave$' agent_ssh agentc dave whoami
  expect "docker: revoke removes the certificate in the container" 0 '^c: revoked dave@host1' "$lend_ssh" revoke c
  expect "... it's gone there" fail 'No such file' docker_files agentc /home/agent/.ssh/id_ed25519-cert.pub
  expect "... the agent can't log in" fail 'Permission denied' agent_ssh agentc dave whoami
  expect "docker: agent add of a key already in a container" 0 "^added agent c2: $loc$" "$lend_ssh" agent add c2 "$loc"
  "$lend_ssh" grant -t 1h c dave@host1 >/dev/null
  expect "docker: agent rm with a grant removes the certificate in the container" 0 'removed agent c$' "$lend_ssh" agent rm c
  expect "... it's gone there" fail 'No such file' docker_files agentc /home/agent/.ssh/id_ed25519-cert.pub
  expect "docker: agent add in a container that isn't there" 1 "No such container.*couldn't read docker://$id-none/" \
    oneline "$lend_ssh" agent add x "docker://$id-none/~/.ssh/id_ed25519.pub"
  "$lend_ssh" agent rm c2 >/dev/null
  docker_reset
}

# docker_volume_add NAME: agent add NAME in the volume creates a key, owned by
# agent, which logs in with it once granted; then the volume has no key
# again. LEND_SSH_VOLUME_IMAGE is the caller's.
docker_volume_add() {
  local name=$1 loc=docker-volume://$id-home/.ssh/id_ed25519.pub
  expect "docker: agent add creates a key in a volume ($name)" 0 \
    "^created a key at docker-volume://$id-home/.ssh/id_ed25519, without a passphrase$" "$lend_ssh" agent add "$name" "$loc"
  expect "... it belongs to the owner of the volume's top, in a .ssh only it reads" 0 \
    '^agent 700 /home/agent/.ssh agent 600 /home/agent/.ssh/id_ed25519 agent 644 /home/agent/.ssh/id_ed25519.pub $' \
    oneline docker_files volume /home/agent/.ssh /home/agent/.ssh/id_ed25519 /home/agent/.ssh/id_ed25519.pub
  expect "... grant" 0 "^$name: dave@host1 \\(new\\) until " "$lend_ssh" grant -t 1h "$name" dave@host1
  expect "... writes the certificate there, owned alike" 0 '^agent 644 /home/agent/.ssh/id_ed25519-cert.pub$' \
    docker_files volume /home/agent/.ssh/id_ed25519-cert.pub
  expect "... the agent logs in with the volume as its home" 0 '^dave$' agent_ssh volume dave whoami
  expect "... revoke removes it there" 0 "^$name: revoked dave@host1" "$lend_ssh" revoke "$name"
  expect "... the agent can't log in" fail 'Permission denied' agent_ssh volume dave whoami
  expect "... lend-ssh's containers are gone" 0 '^$' volume_containers
  "$lend_ssh" agent rm "$name" >/dev/null
  docker run --rm --label "$id" -v "$id-home:/home/agent" "$image" rm -rf /home/agent/.ssh
}

real_docker_volume() {
  make_ca
  "$lend_ssh" account add dave@host1 >/dev/null
  docker_volume_add alpine
  # A docker on PATH that logs each command line, to see which image lend-ssh
  # ran on the volume.
  mkdir "$work/bin"
  printf '#!/bin/sh\necho "$*" >>%q\nexec %q "$@"\n' "$work/docker.log" "$(command -v docker)" >"$work/bin/docker"
  chmod +x "$work/bin/docker"
  PATH=$work/bin:$PATH LEND_SSH_VOLUME_IMAGE=$image docker_volume_add image
  check "... lend-ssh ran the volume in that image" grep -q -- "-v $id-home:[^ ]* $image " "$work/docker.log"
  check "... and in no other" test -z "$(grep -- "-v $id-home:" "$work/docker.log" | grep -v -e "-v $id-home:/home/agent " -e "-v $id-home:[^ ]* $image ")"
  expect "docker: agent add in a volume that isn't there" 1 "no such volume.*couldn't read docker-volume://$id-none/" \
    oneline "$lend_ssh" agent add x "docker-volume://$id-none/.ssh/id_ed25519.pub"
  expect "... it isn't created" fail 'no such volume' docker volume inspect "$id-none"
  docker volume rm -f "$id-none" >/dev/null 2>&1
  docker_reset
}

real_docker_stopped() {
  local loc=docker://$id-agentc/~/.ssh/id_ed25519.pub
  make_ca
  "$lend_ssh" account add dave@host1 >/dev/null
  "$lend_ssh" agent add c "$loc" >/dev/null
  docker stop -t 0 "$id-agentc" >/dev/null
  expect "docker: grant to an agent in a stopped container" 1 \
    "is not running.*couldn't write c's certificate to $loc; grant again to retry" \
    oneline "$lend_ssh" grant -t 1h c dave@host1
  docker start "$id-agentc" >/dev/null
  expect "... the container restarts as agent" 0 '^agent$' docker exec "$id-agentc" whoami
  expect "... granting again retries" 0 '^c: dave@host1 \(new\) until ' "$lend_ssh" grant -t 1h c dave@host1
  expect "... the agent logs in" 0 '^dave$' agent_ssh agentc dave whoami
  docker stop -t 0 "$id-agentc" >/dev/null
  expect "docker: revoke from an agent in a stopped container" 1 \
    "couldn't change the certificate at $loc, so c keeps its grant; revoke again to retry" \
    oneline "$lend_ssh" revoke c
  expect "... revokes nothing" 0 '^c: dave@host1 until ' "$lend_ssh" grant
  docker start "$id-agentc" >/dev/null
  expect "... the agent still logs in" 0 '^dave$' agent_ssh agentc dave whoami
  expect "... revoking again retries" 0 '^c: revoked dave@host1' "$lend_ssh" revoke c
  expect "... the agent can't log in" fail 'Permission denied' agent_ssh agentc dave whoami
  "$lend_ssh" agent rm c >/dev/null
  docker_reset
}

real_docker_move() {
  local from=docker://$id-agentc/~/.ssh/id_ed25519.pub to=docker-volume://$id-home/.ssh/id_ed25519.pub
  make_ca
  "$lend_ssh" account add dave@host1 >/dev/null
  "$lend_ssh" agent add c "$from" >/dev/null
  "$lend_ssh" grant -t 1h c dave@host1 >/dev/null
  # The same key, copied from agentc into the volume.
  docker exec "$id-agentc" tar -C /home/agent -cf - .ssh/id_ed25519 .ssh/id_ed25519.pub |
    docker run --rm -i --label "$id" -u agent -v "$id-home:/home/agent" "$image" tar -C /home/agent -xf -
  expect "docker: agent add -f moves an agent from a container to a volume" 0 \
    "^removed its certificate at $from added agent c: $to sent its certificate, dave@host1 until [0-9: -]+, to $to $" \
    oneline "$lend_ssh" agent add -f c "$to"
  expect "... the agent logs in with the volume as its home" 0 '^dave$' agent_ssh volume dave whoami
  expect "... the certificate is gone from the container" fail 'No such file' \
    docker_files agentc /home/agent/.ssh/id_ed25519-cert.pub
  expect "... the agent can't log in from it" fail 'Permission denied' agent_ssh agentc dave whoami
  expect "... revoke removes it in the volume" 0 '^c: revoked dave@host1' "$lend_ssh" revoke c
  expect "... the agent can't log in" fail 'Permission denied' agent_ssh volume dave whoami
  "$lend_ssh" agent rm c >/dev/null
  docker_reset
}

# completions WORDS...: lend-ssh __complete's candidates, without their
# descriptions.
completions() {
  "$lend_ssh" __complete "$@" | cut -f1
}

real_docker_complete() {
  expect "docker: agent add completes the running containers" 0 "^docker://$id-agentc/~/\\.ssh/id_ed25519\\.pub$" \
    completions agent add x docker://
  expect "docker: agent add completes the volumes" 0 "^docker-volume://$id-home/\\.ssh/id_ed25519\\.pub$" \
    completions agent add x docker-volume://
  docker stop -t 0 "$id-agentc" >/dev/null
  expect "docker: agent add doesn't complete a stopped container" 0 '^$' completions agent add x "docker://$id-agentc"
  docker start "$id-agentc" >/dev/null
}
