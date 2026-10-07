# shellcheck shell=bash disable=SC2154  # lend_ssh and the rest are test/real.sh's
# Agents at ssh:// locations and bare [USER@]HOST, on agentbox's sshd, logging
# in from there to host1.

# box_exec COMMAND...: runs COMMAND as root on agentbox.
box_exec() { docker exec "$id-agentbox" "$@"; }

# box_as_agent COMMAND...: runs sh command line COMMAND as agent on agentbox.
box_as_agent() { docker exec -u agent "$id-agentbox" sh -c "$1"; }

# box_stat PATH...: prints the owner and mode of each PATH on agentbox.
box_stat() { box_exec stat -c '%U %a' "$@" 2>&1 | paste -sd' ' -; }

# box_aliases: prints agentbox's names on the network.
box_aliases() {
  docker inspect -f "{{json (index .NetworkSettings.Networks \"$id\").Aliases}}" "$id-agentbox"
}

# box_off and box_on take agentbox off the network, so lend-ssh can't reach it,
# and put it back under its name there.
box_off() { docker network disconnect "$id" "$id-agentbox"; }
box_on() { docker network connect --alias agentbox "$id" "$id-agentbox"; }

# A new key at a location, in a directory agent add creates, which the agent
# logs in with once granted.
real_ssh_new_key() {
  make_ca
  mkdir "$work/tmp"
  expect "ssh: agent add creates a key at a location" 0 '^created a key at ssh://agent@agentbox/~/keys/id_ed25519, without a passphrase' \
    env TMPDIR="$work/tmp" "$lend_ssh" agent add box ssh://agent@agentbox/~/keys/id_ed25519.pub
  expect "... agent lists it at the location" 0 '^box[[:space:]]+ssh://agent@agentbox/~/keys/id_ed25519.pub' "$lend_ssh" agent
  expect "ssh: the new key's directory is agent's, 700" 0 '^agent 700$' box_stat /home/agent/keys
  expect "ssh: the new key is agent's, 600 and 644" 0 '^agent 600 agent 644$' \
    box_stat /home/agent/keys/id_ed25519 /home/agent/keys/id_ed25519.pub
  check "ssh: agent add keeps the public key it created" \
    cmp -s "$XDG_CONFIG_HOME/lend-ssh/keys/box/key.pub" <(box_exec cat /home/agent/keys/id_ed25519.pub)
  check "ssh: agent add leaves no key here" test -z "$(ls -A "$work/tmp")"
  "$lend_ssh" account add dave@host1 >/dev/null
  expect "ssh: grant to a new key at a location" 0 '^box: dave@host1 \(new\)' "$lend_ssh" grant -t 1h box dave@host1
  expect "ssh: grant writes the certificate there, agent's, 644" 0 '^agent 644$' box_stat /home/agent/keys/id_ed25519-cert.pub
  expect "ssh: the agent logs in with the new key" 0 '^dave$' agent_ssh -i /home/agent/keys/id_ed25519 agentbox dave whoami
  expect "ssh: agent rm" 0 '^removed agent box' "$lend_ssh" agent rm box
  expect "ssh: agent rm removes the certificate there" fail 'No such file' box_exec ls /home/agent/keys/id_ed25519-cert.pub
  expect "ssh: agent rm leaves the key there" 0 'id_ed25519.pub' box_exec ls /home/agent/keys/id_ed25519.pub
  expect "ssh: the agent can't log in after agent rm" fail 'Permission denied' agent_ssh -i /home/agent/keys/id_ed25519 agentbox dave whoami
  "$lend_ssh" account rm dave@host1 >/dev/null
  box_exec rm -rf /home/agent/keys
}

