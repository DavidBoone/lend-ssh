# lend-ssh

Lend an AI agent, or any process you don't want holding your SSH key, SSH
access to the accounts you choose, for a few hours at a time.

```
you:    lend-ssh grant -t 2h claude myhost    # let the agent "claude" in for 2 hours
agent:  ssh dave@myhost …                      # works until then
```

The agent keeps its own key. When you grant it an account, lend-ssh signs
that key with a certificate for the account. When the certificate expires,
the agent's key stops working, its sessions end, and there is nothing to
clean up.

Each account accepts these certificates through one line in its
`~/.ssh/authorized_keys`, which lend-ssh adds for you. Hosts need nothing
else: no `sshd_config` changes, no root, no server to run. lend-ssh is a small
bash script around `ssh` and `ssh-keygen`; [Alternatives](docs/alternatives.md)
compares it with other tools that do this.

## What goes where

```
     your machine                 the agent                   an account
   ┌────────────────┐          ┌──────────────────────┐     ┌─────────────────────────┐
   │ lend-ssh       │ ◀─.pub── │ id_ed25519      stays│     │ ~/.ssh/authorized_keys  │
   │  ca       stays│          │ id_ed25519.pub       │     │   cert-authority,       │
   │  ca.pub        │ ─cert──▶ │ id_ed25519-cert.pub  │     │   principals="dave@…"   │
   │                │          │                      │     │   ca.pub                │
   └────────────────┘          └──────────────────────┘     └─────────────────────────┘
           │                              └──── ssh, key + cert ───────▶ ▲
           └──── account add, reset, rm: ssh as you, edits the line ─────┘
```

- `account add` logs in to the account as you and adds one line holding your
  signing key's public half, `ca.pub`. That's all a host ever gets from
  lend-ssh; `account reset` and `account rm` change or remove the line.
- `agent add` records where the agent's public key is, here or in another
  machine or container, or the key itself. lend-ssh never reads the agent's
  private key. When it creates one for an agent elsewhere, it creates it on
  this machine, sends it there, and deletes it here.
- `grant` signs the agent's public key with `ca`, which never leaves your
  machine, and writes the certificate, `id_ed25519-cert.pub`, beside the
  agent's key: on this machine, or over `ssh` or `docker` to where the agent
  is. That file is the only thing a grant moves, and it never connects to
  an account's host. When the agent's files are out of reach, `grant` prints
  the certificate for you to copy over.
- The agent logs in with plain `ssh`, offering its key and the certificate.
  The host checks the certificate against the line: signed by `ca`, naming
  the account, not expired. Neither the agent nor the host ever talks to
  lend-ssh.

So `revoke`, which only rewrites the certificate beside the agent's key, can't
stop a copy of it, while `account reset` changes the line on the host and
stops every certificate for that account.

## Install

On your own machine, the one you'll grant access from:

```sh
git clone https://github.com/DavidBoone/lend-ssh
lend-ssh/lend-ssh install
```

This puts `lend-ssh` on your `PATH`, with tab completion for bash and zsh. If
the directory it picks isn't on your `PATH`, or your shell needs a line to
load the completion, it tells you what to add. `lend-ssh update` updates it,
and lists the changes.

You need bash 3.2 or later and OpenSSH. Hosts need a POSIX `sh` and GNU
`timeout` or `perl`.

To remove lend-ssh, first `lend-ssh account rm` each account, which takes
lend-ssh's line out of its `authorized_keys`. Then `lend-ssh uninstall`
removes what `install` added and lists what's left, such as your signing key
and the clone.

## Getting started

**1. Create your signing key**, once:

```sh
lend-ssh init
```

This creates `~/.config/lend-ssh/ca`, the key that signs certificates, and
asks for a passphrase for it.

**2. Set up each account** agents may use:

```sh
lend-ssh account add myhost deploy@build
```

An account is `[USER@]HOST`, as you'd give it to `ssh`; `myhost` alone means
your own user name there, say `dave`. lend-ssh logs in over `ssh` as you
normally do and adds this line to the account's `~/.ssh/authorized_keys`:

```
cert-authority,principals="dave@myhost" ssh-ed25519 AAAA… lend-ssh CA dave@laptop
```

From then on the account accepts certificates from your signing key that name
it, and no others. Running `account add` again is harmless. For an account you
can't reach from here, `-p` prints the line for you to add by hand, and
lend-ssh treats the account as set up from then on.

**3. Add the agent**, giving it a name and the path to its public key:

```sh
lend-ssh agent add claude /path/to/agent/.ssh/id_ed25519.pub
```

