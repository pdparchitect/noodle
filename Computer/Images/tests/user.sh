#!/bin/sh
# Run as the image's default user, without networking or mounts.
set -eu
test "$(id -u)" = 1000
test "$(id -un)" = agent
test "$HOME" = /home/agent
test "$(sudo -n id -u)" = 0
test ! -w /etc/passwd
test ! -w /root
touch /workspace/noodle-user-test "$HOME/noodle-user-test"
test "$(stat -c %u /workspace/noodle-user-test)" = 1000
sudo -n sh -c 'printf elevated > /root/noodle-sudo-test'
test "$(sudo -n cat /root/noodle-sudo-test)" = elevated
printf 'PASS: default agent account, writable home/workspace, explicit sudo\n'
