FROM alpine:3.22 AS base

RUN apk add --no-cache openssh-server shadow sudo tmux curl \
    && mkdir -p /fixtures /run/sshd

COPY start.sh /usr/local/bin/omniterm-runtime-host
RUN chmod 0755 /usr/local/bin/omniterm-runtime-host

EXPOSE 2222
ENTRYPOINT ["/usr/local/bin/omniterm-runtime-host"]

FROM base AS docker-host
RUN apk add --no-cache docker-cli docker-cli-compose
ENV OMNITERM_TEST_RUNTIME=docker

FROM base AS podman-host
RUN mkdir -p /lib/modules \
    && apk add --no-cache fuse-overlayfs iptables podman podman-compose shadow-subids \
    && sed -i 's/^#cgroups = "enabled"/cgroups = "disabled"/' \
      /etc/containers/containers.conf
COPY podman-root /usr/local/bin/podman
RUN chmod 0755 /usr/local/bin/podman
ENV OMNITERM_TEST_RUNTIME=podman
