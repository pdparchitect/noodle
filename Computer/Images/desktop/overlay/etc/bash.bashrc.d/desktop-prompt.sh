# Noodle desktop - custom bash prompt and shell settings.
# Sourced from /etc/bash.bashrc.d/ so it applies to all interactive shells.

# Prompt: @user ➜ ~/working/dir (branch) $
# Neon-green username, blue path, cyan parens, red branch, reset dollar.
__desktop_ps1() {
  local exit_code=$?
  local neon_green='\[\e[38;5;46m\]'
  local blue='\[\e[1;34m\]'
  local cyan='\[\e[0;36m\]'
  local red='\[\e[1;31m\]'
  local reset='\[\e[0m\]'

  # Arrow color: green on success, red on failure.
  local arrow
  if [ "$exit_code" -ne 0 ]; then
    arrow='\[\e[1;31m\]➜'
  else
    arrow="${reset}➜"
  fi

  # Git branch (fast, no lock).
  local branch
  branch="$(git --no-optional-locks symbolic-ref --short HEAD 2>/dev/null \
    || git --no-optional-locks rev-parse --short HEAD 2>/dev/null)"

  local git_info=""
  if [ -n "$branch" ]; then
    git_info=" ${cyan}(${red}${branch}${cyan})"
  fi

  PS1="${neon_green}@\\u ${arrow} ${blue}\\w${git_info} ${reset}\$ "
}

PROMPT_COMMAND="__desktop_ps1"

# Decent defaults.
export EDITOR=vim
export LANG="${LANG:-C.UTF-8}"
export BROWSER="${BROWSER:-chromium}"

# Start in the workspace rather than the home directory.
#
# This has to happen here rather than anywhere earlier in the launch chain:
# Openbox chdirs to $HOME when it starts, whatever directory it was started
# from, and hands that to everything it launches. So the session working
# directory cannot be set once for the desktop - terminals arrive in $HOME no
# matter what the entrypoint or xstartup does. The shell is the one place every
# terminal passes through regardless of which launcher opened it.
#
# Only when the shell landed in $HOME, which is the inherited default. A shell
# started anywhere else is left where it is, so this never overrides a directory
# somebody chose on purpose.
if [ -n "${PS1:-}" ] && [ "$PWD" = "$HOME" ] && [ -d /workspace ]; then
  cd /workspace || true
fi
