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

# Backups for the Backup Age check, each taken at a fixed time (2026-01-01 00:00 UTC) so a check
# reads a known age: a restic and a Borg repository with that password, and a vzdump directory.
# Made once per container; the password comes from .env and is passed only in the environment.
backups="/home/$OMNITERM_TEST_USER/backups"
if [ -n "${OMNITERM_TEST_BACKUP_PASSWORD:-}" ] && command -v restic >/dev/null 2>&1 && [ ! -d "$backups" ]; then
  mkdir -p "$backups/data" "$backups/dump"
  printf 'fixture\n' >"$backups/data/file.txt"
  RESTIC_PASSWORD="$OMNITERM_TEST_BACKUP_PASSWORD" restic init -q -r "$backups/restic"
  RESTIC_PASSWORD="$OMNITERM_TEST_BACKUP_PASSWORD" restic backup -q -r "$backups/restic" \
    --host fixture --time '2026-01-01 00:00:00' "$backups/data"
  BORG_PASSPHRASE="$OMNITERM_TEST_BACKUP_PASSWORD" borg init -e repokey "$backups/borg"
  BORG_PASSPHRASE="$OMNITERM_TEST_BACKUP_PASSWORD" borg create --timestamp 2026-01-01T00:00:00 \
    "$backups/borg::fixture-2026-01-01" "$backups/data"
  # Two guests; 101's newest dump is the older one. The logs and notes beside them are not dumps.
  for f in vzdump-qemu-100-2025_12_31-00_00_00.vma.zst vzdump-qemu-100-2026_01_01-00_00_00.vma.zst \
    vzdump-lxc-101-2025_12_25-00_00_00.tar.zst vzdump-qemu-100-2026_01_01-00_00_00.log \
    vzdump-qemu-100-2026_01_01-00_00_00.vma.zst.notes; do
    : >"$backups/dump/$f"
  done
  chown -R "$OMNITERM_TEST_USER:$OMNITERM_TEST_USER" "$backups"
fi

if [ "$OMNITERM_TEST_RUNTIME" = docker ]; then
  for _ in $(seq 1 60); do
    [ -S /var/run/docker.sock ] && break
    sleep 1
  done
  [ -S /var/run/docker.sock ] || { echo "isolated Docker socket did not appear" >&2; exit 1; }
  # This socket belongs only to the disposable DinD service, never to the host daemon.
  chmod 0666 /var/run/docker.sock
fi

if [ "$OMNITERM_TEST_RUNTIME" = podman ]; then
  # Podman records the boot ID under /run, and /run survives when Docker restarts this container
  # instead of recreating it (as after a host reboot). Every podman command then refuses with
  # "current system boot ID differs from cached boot ID; an unhandled reboot has occurred", and
  # the fixture looks like a host without Podman. A container start is a fresh boot as far as
  # Podman is concerned: nothing it ran survived it. So clear its runtime state, as that message
  # advises. Images and volumes live in /var/lib/containers and are kept.
  rm -rf /run/containers/storage /run/libpod
fi

ssh-keygen -A
exec /usr/sbin/sshd -D -e -p 2222 \
  -o PasswordAuthentication=yes \
  -o PermitRootLogin=no \
  -o AllowTcpForwarding=yes \
  -o UsePAM=no
