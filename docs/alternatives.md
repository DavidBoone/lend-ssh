# Alternatives

lend-ssh signs OpenSSH user certificates with `ssh-keygen`. Many tools use
these certificates, and some aim at AI agents. This page compares them by what
the hosts need, what has to keep running, and what the agent holds.

| | Host setup | What runs | The agent holds |
|---|---|---|---|
| lend-ssh | a `cert-authority` line in each account's `authorized_keys` | a script on the machine that signs | its key and a certificate |
| `ssh-keygen -s` by hand | the same, or `TrustedUserCAKeys` in `sshd_config` | a command | its key and a certificate |
| step-ca / `step` | `TrustedUserCAKeys` in `sshd_config` | a CA server, or `step` offline | its key and a certificate |
| Vault SSH engine | `TrustedUserCAKeys` in `sshd_config` | a Vault server | its key and a certificate |
| Teleport (agentless OpenSSH) | sshd trusts Teleport's CA; host registered with `teleport` | Teleport's Auth and Proxy services | Teleport-issued certificates |
| Cloudflare Access for Infrastructure | `TrustedUserCAKeys` in `sshd_config`, plus `cloudflared` | a hosted Cloudflare One service | a short-lived certificate from its Access login |
| infrabroker | `TrustedUserCAKeys` in `sshd_config` | a broker and a separate signer | nothing: it calls the broker over MCP |
| `ssh-add -h` | none | your ssh-agent | access to your agent socket |

## `ssh-keygen -s` by hand

lend-ssh runs the same `ssh-keygen -s` command. Done by hand, you choose the
principals, validity and options for each certificate, and write each
`authorized_keys` line yourself. lend-ssh adds account names that
`account add` and `grant` agree on, restrictive defaults, a session deadline,
`account add` and `account rm` over `ssh`, named agents, grants that only add,
and revoking one agent's grants or every grant to an account.

The `cert-authority` option and its `principals=` list are documented in
[sshd(8)](https://man.openbsd.org/sshd.8) under AUTHORIZED_KEYS FILE FORMAT.

## step-ca and the `step` CLI

[step-ca](https://smallstep.com/docs/step-ca/) is a CA server for X.509 and
SSH certificates. Hosts trust its SSH user CA through `TrustedUserCAKeys` in
`sshd_config`
([tutorial](https://smallstep.com/docs/tutorials/ssh-certificate-login/)).
`step ssh certificate --offline` signs with a local CA's keys, without the
server
([reference](https://smallstep.com/docs/step-cli/reference/ssh/certificate/)).

## HashiCorp Vault SSH secrets engine

Vault's [signed SSH certificates](https://developer.hashicorp.com/vault/docs/secrets/ssh/signed-ssh-certificates)
keep the CA key in a Vault server, which signs clients' public keys. Each host
trusts the CA through `TrustedUserCAKeys` in `sshd_config`.

## Teleport

Teleport issues short-lived certificates through its own Auth and Proxy
services. In [agentless mode](https://goteleport.com/docs/enroll-resources/server-access/openssh/openssh-agentless/),
OpenSSH's sshd trusts Teleport's CA, and each host is registered by running
the `teleport` binary there once.

## Cloudflare Access for Infrastructure

A [hosted service](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/use-cases/ssh/ssh-infrastructure-access/)
that issues short-lived certificates from a user's Cloudflare Access login.
Hosts set `TrustedUserCAKeys` in `sshd_config` and run `cloudflared`, and
users run the Cloudflare One client.

## infrabroker

[infrabroker](https://github.com/luisgf/infrabroker) gives AI agents SSH and
Kubernetes access through MCP tools such as `ssh_execute`. The agent never
holds a credential: for each request, the broker checks its policy, gets an
ephemeral certificate from a separate signer process that holds the CA key,
runs the command itself, and returns its output. Hosts trust the CA through
`TrustedUserCAKeys` in `sshd_config`.

With lend-ssh, the agent runs `ssh` itself, as any program it likes, limited
to the accounts and time its certificate names.

## Destination-constrained ssh-agent keys

`ssh-add -h` (OpenSSH 8.9 and later) limits which hosts a key loaded in
ssh-agent can authenticate to, including through forwarded agents
([ssh-add(1)](https://man.openbsd.org/ssh-add.1)). A process with access to
the agent's socket can then use the key only for those destinations, for as
long as it has the socket and the key stays loaded.
