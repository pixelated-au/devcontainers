# shellcheck shell=sh
#
# Sourced by every interactive shell (bash and zsh) via the system-wide rc files.
#
# A container whose firewall never got installed looks exactly like one that did,
# from the inside. That happens more easily than you would think: postStartCommand
# is what runs `configure-firewall.sh --init`, and anything that stops it running
# — most commonly a stale container whose workspaceFolder no longer exists — leaves
# the container up with unrestricted egress and no visible sign of it.
#
# `--list` is the cheapest thing the restricted sudoers rule lets a normal user run
# that fails when the allow-list is absent.
if ! sudo -n /usr/local/bin/configure-firewall.sh --list >/dev/null 2>&1; then
    printf '\033[1;31m%s\033[0m\n' "WARNING: the outbound firewall is NOT active in this container."
    printf '\033[1;31m%s\033[0m\n' "Network access is unrestricted. This container is not a sandbox."
    printf '\033[1;31m%s\033[0m\n' "Fix: sudo /usr/local/bin/configure-firewall.sh --init"
fi
