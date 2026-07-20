#!/bin/bash
# Remove gh-multi-account. Leaves your SSH keys and gh logins alone unless
# you pass --purge (they are credentials; deleting them silently would be rude).

set -euo pipefail

LIBDIR="$HOME/.local/libexec/gh-multi-account"
BINDIR="$HOME/.local/bin"
CFGDIR="$HOME/.config/gh-multi-account"
GITCFG="$CFGDIR/gitconfig"
BEGIN_SSH="# >>> gh-multi-account >>>"
END_SSH="# <<< gh-multi-account <<<"

PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

ok() { printf '  ✓ %s\n' "$*"; }

ACCOUNTS=()
# shellcheck disable=SC1091
[ -r "$CFGDIR/config" ] && . "$CFGDIR/config"

# git include line
if git config --global --get-all include.path 2>/dev/null | grep -qxF "$GITCFG"; then
    git config --global --unset-all include.path "$(printf '%s' "$GITCFG" | sed 's/[].[^$\\*/]/\\&/g')" 2>/dev/null \
        || git config --global --unset-all include.path 2>/dev/null || true
    ok "removed include from ~/.gitconfig"
fi

# ssh config block
SSHCFG="$HOME/.ssh/config"
if [ -f "$SSHCFG" ] && grep -qF "$BEGIN_SSH" "$SSHCFG"; then
    cp "$SSHCFG" "$SSHCFG.backup-$(date +%Y%m%d%H%M%S)"
    awk -v b="$BEGIN_SSH" -v e="$END_SSH" 'index($0,b){s=1} !s{print} index($0,e){s=0}' \
        "$SSHCFG" > "$SSHCFG.new"
    mv "$SSHCFG.new" "$SSHCFG"; chmod 600 "$SSHCFG"
    ok "removed block from ~/.ssh/config"
fi

# commands
for f in gha gh-clone git-whoami ghma-setup gh; do
    [ -e "$BINDIR/$f" ] && { rm -f "$BINDIR/$f"; ok "removed $f"; }
done
for a in ${ACCOUNTS[@]+"${ACCOUNTS[@]}"}; do
    [ -e "$BINDIR/gh-$a" ] && { rm -f "$BINDIR/gh-$a"; ok "removed gh-$a"; }
done
rm -rf "$LIBDIR" && ok "removed $LIBDIR"

if [ "$PURGE" = "1" ]; then
    rm -rf "$CFGDIR"; ok "purged $CFGDIR (gh logins included)"
    for a in ${ACCOUNTS[@]+"${ACCOUNTS[@]}"}; do
        rm -f "$HOME/.ssh/id_ed25519_github_$a" "$HOME/.ssh/id_ed25519_github_$a.pub"
        ok "deleted ssh key for $a"
    done
    echo "  Remember to remove the deploy keys from github.com/settings/keys"
else
    rm -f "$CFGDIR/gitconfig"
    ok "kept $CFGDIR (gh logins, identities) and your SSH keys"
    echo "  Use --purge to delete those too."
fi

echo
echo "Done. Your global git identity was NOT restored automatically —"
echo "check the commented lines at the bottom of ~/.gitconfig if you want it back."
