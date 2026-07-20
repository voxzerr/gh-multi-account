#!/bin/bash
# gh-multi-account installer.
#
#   ./install.sh personal work
#   ./install.sh personal work --projects-root ~/code --shadow-gh
#
# Touches as little of your existing setup as possible: it adds ONE include
# line to ~/.gitconfig and ONE marked block to ~/.ssh/config, and backs up
# both first. Everything else lives under ~/.config/gh-multi-account.
# Re-running is safe. ./uninstall.sh reverses it.

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIBDIR="$HOME/.local/libexec/gh-multi-account"
BINDIR="$HOME/.local/bin"
CFGDIR="$HOME/.config/gh-multi-account"
GITCFG="$CFGDIR/gitconfig"
CONFIG="$CFGDIR/config"

BEGIN_SSH="# >>> gh-multi-account >>>"
END_SSH="# <<< gh-multi-account <<<"

if [ -t 1 ]; then
    B=$(tput bold); R=$(tput sgr0); RED=$(tput setaf 1); GRN=$(tput setaf 2); YEL=$(tput setaf 3)
else B=""; R=""; RED=""; GRN=""; YEL=""; fi
say()  { printf '%s%s%s\n' "$B" "$*" "$R"; }
ok()   { printf '  %s✓%s %s\n' "$GRN" "$R" "$*"; }
warn() { printf '  %s!%s %s\n' "$YEL" "$R" "$*"; }
die()  { printf '%s✗ %s%s\n' "$RED" "$*" "$R" >&2; exit 1; }

# ----------------------------------------------------------------- arguments --
ACCOUNTS=(); PROJECTS_ROOT="$HOME/Projects"; SHADOW_GH=0; ASSUME_YES=0
while [ $# -gt 0 ]; do
    case "$1" in
        --projects-root) PROJECTS_ROOT="${2:?--projects-root needs a path}"; shift 2 ;;
        --shadow-gh)     SHADOW_GH=1; shift ;;
        -y|--yes)        ASSUME_YES=1; shift ;;
        -h|--help)
            sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) die "unknown option: $1" ;;
        *)  ACCOUNTS+=("$1"); shift ;;
    esac
done
PROJECTS_ROOT="${PROJECTS_ROOT/#\~/$HOME}"
# Store the PHYSICAL path. git resolves symlinks when matching `gitdir:`, and
# reports physical paths from rev-parse, so a symlinked root (a symlinked /home,
# /tmp on macOS, an external volume) would silently never match.
mkdir -p "$PROJECTS_ROOT" 2>/dev/null || true
PROJECTS_ROOT="$(cd "$PROJECTS_ROOT" 2>/dev/null && pwd -P || echo "$PROJECTS_ROOT")"

