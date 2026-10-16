#!/bin/sh
set -eu

: "${OMNITERM_TEST_USER:?OMNITERM_TEST_USER is required}"
: "${OMNITERM_TEST_PASSWORD:?OMNITERM_TEST_PASSWORD is required}"
: "${OMNITERM_TEST_RUNTIME:?OMNITERM_TEST_RUNTIME is required}"

if ! id "$OMNITERM_TEST_USER" >/dev/null 2>&1; then
  adduser -D -h "/home/$OMNITERM_TEST_USER" "$OMNITERM_TEST_USER"
fi
printf '%s:%s\n' "$OMNITERM_TEST_USER" "$OMNITERM_TEST_PASSWORD" | chpasswd
printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$OMNITERM_TEST_USER" \
  >/etc/sudoers.d/omniterm-test
chmod 0440 /etc/sudoers.d/omniterm-test

fixture_home="/home/$OMNITERM_TEST_USER/omniterm-e2e"
mkdir -p "$fixture_home/runtime" "$fixture_home/corpus"
cp -a /fixtures/runtime-stack/. "$fixture_home/runtime/"
cp -a /fixtures/compose-corpus/. "$fixture_home/corpus/"
cp -a /fixtures/large-stack.yml "$fixture_home/large-stack.yml"
chown -R "$OMNITERM_TEST_USER:$OMNITERM_TEST_USER" "$fixture_home"

if [ "$OMNITERM_TEST_RUNTIME" = docker ]; then
  for _ in $(seq 1 60); do
    [ -S /var/run/docker.sock ] && break
    sleep 1
  done
  [ -S /var/run/docker.sock ] || { echo "isolated Docker socket did not appear" >&2; exit 1; }
  # This socket belongs only to the disposable DinD service, never to the host daemon.
  chmod 0666 /var/run/docker.sock
fi

ssh-keygen -A
exec /usr/sbin/sshd -D -e -p 2222 \
  -o PasswordAuthentication=yes \
  -o PermitRootLogin=no \
  -o AllowTcpForwarding=yes \
  -o UsePAM=no
