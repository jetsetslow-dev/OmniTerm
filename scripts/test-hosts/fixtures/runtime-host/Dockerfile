FROM alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce AS docker-host

RUN apk add --no-cache openssh-server shadow sudo tmux curl docker-cli docker-cli-compose \
    && mkdir -p /fixtures /run/sshd

COPY start.sh /usr/local/bin/omniterm-runtime-host
RUN chmod 0755 /usr/local/bin/omniterm-runtime-host

EXPOSE 2222
ENTRYPOINT ["/usr/local/bin/omniterm-runtime-host"]
ENV OMNITERM_TEST_RUNTIME=docker

FROM alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce AS podman-host

RUN mkdir -p /lib/modules \
    && apk add --no-cache openssh-server shadow sudo tmux curl \
      fuse-overlayfs iptables podman podman-compose shadow-subids \
    && mkdir -p /fixtures /run/sshd \
    && sed -i 's/^#cgroups = "enabled"/cgroups = "disabled"/' \
      /etc/containers/containers.conf
COPY start.sh /usr/local/bin/omniterm-runtime-host
COPY podman-root /usr/local/bin/podman
RUN chmod 0755 /usr/local/bin/omniterm-runtime-host /usr/local/bin/podman

EXPOSE 2222
ENTRYPOINT ["/usr/local/bin/omniterm-runtime-host"]
ENV OMNITERM_TEST_RUNTIME=podman
