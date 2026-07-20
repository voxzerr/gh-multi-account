#!/bin/bash
# Shared account detection. Sourced by every command in bin/.
#
# Prints the account label for the current directory, or exits 1 if it cannot
# tell. Detection order deliberately mirrors the includeIf rules written into
# ~/.gitconfig, so git and gh can never disagree about which account is in play:
#
#   1. the remote URL naming a host alias   (authoritative)
#   2. failing that, the directory the repo lives in
#
# There is no "currently active account" anywhere. That is the whole point:
# two shells in two repos must not be able to change each other's account.

GHMA_CONFIG="${GHMA_CONFIG:-$HOME/.config/gh-multi-account/config}"

if [ -r "$GHMA_CONFIG" ]; then
    # shellcheck disable=SC1090
    . "$GHMA_CONFIG"
else
    echo "gh-multi-account: config not found at $GHMA_CONFIG" >&2
    echo "  Run the installer, or set GHMA_CONFIG to point at it." >&2
    exit 1
fi

: "${PROJECTS_ROOT:=$HOME/Projects}"
: "${GH_REAL:=$HOME/.local/libexec/gh-multi-account/gh}"

# Fall back to whatever gh is on PATH if we are not shadowing the binary.
if [ ! -x "$GH_REAL" ]; then
    GH_REAL="$(command -v gh 2>/dev/null || echo gh)"
fi
REAL_GH="$GH_REAL"   # backwards-compatible alias

ghma_accounts() { printf '%s\n' "${ACCOUNTS[@]}"; }

ghma_is_account() {
    local a
    for a in "${ACCOUNTS[@]}"; do [ "$a" = "$1" ] && return 0; done
    return 1
}

# Print the gh config dir for an account label.
ghma_config_dir() {
    ghma_is_account "$1" || return 1
    echo "$HOME/.config/gh-multi-account/gh-$1"
}

ghma_ssh_key() {
    ghma_is_account "$1" || return 1
    echo "$HOME/.ssh/id_ed25519_github_$1"
}

ghma_identity_file() {
    ghma_is_account "$1" || return 1
    echo "$HOME/.config/gh-multi-account/git-$1.gitconfig"
}

# The heart of it: which account does the current directory belong to?
ghma_detect_account() {
    local url toplevel a

    # --- rule 1: remote URL ---
    url="$(git config --get remote.origin.url 2>/dev/null)"
    if [ -z "$url" ]; then
        url="$(git config --get-regexp '^remote\..*\.url$' 2>/dev/null | head -1 | awk '{print $2}')"
    fi
    if [ -n "$url" ]; then
        for a in "${ACCOUNTS[@]}"; do
            case "$url" in
                # the trailing : or / matters — it stops "work" matching "work2"
                *github.com-"$a":*|*github.com-"$a"/*) echo "$a"; return 0 ;;
            esac
        done
    fi

    # --- rule 2: directory ---
    toplevel="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    for a in "${ACCOUNTS[@]}"; do
        case "$toplevel/" in
            "$PROJECTS_ROOT/$a/"*) echo "$a"; return 0 ;;
        esac
    done

    return 1
}

# Refuse to run when an environment token is set. GH_TOKEN / GITHUB_TOKEN
# outrank GH_CONFIG_DIR inside gh, so either one silently pins every command to
# a single account regardless of which wrapper was used.
ghma_guard_env_token() {
    if [ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]; then
        {
            echo "gh-multi-account: GH_TOKEN or GITHUB_TOKEN is set."
            echo "  An environment token overrides per-account config and would"
            echo "  silently make every command use one account. Refusing to run."
            echo "  Unset it:  unset GH_TOKEN GITHUB_TOKEN"
        } >&2
        exit 2
    fi
}

# Back-compat aliases used by older installs.
github_detect_account() { ghma_detect_account; }
github_config_dir() { ghma_config_dir "$@"; }
github_guard_env_token() { ghma_guard_env_token; }
