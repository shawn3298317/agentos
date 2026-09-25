# Fresh-machine stand-in for testing install.sh: a bare Ubuntu with a sudo-capable user.
# No git, curl, jq, tmux, node or agent-deck. install.sh has to bring all of them.
ARG BASE=ubuntu:24.04
FROM ${BASE}
RUN set -eux; \
    if [ -f /etc/apt/sources.list ] && ! grep -q universe /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; then \
      sed -i 's/^deb \(.*\) main$/deb \1 main universe/' /etc/apt/sources.list; \
      for s in noble-updates noble-security; do echo "deb http://archive.ubuntu.com/ubuntu $s main universe" >> /etc/apt/sources.list; done; \
    fi; \
    apt-get update -qq; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends sudo ca-certificates; \
    rm -rf /var/lib/apt/lists/*; \
    useradd -m -s /bin/bash shawn; \
    echo 'shawn ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/shawn
USER shawn
WORKDIR /home/shawn
COPY --chown=shawn:shawn . /home/shawn/agentos
CMD ["bash", "/home/shawn/agentos/test/e2e.sh"]