# An existing key at a location: grants add up there, and revokes narrow and
# remove the certificate there.
real_ssh_existing_key() {
  make_ca
  box_as_agent 'mkdir ~/have && ssh-keygen -q -t ed25519 -N "" -C have -f ~/have/id_ed25519'
  expect "ssh: agent add takes an existing key at a location" 0 '^added agent box: ssh://agent@agentbox/~/have/id_ed25519.pub$' \
    "$lend_ssh" agent add box ssh://agent@agentbox/~/have/id_ed25519
  check "ssh: agent add copies the existing key" \
    cmp -s "$XDG_CONFIG_HOME/lend-ssh/keys/box/key.pub" <(box_exec cat /home/agent/have/id_ed25519.pub)
  "$lend_ssh" account add dave@host1 deploy@host1 >/dev/null
  expect "ssh: grant at a location" 0 '^box: dave@host1 \(new\)' "$lend_ssh" grant -t 1h box dave@host1
  expect "ssh: grant adds at a location" 0 '^box: deploy@host1 \(new\), dave@host1 \(kept\)' "$lend_ssh" grant -t 1h box deploy@host1
  expect "... the agent still logs in to the account it had" 0 '^dave$' agent_ssh -i /home/agent/have/id_ed25519 agentbox dave whoami
  expect "... and to the new one" 0 '^deploy$' agent_ssh -i /home/agent/have/id_ed25519 agentbox deploy whoami
  expect "ssh: revoke narrows at a location" 0 '^box: revoked deploy@host1; keeps dave@host1' "$lend_ssh" revoke box deploy@host1
  expect "... the agent can't log in to the account revoked" fail 'Permission denied' agent_ssh -i /home/agent/have/id_ed25519 agentbox deploy whoami
  expect "... and still logs in to the one kept" 0 '^dave$' agent_ssh -i /home/agent/have/id_ed25519 agentbox dave whoami
  check "ssh: revoke narrows the certificate there" \
    cmp -s "$XDG_CONFIG_HOME/lend-ssh/keys/box/key-cert.pub" <(box_exec cat /home/agent/have/id_ed25519-cert.pub)
  expect "ssh: revoke removes the certificate at a location" 0 '^box: revoked dave@host1' "$lend_ssh" revoke box
  expect "ssh: revoke removes the certificate there" fail 'No such file' box_exec ls /home/agent/have/id_ed25519-cert.pub
  expect "ssh: revoke leaves the key there" 0 '^agent 600 agent 644$' \
    box_stat /home/agent/have/id_ed25519 /home/agent/have/id_ed25519.pub
  "$lend_ssh" agent rm box >/dev/null
  "$lend_ssh" account rm dave@host1 deploy@host1 >/dev/null
  box_exec rm -rf /home/agent/have
}

# An absolute PATH, :PORT on a second sshd on agentbox, and a host whose port
# comes from ~/.ssh/config, known under [HOST]:PORT. That host's key is
# ~/.ssh/id_ed25519 there, which this removes after unless it was there before.
real_ssh_path_and_port() {
  local tries=0 kh=$HOME/.ssh/known_hosts had=''
  make_ca
  ! box_exec test -e /home/agent/.ssh/id_ed25519.pub || had=1
  cp -p "$kh" "$work/known_hosts"
  [[ ! -e $HOME/.ssh/config ]] || cp -p "$HOME/.ssh/config" "$work/config.ssh"
  box_exec mkdir -p /home/agent/abs
  box_exec chown agent: /home/agent/abs
  expect "ssh: agent add with an absolute path" 0 '^added agent box: ssh://agent@agentbox/home/agent/abs/id_ed25519.pub$' \
    "$lend_ssh" agent add box ssh://agent@agentbox/home/agent/abs/id_ed25519.pub
  expect "... the key there is agent's, 600 and 644" 0 '^agent 600 agent 644$' \
    box_stat /home/agent/abs/id_ed25519 /home/agent/abs/id_ed25519.pub
  "$lend_ssh" account add dave@host1 >/dev/null
  expect "ssh: grant with an absolute path" 0 '^box: dave@host1 \(new\)' "$lend_ssh" grant -t 1h box dave@host1
  expect "... the agent logs in with it" 0 '^dave$' agent_ssh -i /home/agent/abs/id_ed25519 agentbox dave whoami

  box_exec /usr/sbin/sshd -p 2200 -o PidFile=/run/sshd-2200.pid
  until box_exec test -s /run/sshd-2200.pid; do
    ((++tries < 50)) || break
    sleep 0.1
  done
  grep -v '^#' "$work/known_hosts" | awk '$1 == "agentbox" { $1 = "[agentbox]:2200"; print }' >>"$kh"
  expect "ssh: agent add at a :PORT" 0 '^added agent box2: ssh://agent@agentbox:2200/~/abs/id_ed25519.pub$' \
    "$lend_ssh" agent add box2 ssh://agent@agentbox:2200/~/abs/id_ed25519.pub
  expect "ssh: agent add at a :PORT with nothing there" 1 "couldn't read ssh://agent@agentbox:2201/" \
    "$lend_ssh" agent add box3 ssh://agent@agentbox:2201/~/abs/id_ed25519.pub
  printf 'Host abox*\n  HostName agentbox\n  Port 2200\n  User agent\n' >"$HOME/.ssh/config"
  expect "ssh: agent add of a host known at its port" 0 '^added agent box3: ssh://abox1/~/.ssh/id_ed25519.pub$' \
    "$lend_ssh" agent add box3 abox1
  cp -p "$work/known_hosts" "$kh"
  expect "ssh: agent add of a host not known at its port" 1 "neither a key file, a public key nor a host ssh knows" \
    "$lend_ssh" agent add box4 abox1
  "$lend_ssh" agent rm box box2 box3 >/dev/null
  "$lend_ssh" account rm dave@host1 >/dev/null
  [[ -n $had ]] || box_exec rm -f /home/agent/.ssh/id_ed25519 /home/agent/.ssh/id_ed25519.pub
  box_exec pkill -f 'sshd -p 2200'
  box_exec rm -rf /home/agent/abs
  if [[ -e $work/config.ssh ]]; then cp -p "$work/config.ssh" "$HOME/.ssh/config"; else rm -f "$HOME/.ssh/config"; fi
}

