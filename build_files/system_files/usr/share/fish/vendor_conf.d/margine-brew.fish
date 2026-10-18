# Homebrew in fish, once `ujust lucciola-devmode` has installed it in
# /home/linuxbrew/.linuxbrew. Without Homebrew this does nothing. Same rule
# as /etc/profile.d/margine-brew.sh: brew's directories go after the
# system's, so a formula never shadows a system command.
if test -x /home/linuxbrew/.linuxbrew/bin/brew; and not set -q HOMEBREW_PREFIX
    /home/linuxbrew/.linuxbrew/bin/brew shellenv fish 2>/dev/null | source
    fish_add_path --global --move --append --path /home/linuxbrew/.linuxbrew/bin /home/linuxbrew/.linuxbrew/sbin
end