if [ ${#ACCOUNTS[@]} -eq 0 ]; then
    say "Which accounts do you want? These become folder names and command"
    say "arguments, so keep them short and lowercase (e.g. personal work)."
    read -r -p "Account labels, space separated [personal work]: " reply
    [ -z "$reply" ] && reply="personal work"
    # shellcheck disable=SC2206
    ACCOUNTS=($reply)
fi
[ ${#ACCOUNTS[@]} -ge 2 ] || die "give at least two account labels (got: ${ACCOUNTS[*]})"

for a in "${ACCOUNTS[@]}"; do
    case "$a" in
        *[!a-z0-9-]*) die "account label '$a' must be lowercase letters, digits or dashes" ;;
    esac
done
# reject duplicates
if [ "$(printf '%s\n' "${ACCOUNTS[@]}" | sort -u | wc -l)" -ne "${#ACCOUNTS[@]}" ]; then
    die "duplicate account labels in: ${ACCOUNTS[*]}"
fi

# ----------------------------------------------------------------- preflight --
say "Checking prerequisites"
command -v git >/dev/null || die "git is not installed"
gitver="$(git --version | awk '{print $3}')"
gitmaj="${gitver%%.*}"; gitrest="${gitver#*.}"; gitmin="${gitrest%%.*}"
if [ "$gitmaj" -lt 2 ] || { [ "$gitmaj" -eq 2 ] && [ "$gitmin" -lt 36 ]; }; then
    die "git $gitver is too old — need 2.36+ for conditional remote-URL config"
fi
ok "git $gitver"
command -v ssh-keygen >/dev/null || die "ssh-keygen is not installed"
ok "ssh available"

# Find the real gh, taking care not to find our own wrapper if one is installed.
GH_REAL=""
for cand in $(type -a -p gh 2>/dev/null || true); do
    [ "$cand" = "$BINDIR/gh" ] && continue   # skip our own shim if already installed
    GH_REAL="$cand"; break
done
if [ -n "$GH_REAL" ]; then
    ok "gh CLI at $GH_REAL ($("$GH_REAL" --version 2>/dev/null | head -1))"
else
    warn "gh CLI not found. Install it, then re-run this script:"
    echo "      macOS:  brew install gh"
    echo "      Linux:  see https://github.com/cli/cli#installation"
    echo "      or grab a release: https://github.com/cli/cli/releases"
    die "gh is required"
fi

# -------------------------------------------------- existing global identity --
EXISTING_EMAIL="$(git config --global --get user.email 2>/dev/null || true)"
EXISTING_NAME="$(git config --global --get user.name 2>/dev/null || true)"

echo
say "Plan"
echo "  accounts       ${ACCOUNTS[*]}"
echo "  project root   $PROJECTS_ROOT/<account>"
echo "  ssh keys       ~/.ssh/id_ed25519_github_<account>  (created if missing)"
echo "  config         ${CFGDIR/#$HOME/~}"
echo "  commands       ${BINDIR/#$HOME/~}/{gha,gh-clone,git-whoami,ghma-setup}"
[ "$SHADOW_GH" = "1" ] && echo "  also           a 'gh' wrapper that auto-picks the account"
echo "  modifies       ~/.gitconfig (one include line), ~/.ssh/config (one block)"
if [ -n "$EXISTING_EMAIL" ] || [ -n "$EXISTING_NAME" ]; then
    echo
    warn "You currently have a global git identity:"
    [ -n "$EXISTING_NAME" ]  && echo "      user.name  = $EXISTING_NAME"
    [ -n "$EXISTING_EMAIL" ] && echo "      user.email = $EXISTING_EMAIL"
    echo "    This must be removed — a global identity silently overrides the"
    echo "    per-account one and defeats the whole point. It will be commented"
    echo "    out (not deleted) and ~/.gitconfig backed up first."
fi
echo
if [ "$ASSUME_YES" != "1" ]; then
    read -r -p "Proceed? [y/N] " go
    case "$go" in y|Y|yes|YES) ;; *) echo "Aborted."; exit 1 ;; esac
fi

backup() {  # backup <file>
    [ -e "$1" ] || return 0
    local bak
    bak="$1.backup-$(date +%Y%m%d%H%M%S)"
    cp "$1" "$bak"; ok "backed up ${1/#$HOME/~} -> ${bak##*/}"
}
strip_block() {  # strip_block <file> <begin> <end>  -> stdout
    awk -v b="$2" -v e="$3" 'index($0,b){s=1} !s{print} index($0,e){s=0}' "$1"
}

# --------------------------------------------------------------- directories --
echo
say "Installing"
mkdir -p "$LIBDIR" "$BINDIR" "$CFGDIR" "$HOME/.ssh"
chmod 700 "$HOME/.ssh" "$CFGDIR"
for a in "${ACCOUNTS[@]}"; do
    mkdir -p "$PROJECTS_ROOT/$a" "$CFGDIR/gh-$a"
    chmod 700 "$CFGDIR/gh-$a"
done
ok "directories"

# ------------------------------------------------------------------- config --
{
    echo "# gh-multi-account config. Written by install.sh; safe to edit."
    echo "ACCOUNTS=(${ACCOUNTS[*]})"
    echo "PROJECTS_ROOT=\"$PROJECTS_ROOT\""
    echo "GH_REAL=\"$GH_REAL\""
} > "$CONFIG"
ok "config"

# ----------------------------------------------------------------- ssh keys --
for a in "${ACCOUNTS[@]}"; do
    key="$HOME/.ssh/id_ed25519_github_$a"
    if [ -f "$key" ]; then
        ok "ssh key for $a already exists (kept)"
    else
        ssh-keygen -t ed25519 -f "$key" -N "" -q \
            -C "github-$a ($(whoami)@$(scutil --get LocalHostName 2>/dev/null || hostname))"
        chmod 600 "$key"; chmod 644 "$key.pub"
        ok "generated ssh key for $a"
    fi
done
warn "keys have no passphrase. Add one later with: ssh-keygen -p -f <key>"

# --------------------------------------------------------------- known_hosts --
# Entirely optional: without it ssh simply asks you to confirm GitHub's
# fingerprint once. So this must never be able to fail the install.
#
# It runs with `set +e` deliberately. Under `set -euo pipefail`, an assignment
# from a pipeline whose first stage fails takes down the whole script — and
# because stderr is suppressed here, it would die with no message at all.
# That is exactly how this failed on newer macOS in CI.
pin_host_keys() {
    set +e
    command -v curl >/dev/null || { warn "curl missing; skipping host key pinning"; return 0; }
    command -v python3 >/dev/null || { warn "python3 missing; skipping host key pinning"; return 0; }

    local fps scanned added=0 line fp body h
    fps="$(curl -sSL --max-time 15 https://api.github.com/meta 2>/dev/null \
        | python3 -c 'import json,sys;print("\n".join(json.load(sys.stdin)["ssh_key_fingerprints"].values()))' 2>/dev/null)"
    if [ -z "$fps" ]; then
        warn "could not fetch GitHub's published host keys; ssh will ask once"
        return 0
    fi

    scanned="$(ssh-keyscan -t rsa,ecdsa,ed25519 github.com 2>/dev/null)"
    if [ -z "$scanned" ]; then
        warn "could not reach github.com to read host keys; ssh will ask once"
        return 0
    fi

    touch "$HOME/.ssh/known_hosts" 2>/dev/null
    chmod 600 "$HOME/.ssh/known_hosts" 2>/dev/null
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        fp="$(printf '%s\n' "$line" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}' | sed 's|^SHA256:||')"
        [ -n "$fp" ] || continue
        # only trust a key GitHub itself publishes the fingerprint for
        printf '%s\n' "$fps" | grep -qxF "$fp" || continue
        body="$(printf '%s\n' "$line" | awk '{print $2" "$3}')"
        [ -n "$body" ] || continue
        grep -qF "$body" "$HOME/.ssh/known_hosts" 2>/dev/null && continue
        for h in github.com "${ACCOUNTS[@]/#/github.com-}"; do
            printf '%s %s\n' "$h" "$body" >> "$HOME/.ssh/known_hosts"
        done
        added=$((added + 1))
    done <<EOF
$scanned
EOF

    if [ "$added" -gt 0 ]; then ok "verified and pinned $added GitHub host key(s)"
    else ok "GitHub host keys already known"; fi
    return 0
}
pin_host_keys || true
set -euo pipefail

# --------------------------------------------------------------- ssh config --
SSHCFG="$HOME/.ssh/config"
touch "$SSHCFG"; chmod 600 "$SSHCFG"
backup "$SSHCFG"
{
    echo "$BEGIN_SSH"
    echo "# Managed by gh-multi-account. Do not edit between these markers."
    echo "#"
    echo "# There is deliberately NO 'Host github.com' entry: a remote of"
    echo "# git@github.com:owner/repo.git names no account, so it should fail"
    echo "# rather than authenticate as whichever key ssh happens to try first."
    echo "# Use git@github.com-<account>:owner/repo.git instead."
    echo "IgnoreUnknown UseKeychain"
    for a in "${ACCOUNTS[@]}"; do
        echo
        echo "Host github.com-$a"
        echo "    HostName github.com"
        echo "    User git"
        echo "    IdentityFile ~/.ssh/id_ed25519_github_$a"
        echo "    IdentitiesOnly yes"     # without this ssh offers every agent key
        echo "    AddKeysToAgent yes"
        echo "    UseKeychain yes"        # macOS only; IgnoreUnknown covers others
    done
    echo "$END_SSH"
    echo
    strip_block "$SSHCFG" "$BEGIN_SSH" "$END_SSH"
} > "$SSHCFG.new"
mv "$SSHCFG.new" "$SSHCFG"; chmod 600 "$SSHCFG"
ok "ssh config"

# --------------------------------------------------------------- git config --
{
    echo "# Managed by gh-multi-account. Included from ~/.gitconfig."
    echo "#"
    echo "# No name/email here, and useConfigOnly is on, so git REFUSES to"
    echo "# commit unless one of the rules below supplies an identity. Without"
    echo "# this git silently invents user@hostname and bakes it into history."
    echo "[user]"
    echo "	useConfigOnly = true"
    echo
    echo "[core]"
    echo "	hooksPath = $CFGDIR/hooks"
    echo
    echo "# Rule 1 — by directory (covers new repos with no remote yet)"
    for a in "${ACCOUNTS[@]}"; do
        echo "[includeIf \"gitdir:$PROJECTS_ROOT/$a/\"]"
        echo "	path = $CFGDIR/git-$a.gitconfig"
    done
    echo
    echo "# Rule 2 — by remote URL. Authoritative; listed later so it wins."
    echo "# Glob notes: '*' does not cross '/', and '**' is only special as a"
    echo "# whole path component — so ':*/**' is required, ':**' matches nothing."
    for a in "${ACCOUNTS[@]}"; do
        echo "[includeIf \"hasconfig:remote.*.url:git@github.com-$a:*/**\"]"
        echo "	path = $CFGDIR/git-$a.gitconfig"
        echo "[includeIf \"hasconfig:remote.*.url:ssh://git@github.com-$a/**\"]"
        echo "	path = $CFGDIR/git-$a.gitconfig"
    done
    echo
    echo "# Unqualified URLs name no account -> send them to a host that does"
    echo "# not resolve. HTTPS uses pushInsteadOf so cloning public repos still"
    echo "# works; only pushing is blocked."
    echo "[url \"ACCOUNT-NOT-SPECIFIED-use-github.com-<account>:\"]"
    echo "	insteadOf = git@github.com:"
    echo "	insteadOf = ssh://git@github.com/"
    echo "	pushInsteadOf = https://github.com/"
    echo
    echo "# Xcode's tools enable credential.helper=osxkeychain system-wide. It"
    echo "# keys on hostname only — one shared slot for all of github.com — so a"
    echo "# password saved for one account is handed to the other with no"
    echo "# prompt. Empty value resets the list. Auth here goes over SSH."
    echo "[credential]"
    echo "	helper ="
} > "$GITCFG"
ok "git config"

for a in "${ACCOUNTS[@]}"; do
    idf="$CFGDIR/git-$a.gitconfig"
    if [ -s "$idf" ] && grep -q '^\[user\]' "$idf" && grep -q 'email' "$idf"; then
        ok "identity for $a already set (kept)"
    else
        printf '# Identity for "%s" — filled in by ghma-setup.\n[user]\n' "$a" > "$idf"
        ok "identity placeholder for $a"
    fi
done

GITRC="$HOME/.gitconfig"
touch "$GITRC"
if ! git config --global --get-all include.path 2>/dev/null | grep -qxF "$GITCFG"; then
    backup "$GITRC"
    git config --global --add include.path "$GITCFG"
    ok "added include to ~/.gitconfig"
else
    ok "git config already includes ours"
fi

if [ -n "$EXISTING_EMAIL" ] || [ -n "$EXISTING_NAME" ]; then
    git config --global --unset-all user.email 2>/dev/null || true
    git config --global --unset-all user.name 2>/dev/null || true
    {
        echo ""
        echo "# Removed by gh-multi-account on $(date +%Y-%m-%d): a global identity"
        echo "# overrides per-account identities. Kept here for reference."
        [ -n "$EXISTING_NAME" ]  && echo "#   user.name  = $EXISTING_NAME"
        [ -n "$EXISTING_EMAIL" ] && echo "#   user.email = $EXISTING_EMAIL"
    } >> "$GITRC"
    ok "removed global identity (recorded as a comment, backup kept)"
fi

# ------------------------------------------------------------------ scripts --
install -m 755 "$SRC/lib/account-detect.sh" "$LIBDIR/account-detect.sh"
mkdir -p "$CFGDIR/hooks"
# All four matter: git runs a DIFFERENT hook for merges, and runs none at all
# for cherry-pick/revert — pre-push is the backstop for those.
for h in pre-commit pre-merge-commit post-commit pre-push; do
    install -m 755 "$SRC/hooks/$h" "$CFGDIR/hooks/$h"
done
ok "hooks installed (commit, merge, post-commit warning, push)"
for f in gha gh-clone git-whoami ghma-setup ghma-doctor; do
    install -m 755 "$SRC/bin/$f" "$BINDIR/$f"
done
ok "commands installed to ${BINDIR/#$HOME/~}"

# Register `git whoami` as a real alias so it works even when ~/.local/bin is
# not on PATH — which is the case for cron, GUI-launched editors, and any
# non-login shell.
git config --global alias.whoami "!$BINDIR/git-whoami"
ok "git whoami alias registered"

for a in "${ACCOUNTS[@]}"; do
    printf '#!/bin/bash\nexec "%s/gha" %s "$@"\n' "$BINDIR" "$a" > "$BINDIR/gh-$a"
    chmod 755 "$BINDIR/gh-$a"
done
ok "per-account shortcuts: $(printf 'gh-%s ' "${ACCOUNTS[@]}")"

if [ "$SHADOW_GH" = "1" ]; then
    install -m 755 "$SRC/bin/gh-wrapper" "$BINDIR/gh"
    ok "installed auto-routing 'gh' wrapper (real gh: $GH_REAL)"
fi

# --------------------------------------------------------------------- PATH --
case ":$PATH:" in
    *":$BINDIR:"*) ok "$BINDIR already on PATH" ;;
    *)
        rc=""
        case "${SHELL##*/}" in
            zsh)  rc="$HOME/.zshrc" ;;
            bash) rc="$HOME/.bashrc"; [ -f "$HOME/.bash_profile" ] && rc="$HOME/.bash_profile" ;;
        esac
        if [ -n "$rc" ] && ! grep -qs 'gh-multi-account: PATH' "$rc" 2>/dev/null; then
            {
                echo ""
                echo "# gh-multi-account: PATH"
                echo "export PATH=\"\$HOME/.local/bin:\$PATH\""
            } >> "$rc"
            ok "added $BINDIR to PATH in ${rc/#$HOME/~}"
            warn "open a NEW terminal, or run: source ${rc/#$HOME/~}"
        else
            warn "add this to your shell profile:  export PATH=\"\$HOME/.local/bin:\$PATH\""
        fi ;;
esac

# --------------------------------------------------------------------- done --
echo
say "Installed. One step left — sign in to each account:"
echo
echo "    ghma-setup"
echo
echo "  (opens a browser per account; it prints a one-time code first)"
echo "  If the command is not found yet, use: $BINDIR/ghma-setup"
echo
echo "  Then:  gh-clone ${ACCOUNTS[0]} owner/repo   and   git whoami"