# Refusals at a location: a new key beside other public keys, in a directory
# whose parent is missing, or beside a private key with no public one.
real_ssh_refusals() {
  make_ca
  box_as_agent 'mkdir ~/others && ssh-keygen -q -t ed25519 -N "" -C x -f ~/others/x && rm ~/others/x && mkdir ~/lone && ssh-keygen -q -t ed25519 -N "" -C x -f ~/lone/x && rm ~/lone/x.pub'
  expect "ssh: agent add refuses a new key beside other keys" 1 "others already has x.pub; to use it: 'lend-ssh agent add box agent@agentbox:others/x.pub'" \
    "$lend_ssh" agent add box ssh://agent@agentbox/~/others/id_ed25519.pub
  expect "... and leaves only the other key there" 0 '^x.pub$' box_exec ls /home/agent/others
  expect "ssh: agent add refuses a new key with no parent directory" 1 'no directory ssh://agent@agentbox/~/no to create a key in' \
    "$lend_ssh" agent add box ssh://agent@agentbox/~/no/such/id_ed25519.pub
  expect "... and creates no directory" fail 'No such file' box_exec ls /home/agent/no
  expect "ssh: agent add refuses a private key with no public key" 1 'no public key at ssh://agent@agentbox/~/lone/x.pub' \
    "$lend_ssh" agent add box ssh://agent@agentbox/~/lone/x
  expect "ssh: agent add refuses a host ssh doesn't know" 1 'neither a key file, a public key nor a host ssh knows' \
    "$lend_ssh" agent add box agent@agentc
  expect "ssh: agent add refusals add no agent" 0 '^No agents' "$lend_ssh" agent
  box_exec rm -rf /home/agent/others /home/agent/lone
}

# Bare [USER@]HOST: in known_hosts, plain or hashed, and as a Host in
# ~/.ssh/config. Its key is ~/.ssh/id_ed25519 there, which this removes after
# unless it was there before.
real_ssh_bare_host() {
  local kh=$HOME/.ssh/known_hosts had=''
  make_ca
  ! box_exec test -e /home/agent/.ssh/id_ed25519.pub || had=1
  cp -p "$kh" "$work/known_hosts"
  [[ ! -e $HOME/.ssh/config ]] || cp -p "$HOME/.ssh/config" "$work/config.ssh"
  expect "ssh: agent add of a host in known_hosts" 0 '^added agent box: ssh://agent@agentbox/~/.ssh/id_ed25519.pub$' \
    "$lend_ssh" agent add box agent@agentbox
  expect "... creates a key there in ~/.ssh, agent's, 600 and 644" 0 '^agent 600 agent 644$' \
    box_stat /home/agent/.ssh/id_ed25519 /home/agent/.ssh/id_ed25519.pub
  "$lend_ssh" account add dave@host1 >/dev/null
  expect "ssh: grant to a bare host" 0 '^box: dave@host1 \(new\)' "$lend_ssh" grant -t 1h box dave@host1
  expect "... the agent logs in with its usual key" 0 '^dave$' agent_ssh agentbox dave whoami

  ssh-keygen -q -H -f "$kh" >/dev/null 2>&1
  rm -f "$kh.old"
  check "ssh: known_hosts is hashed" test -z "$(grep agentbox "$kh")"
  expect "ssh: agent add of a host in hashed known_hosts" 0 '^added agent box2: ssh://agent@agentbox/~/.ssh/id_ed25519.pub$' \
    "$lend_ssh" agent add box2 agent@agentbox
  cp -p "$work/known_hosts" "$kh"

  printf 'Host abox\n  HostName agentbox\n  User agent\n' >"$HOME/.ssh/config"
  expect "ssh: agent add of a Host in ~/.ssh/config" 0 '^added agent box3: ssh://abox/~/.ssh/id_ed25519.pub$' \
    "$lend_ssh" agent add box3 abox
  expect "ssh: agent rm of a bare host" 0 '^removed agent box' "$lend_ssh" agent rm box
  expect "... removes the certificate there" fail 'No such file' box_exec ls /home/agent/.ssh/id_ed25519-cert.pub
  expect "ssh: grant to a Host in ~/.ssh/config" 0 '^box3: dave@host1 \(new\)' "$lend_ssh" grant -t 1h box3 dave@host1
  expect "... the agent logs in" 0 '^dave$' agent_ssh agentbox dave whoami
  expect "ssh: revoke at a Host in ~/.ssh/config" 0 '^box3: revoked dave@host1' "$lend_ssh" revoke box3
  expect "... removes the certificate there" fail 'No such file' box_exec ls /home/agent/.ssh/id_ed25519-cert.pub
  "$lend_ssh" agent rm box2 box3 >/dev/null
  "$lend_ssh" account rm dave@host1 >/dev/null
  if [[ -e $work/config.ssh ]]; then cp -p "$work/config.ssh" "$HOME/.ssh/config"; else rm -f "$HOME/.ssh/config"; fi
  [[ -n $had ]] || box_exec rm -f /home/agent/.ssh/id_ed25519 /home/agent/.ssh/id_ed25519.pub
}

