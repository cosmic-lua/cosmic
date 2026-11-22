#!/bin/sh
# What the Claude Code Action's env scrub (CLAUDE_CODE_SUBPROCESS_ENV_SCRUB)
# needs to start, for review.yml: bubblewrap, which runs the agent's Bash
# in namespaces of its own, and socat, which carries its network out of
# them; and unprivileged user namespaces, which Ubuntu 24.04's AppArmor
# refuses by default. The action does the same itself only for runs that
# take content from users without write access.
set -eu

sudo apt-get update -qq
sudo apt-get install -y -qq --no-install-recommends bubblewrap socat
if [ -f /proc/sys/kernel/apparmor_restrict_unprivileged_userns ]; then
  sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
fi
