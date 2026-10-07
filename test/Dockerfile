# One image for every container test/docker.sh starts: the lender, which runs
# lend-ssh as "me", and the machines it reaches, with sshd and the users
# dave, deploy and agent. The tests fail logins on purpose, so sshd doesn't
# penalize the addresses they come from.
FROM debian:stable-slim
RUN apt-get update \
  && apt-get install -y --no-install-recommends openssh-server openssh-client \
    shellcheck zsh python3 git perl bash-completion procps \
  && rm -rf /var/lib/apt/lists/* \
  && rm -f /etc/ssh/ssh_host_* \
  && mkdir -p /run/sshd \
  && echo 'PerSourcePenalties no' >/etc/ssh/sshd_config.d/lend-ssh-test.conf \
  && for u in me dave deploy agent; do useradd -m -s /bin/bash "$u" && usermod -p '*' "$u"; done
COPY --from=docker:cli /usr/local/bin/docker /usr/local/bin/docker
COPY --chown=me . /src
WORKDIR /src
CMD ["sh", "-c", "ssh-keygen -A && exec /usr/sbin/sshd -D -e"]