If there's no key there yet, lend-ssh creates one, without a passphrase, since
the agent uses it unattended and it is useless without a current
certificate. lend-ssh never reads the private key.

If the agent's key is on another machine, in a container or in a Docker
volume, see
[An agent on another machine or in a container](#an-agent-on-another-machine-or-in-a-container).

**4. Grant access:**

```sh
lend-ssh grant -t 2h claude myhost
```

For the next 2 hours, the agent can log in to the account: `ssh dave@myhost`.

**5. Check it.** `lend-ssh agent` shows what each agent can reach:

```
$ lend-ssh agent
claude  /path/to/agent/.ssh/id_ed25519.pub
        dave@myhost until 2026-10-04 18:41:07
```

Then try a login from the agent's side, such as `ssh dave@myhost true`. If it
fails, see [Troubleshooting](#troubleshooting).

## On the agent's side

The agent uses plain `ssh`. For its logins to work:

- **It logs in as the account's user**: `ssh dave@myhost`, not as its own
  user name. Where your `~/.ssh/config` gives `myhost` a `User` or a
  `HostName`, the agent needs the same, in its own config or on the command
  line.
- **Its `ssh` uses the key you added.** `ssh` tries `~/.ssh/id_ed25519` and the
  other default key names by itself, and any key set with `-i` or
  `IdentityFile`, and loads the certificate beside each, named
  `KEY-cert.pub`.
- **It knows the host's key.** The first time it connects to a host, `ssh`
  asks to confirm the host's key; without a terminal, it fails with "Host key
  verification failed." Put the host's line from your `~/.ssh/known_hosts` in
  the agent's `~/.ssh/known_hosts` first.

## Granting access

`grant` writes the certificate, `id_ed25519-cert.pub`, beside the agent's key.
The certificate:

- opens only the accounts you name, each of which must be set up with
  `account add`; in a terminal, `grant` offers to run it for any that aren't
- lasts for the time `-t` gives, which `grant` always needs: `-t 30m`,
  `-t 4h`, `-t 2d`
- ends the agent's sessions when it expires (see
  [Session deadline](docs/how-it-works.md#session-deadline))
- allows a shell and commands only: no port, agent or X11 forwarding.
  `-O permit-port-forwarding` and the like allow them

Grants add up. While the agent's certificate is valid, a new grant keeps the
accounts it already has, and the later of the two expiry times:

```
$ lend-ssh grant -t 30m claude deploy@build
claude: deploy@build (new), dave@myhost (kept) until 2026-10-04 18:41:07
```

To change `-O` or `-D` on a valid certificate, `revoke` the agent first.

To see who can reach what, `lend-ssh grant` lists the grants,
`lend-ssh agent` the agents and `lend-ssh account` the accounts:

```
$ lend-ssh grant
claude: dave@myhost deploy@build until 2026-10-04 18:41:07
```

```
$ lend-ssh account
dave@myhost
        claude until 2026-10-04 18:41:07
deploy@build
        claude until 2026-10-04 18:41:07
```

`lend-ssh agent show claude` shows the certificate in detail, with the
[session deadline](docs/how-it-works.md#session-deadline) as one line in place
of the script that holds it; `ssh-keygen -L -f FILE` shows all of it.

## Taking access back

Certificates expire on their own. To end access sooner:

| Command | What it does | Open sessions | Copies of the certificate |
|---|---|---|---|
| `revoke claude myhost` | takes `myhost` from claude; with no account named, takes everything | run until the certificate would have expired | keep working until they expire |
| `agent rm claude` | as `revoke claude`, and forgets claude; its key stays | as `revoke` | as `revoke` |
| `account reset myhost` | takes `myhost` from every agent; `myhost` stays set up for new grants | end within about 10 seconds | stop working |
| `account rm myhost` | as `account reset`, and `myhost` takes no agents until you `account add` it again | as `account reset` | stop working |

`revoke` and `agent rm` only change files on your machine. The `account`
commands log in to the account over `ssh` and change its line, so they also
stop any copy the agent made of its certificate. For an account set up with
`-k FILE`, open sessions end only when their certificates expire.

Until a copy would stop working, `grant`, `agent` and `account` list its
accounts as revoked:

```
$ lend-ssh revoke claude deploy@build
claude: revoked deploy@build; keeps dave@myhost until 2026-10-04 18:41:07; a copy of the certificate, and sessions open there now, work until 2026-10-04 18:41:07, or until 'lend-ssh account reset deploy@build'
$ lend-ssh grant
claude: dave@myhost deploy@build (revoked) until 2026-10-04 18:41:07
```

## More

### An agent on another machine or in a container

When the agent's key isn't in a folder on this machine, give `agent add` a
location that lend-ssh reaches with `ssh` or `docker`:

```sh
lend-ssh agent add claude ssh://agentbox/~/.ssh/id_ed25519.pub
lend-ssh agent add claude docker://mycontainer/~/.ssh/id_ed25519.pub
lend-ssh agent add claude docker-volume://myvolume/.ssh/id_ed25519.pub
```

- `ssh://[USER@]HOST[:PORT]/PATH` logs in with your own ssh and its config.
- `docker://CONTAINER/PATH` uses `docker exec` in a running container, as
  the container's user.
- `docker-volume://VOLUME/PATH` uses a throwaway container of `alpine`, or
  of the image `LEND_SSH_VOLUME_IMAGE` names, with the volume mounted, whether
  or not a container is using it. The files it writes get the owner of their
  directory.

A PATH starting with `~/` is in the home directory there, and any other from
`/`; in a volume, PATH starts at the volume's top. As for a path here,
`agent add` creates a key at the location if there's none: it creates it on
this machine, sends both halves there over `ssh` or `docker`, and deletes
them here.

Over ssh, `[USER@]HOST:PATH` works as it does for `scp`, with PATH from the
home directory there unless it starts with `/`; `[USER@]HOST:` alone takes the
agent's usual key:

```sh
lend-ssh agent add claude agentbox:              # its usual key
lend-ssh agent add claude agentbox:keys/ci.pub   # ssh://agentbox/~/keys/ci.pub
```

The usual key is the first of `~/.ssh/id_ed25519.pub`, `id_ecdsa.pub` and
`id_rsa.pub` there; with none of them, `agent add` creates
`~/.ssh/id_ed25519`. For a host you've connected to before, `[USER@]HOST`
alone does the same: lend-ssh takes it as a host when it isn't a file here,
and the host is a `Host` in your `~/.ssh/config` or is in your `known_hosts`,
at the host name and port your ssh config gives it. ssh then logs in as it
would for `ssh agentbox`.

The agent uses its key unattended, so `agent add` warns when an existing key
has a passphrase, which only an ssh-agent can then supply. It checks with
`ssh-keygen` where the private key is, if that machine has it.

`grant` and `revoke` then write the certificate there. lend-ssh keeps a copy
of it, and of the public key, in `~/.config/lend-ssh/keys`, so `agent` and
`account` don't connect anywhere. When `grant` can't reach the location, it
says so and exits 1, and the grant counts as made; granting again writes it
again. When `revoke` can't, it says so, exits 1 and revokes nothing; revoking
again retries.

`agent add -f` gives an agent a new location for the same key, moving its
current certificate there from the old one.

When lend-ssh can't reach the agent at all, have the agent create its key
(`ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519`) and add its public key
as text:

```sh
lend-ssh agent add claude 'ssh-ed25519 AAAA…'
```

`grant` and `revoke` then print the certificate instead of writing it, for
you to put beside the agent's key as `~/.ssh/id_ed25519-cert.pub`.

`grant` also takes a public key, or `-` to read one from stdin, in place of an
agent's name:

```sh
ssh agentbox cat .ssh/id_ed25519.pub | lend-ssh grant -t 2h - myhost | ssh agentbox 'cat > .ssh/id_ed25519-cert.pub'
```

lend-ssh doesn't keep these certificates, so a new grant replaces the
agent's certificate rather than adding to it, and `revoke` can't narrow it;
`account reset` still closes the account.

### Fewer passphrase prompts

`grant` and `revoke` use the signing key from your ssh-agent when it's loaded
there, instead of asking for its passphrase each time:

```sh
ssh-add -t 8h ~/.config/lend-ssh/ca
```

`-t` unloads it again after that long. While it's loaded, anything that can
use your ssh-agent can sign certificates with it, including a host you
`ssh -A` into.

### With clod

In a [clod](https://github.com/DavidBoone/clod) container whose home is a
folder on the host, `~/.clod/homes/<name>`, the agent's `~/.ssh` is in that
folder, and the container runs as the user `claude`:

```sh
lend-ssh agent add claude ~/.clod/homes/default/.ssh/id_ed25519.pub
lend-ssh grant -t 2h claude myhost
```

`agent add` creates the key in the home if it has none. The running container
sees the key and each certificate at once. From the container, the agent logs
in as `ssh dave@myhost`.

A home that's a Docker volume, `vol:<name>`, is the volume
`clod-home-<name>`:

```sh
lend-ssh agent add claude docker-volume://clod-home-default/.ssh/id_ed25519.pub
```

## Troubleshooting

**`grant` says the account "isn't set up for agents from here".** Run
`lend-ssh account add` for it first; `grant` offers to when it runs in a
terminal. An account is named by the user and host
name `ssh` resolves it to, so `myhost` and `dave@myhost` are the same account.

**`grant` says the agent's certificate "allows" something else.** A grant
only adds to a valid certificate with the same `-O` and `-D` options.
`lend-ssh revoke claude` first, then grant again.

**The agent's login fails with "Permission denied".** Check, in turn:

- `lend-ssh agent` lists the account for the agent, not "(cancelled)" or
  "(revoked)". "no grant" means its certificate has expired or was revoked:
  grant again.
- The agent logs in as the account's user (`dave@myhost`), and its `ssh`
  offers the key the certificate is beside (see
  [On the agent's side](#on-the-agents-side)).
- The host reads the account's `~/.ssh/authorized_keys`. If its sshd keeps
  them elsewhere, set up the account with `account add -k FILE`.
- The host's clock is right. A certificate is valid from 5 minutes before the
  grant, so a host whose clock is further behind refuses it at first.

**A session is refused with "this certificate has expired".** The agent
reused an ssh connection opened before the certificate expired
(`ControlMaster`); the certificate's time has run out, so grant again.

**Sessions are refused with "this host has neither GNU timeout nor perl".**
The session deadline needs one of them on the host. Install one there, or
grant with `-D` to leave the deadline out, so that sessions can outlast the
certificate.

## Security

- Your signing key can sign a certificate for any account set up with it.
  Protect it like your own SSH key, with a passphrase.
- Anyone with the agent's private key and a current certificate can log in to
  the accounts it names until it expires.
- A certificate gives no less than the account it logs into: whatever `dave`
  can do on the host, the agent can do while it is valid.
- Expiry and the session deadline stop an agent from staying in by accident,
  not one that sets out to. While its certificate is valid, the agent has a
  shell in the account and can arrange to get back in: add a key to
  `authorized_keys`, add a cron job, or start a process that outlives the
  session. Against that, the account itself has to be limited.
- If the signing key leaks, `account rm` every account, delete the old key,
  `lend-ssh init` a new one, and `account add` the accounts again.

[How it works](docs/how-it-works.md) has the details behind these.

## Commands

`lend-ssh help` lists the commands:

```
usage: lend-ssh COMMAND [ARGS]

Gives AI agents, or anything else you'd rather not hand your own SSH key,
SSH access to your accounts that ends on its own. An account is [USER@]HOST
as ssh takes it, your own user name there unless you give USER.

Set up, once:
  init
      create the signing key
  account add [-p] [-k FILE] [USER@]HOST...
      let agents into these accounts
  agent add [-f] NAME KEY
      name an agent by its public key

Day to day:
  grant
  grant -t TIME [-O OPTION]... [-I ID] [-D] AGENT [USER@]HOST...
      list the grants, or let AGENT into these accounts for a while
  revoke AGENT [USER@]HOST...
      take these accounts back from AGENT
  agent
      list the agents, and what they can reach until when
  account
      list the accounts, and which agents can reach them until when
  agent show AGENT
      show AGENT's certificate in detail

Cut off:
  account reset [-k FILE] [USER@]HOST...
      cancel every agent's grants to these accounts
  account rm [-k FILE] [USER@]HOST...
      shut all agents out of these accounts
  agent rm NAME...
      revoke agents' grants and forget them

Other:
  install [-f] [DIR]
      link lend-ssh onto your PATH, with tab completion
  uninstall [DIR]
      remove the links install made
  update
      update lend-ssh (git pull in its clone)
  completion
      print tab completion for bash and zsh
  help [COMMAND]
      show the commands, or COMMAND's help

options:
  -h, --help           show the commands, or with one, its help

'lend-ssh COMMAND -h' shows more about COMMAND.

```

`lend-ssh COMMAND -h` explains a command and its options. Each option has a
short and a long form, such as `-t` and `--time`.

lend-ssh keeps its signing key, agents and accounts in `~/.config/lend-ssh`
(or `$XDG_CONFIG_HOME/lend-ssh`); `LEND_SSH_CA` sets another path for the
signing key.

## Development

`test/run.sh` runs shellcheck and all the tests, including end-to-end tests
against throwaway sshds when it finds `sshd`. `test/docker.sh`, with only
Docker, runs those in a container that has `sshd`, then lends access between
real containers: a host, an agent machine, an agent container and a volume.
[CLAUDE.md](CLAUDE.md) describes the layout.

## License

MIT; see [LICENSE](LICENSE).