# [USER@]HOST: and [USER@]HOST:PATH: the agent's existing ~/.ssh/id_rsa, which
# its ssh then uses with the certificate beside it, and a key with a
# passphrase. The keys already in ~/.ssh there are set aside meanwhile.
# shellcheck disable=SC2016  # the scripts expand their own variables
real_ssh_host_path() {
  make_ca
  box_as_agent 'mkdir -p ~/.ssh ~/aside ~/pp && for f in ~/.ssh/id_*; do [ ! -e "$f" ] || mv "$f" ~/aside/; done &&
    ssh-keygen -q -t rsa -b 2048 -N "" -C rsa -f ~/.ssh/id_rsa && ssh-keygen -q -t ed25519 -N secret -C pp -f ~/pp/id_ed25519'
  expect "ssh: agent add HOST: takes the agent's id_rsa" 0 '^added agent box: ssh://agent@agentbox/~/.ssh/id_rsa.pub$' \
    "$lend_ssh" agent add box agent@agentbox:
  "$lend_ssh" account add dave@host1 >/dev/null
  "$lend_ssh" grant -t 1h box dave@host1 >/dev/null
  expect "... grant writes id_rsa-cert.pub there" 0 '^agent 644$' box_stat /home/agent/.ssh/id_rsa-cert.pub
  expect "... which the agent's ssh uses by default" 0 '^dave$' agent_ssh agentbox dave whoami
  expect "ssh: agent add HOST:PATH warns of a key with a passphrase" 0 \
    '^lend-ssh: the private key for ssh://agent@agentbox/~/pp/id_ed25519.pub has a passphrase, so the agent can use it only through an ssh-agent added agent pp: ssh://agent@agentbox/~/pp/id_ed25519.pub $' \
    bash -c '"$1" agent add pp agent@agentbox:pp/id_ed25519 2>&1 | tr "\n" " "' _ "$lend_ssh"
  "$lend_ssh" agent rm box pp >/dev/null
  "$lend_ssh" account rm dave@host1 >/dev/null
  box_as_agent 'rm -rf ~/pp ~/.ssh/id_rsa* && for f in ~/aside/*; do [ ! -e "$f" ] || mv "$f" ~/.ssh/; done && rmdir ~/aside'
}

