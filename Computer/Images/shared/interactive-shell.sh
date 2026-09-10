# Sourced by POSIX ENV, Bash's system rc, and login profiles.
case $- in *i*) ;; *) return ;; esac
if [ "${_NOODLE_WELCOME_PID:-}" != "$$" ] && [ -t 1 ]; then
  # Not exported: a fresh nested interactive shell gets its own welcome.
  _NOODLE_WELCOME_PID=$$
  /usr/local/bin/noodle-welcome
fi
