# shellcheck shell=sh
# Homebrew in the shell, once `ujust lucciola-devmode` has installed it in
# /home/linuxbrew/.linuxbrew. Without Homebrew this does nothing.
#
# The variables come from `brew shellenv`; its PATH line is left out and
# brew's directories go AFTER the system's, as in Universal Blue's brew.sh:
# a formula never shadows a system command (dbus, python3, systemctl...).
# Sourced by bash (login and interactive, through /etc/bashrc) and by zsh
# login shells (/etc/zprofile); fish has margine-brew.fish.
if [ -x /home/linuxbrew/.linuxbrew/bin/brew ] && [ -z "${HOMEBREW_PREFIX:-}" ]; then
  eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv bash 2>/dev/null | /usr/bin/grep -Ev '(^|[^A-Z_])PATH=')"
  case ":${PATH:-}:" in
    *:/home/linuxbrew/.linuxbrew/bin:*) ;;
    *) PATH="${PATH:+$PATH:}/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin"; export PATH ;;
  esac
fi