# A location lend-ssh can't reach: grant counts the grant as made and grants
# again to retry, revoke revokes nothing, and agent rm forgets the agent.
real_ssh_unreachable() {
  local aliases
  make_ca
  aliases=$(box_aliases)
  box_as_agent 'mkdir ~/gone && ssh-keygen -q -t ed25519 -N "" -C gone -f ~/gone/id_ed25519'
  "$lend_ssh" agent add box ssh://agent@agentbox/~/gone/id_ed25519.pub >/dev/null
  "$lend_ssh" account add dave@host1 deploy@host1 >/dev/null
  "$lend_ssh" grant -t 1h box dave@host1 >/dev/null 2>&1
  box_off
  expect "ssh: grant to an unreachable location" 1 "couldn't write box's certificate to ssh://agent@agentbox/~/gone/id_ed25519.pub; grant again to retry" \
    "$lend_ssh" grant -t 1h box deploy@host1
  expect "ssh: grant to an unreachable location counts" 0 'deploy@host1' "$lend_ssh" grant
  box_on
  check "ssh: agentbox is back on the network under its names" test "$(box_aliases)" = "$aliases"
  expect "ssh: the agent can't log in to an account granted while unreachable" fail 'Permission denied' agent_ssh -i /home/agent/gone/id_ed25519 agentbox deploy whoami
  expect "ssh: granting again after it's reachable" 0 '^box: deploy@host1 \(new\), dave@host1 \(kept\)' "$lend_ssh" grant -t 1h box deploy@host1
  expect "... the agent logs in" 0 '^deploy$' agent_ssh -i /home/agent/gone/id_ed25519 agentbox deploy whoami

  box_off
  expect "ssh: revoke at an unreachable location" 1 "couldn't change the certificate at ssh://agent@agentbox/~/gone/id_ed25519.pub, so box keeps its grant; revoke again to retry" \
    "$lend_ssh" revoke box deploy@host1
  check "ssh: revoke at an unreachable location records no revoke" test ! -e "$XDG_CONFIG_HOME/lend-ssh/revoked"
  expect "ssh: revoke at an unreachable location keeps the grant" 0 'deploy@host1' "$lend_ssh" grant
  box_on
  expect "... the agent still logs in" 0 '^deploy$' agent_ssh -i /home/agent/gone/id_ed25519 agentbox deploy whoami
  expect "ssh: revoking again after it's reachable" 0 '^box: revoked deploy@host1; keeps dave@host1' "$lend_ssh" revoke box deploy@host1
  expect "... the agent can't log in" fail 'Permission denied' agent_ssh -i /home/agent/gone/id_ed25519 agentbox deploy whoami

  box_off
  expect "ssh: agent rm at an unreachable location" 1 "couldn't remove the certificate at ssh://agent@agentbox/~/gone/id_ed25519.pub, so it still works there" \
    "$lend_ssh" agent rm box
  expect "ssh: agent rm at an unreachable location forgets the agent" 0 '^No agents' "$lend_ssh" agent
  box_on
  check "ssh: agentbox is back on the network under its names again" test "$(box_aliases)" = "$aliases"
  expect "ssh: agent rm at an unreachable location leaves the certificate there" 0 '^dave$' \
    agent_ssh -i /home/agent/gone/id_ed25519 agentbox dave whoami
  "$lend_ssh" account rm dave@host1 deploy@host1 >/dev/null
  box_exec rm -rf /home/agent/gone
}

# agent add -f with the same key at another location moves the certificate;
# with another key, it's refused while the grant lasts.
real_ssh_move() {
  make_ca
  box_as_agent 'mkdir ~/m1 ~/m2 ~/m3 && ssh-keygen -q -t ed25519 -N "" -C m -f ~/m1/id_ed25519 && cp -p ~/m1/id_ed25519 ~/m1/id_ed25519.pub ~/m2/ && ssh-keygen -q -t ed25519 -N "" -C m3 -f ~/m3/id_ed25519'
  "$lend_ssh" agent add box ssh://agent@agentbox/~/m1/id_ed25519.pub >/dev/null
  "$lend_ssh" account add dave@host1 >/dev/null
  "$lend_ssh" grant -t 1h box dave@host1 >/dev/null 2>&1
  expect "ssh: agent add -f refuses another key while granted" 1 'agent box has a grant' \
    "$lend_ssh" agent add -f box ssh://agent@agentbox/~/m3/id_ed25519.pub
  expect "... agent keeps the old location" 0 '^box[[:space:]]+ssh://agent@agentbox/~/m1/id_ed25519.pub' "$lend_ssh" agent
  expect "ssh: agent add -f moves the same key" 0 'removed its certificate at ssh://agent@agentbox/~/m1/id_ed25519.pub' \
    "$lend_ssh" agent add -f box ssh://agent@agentbox/~/m2/id_ed25519.pub
  expect "... agent lists the new location" 0 '^box[[:space:]]+ssh://agent@agentbox/~/m2/id_ed25519.pub' "$lend_ssh" agent
  expect "ssh: agent add -f removes the certificate at the old location" fail 'No such file' box_exec ls /home/agent/m1/id_ed25519-cert.pub
  check "ssh: agent add -f writes the certificate at the new location" \
    cmp -s "$XDG_CONFIG_HOME/lend-ssh/keys/box/key-cert.pub" <(box_exec cat /home/agent/m2/id_ed25519-cert.pub)
  expect "ssh: the agent logs in from the new location" 0 '^dave$' agent_ssh -i /home/agent/m2/id_ed25519 agentbox dave whoami
  "$lend_ssh" agent rm box >/dev/null
  "$lend_ssh" account rm dave@host1 >/dev/null
  box_exec rm -rf /home/agent/m1 /home/agent/m2 /home/agent/m3
}
