#!/usr/bin/env bash
# Shared logic for gh-multi-account. Sourced by everything in bin/ and hooks/.
#
# Prints the account label for the current repo, or fails if it cannot tell.
# Detection mirrors the includeIf rules written into the generated gitconfig,
# so git and gh can never disagree about which account is in play:
#
#   1. the remote URL naming a host alias   (authoritative)
#   2. failing that, the directory the repo lives in
#
# There is no "currently active account" anywhere. That is the point: two
# shells in two repos must not be able to change each other's account.

GHMA_CONFIG="${GHMA_CONFIG:-$HOME/.config/gh-multi-account/config}"

if [ ! -r "$GHMA_CONFIG" ]; then
    {
        echo "gh-multi-account: cannot read its config."
        echo "  Expected: $GHMA_CONFIG"
        echo "  This usually means the install is incomplete or was removed"
        echo "  while hooks were still wired up. Re-run install.sh, or remove"
        echo "  core.hooksPath and the include line from ~/.gitconfig."
    } >&2
    exit 1
fi
# shellcheck disable=SC1090
. "$GHMA_CONFIG"

if [ "${#ACCOUNTS[@]}" -eq 0 ]; then
    echo "gh-multi-account: no accounts configured in $GHMA_CONFIG" >&2
    exit 1
fi

: "${PROJECTS_ROOT:=$HOME/Projects}"
GHMA_DIR="$(dirname "$GHMA_CONFIG")"

# Resolve to a physical path (no symlinks, no doubled slashes). Essential:
# `git rev-parse --show-toplevel` always reports the physical path, and git
# resolves symlinks when matching `gitdir:`. If PROJECTS_ROOT is stored with a
# symlink in it — /tmp, a symlinked /home, an external volume — a plain string
# comparison silently fails to match and every repo looks unaffiliated.
# No `realpath` dependency: it is not on stock macOS.
ghma_realpath() {
    local p="${1:-}" d b
    [ -n "$p" ] || return 1
    if [ -d "$p" ]; then (cd "$p" 2>/dev/null && pwd -P) && return 0; fi
    d="$(dirname "$p")"; b="$(basename "$p")"
    if [ -d "$d" ]; then echo "$(cd "$d" 2>/dev/null && pwd -P)/$b"
    else echo "$p"; fi
}
PROJECTS_ROOT="$(ghma_realpath "$PROJECTS_ROOT")"

# Fall back to gh on PATH if the recorded one has moved.
if [ -z "${GH_REAL:-}" ] || [ ! -x "$GH_REAL" ]; then
    GH_REAL="$(command -v gh 2>/dev/null || echo gh)"
fi

ghma_accounts()   { printf '%s\n' "${ACCOUNTS[@]}"; }
ghma_is_account() { local a; for a in "${ACCOUNTS[@]}"; do [ "$a" = "$1" ] && return 0; done; return 1; }
ghma_config_dir()    { ghma_is_account "$1" || return 1; echo "$GHMA_DIR/gh-$1"; }
ghma_ssh_key()       { ghma_is_account "$1" || return 1; echo "$HOME/.ssh/id_ed25519_github_$1"; }
ghma_identity_file() { ghma_is_account "$1" || return 1; echo "$GHMA_DIR/git-$1.gitconfig"; }

# The repo root, correct inside linked worktrees too. --show-toplevel returns
# the worktree path, which is not necessarily under PROJECTS_ROOT even when the
# main checkout is; --git-common-dir points at the shared .git of the original.
ghma_repo_dir() {
    local top common
    top="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
    common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    if [ -n "$common" ] && [ "$common" != "$top/.git" ]; then
        # linked worktree: prefer the main checkout's location for routing
        local main_root="${common%/.git}"
        [ -d "$main_root" ] && { ghma_realpath "$main_root"; return 0; }
    fi
    ghma_realpath "$top"
}

# Every github remote URL in this repo, one per line.
ghma_remote_urls() { git config --get-regexp '^remote\..*\.url$' 2>/dev/null | awk '{print $2}'; }

# Which account does a single URL name? Empty if none.
ghma_account_for_url() {
    local url="$1" a
    for a in "${ACCOUNTS[@]}"; do
        # the trailing : or / matters — it stops "work" matching "work2"
        case "$url" in
            *github.com-"$a":*|*github.com-"$a"/*) echo "$a"; return 0 ;;
        esac
    done
    return 1
}

# True if remotes point at more than one account — genuinely ambiguous, and
# git would resolve it by whichever includeIf happens to be listed last.
ghma_conflicting_remotes() {
    local url acct seen="" out=""
    while read -r url; do
        [ -z "$url" ] && continue
        acct="$(ghma_account_for_url "$url" || true)"
        [ -z "$acct" ] && continue
        case " $seen " in *" $acct "*) continue ;; esac
        seen="$seen $acct"; out="$out $acct"
    done <<EOF
$(ghma_remote_urls)
EOF
    set -- $out
    [ $# -gt 1 ] || return 1
    echo "$*"
}

# The main event: which account does this directory belong to?
ghma_detect_account() {
    local url acct repo a

    # rule 1: remote URL. origin first, then any other remote.
    url="$(git config --get remote.origin.url 2>/dev/null)"
    if [ -n "$url" ] && acct="$(ghma_account_for_url "$url")"; then echo "$acct"; return 0; fi
    while read -r url; do
        [ -z "$url" ] && continue
        if acct="$(ghma_account_for_url "$url")"; then echo "$acct"; return 0; fi
    done <<EOF
$(ghma_remote_urls)
EOF

    # rule 2: directory
    repo="$(ghma_repo_dir 2>/dev/null || pwd)"
    for a in "${ACCOUNTS[@]}"; do
        case "$repo/" in "$PROJECTS_ROOT/$a/"*) echo "$a"; return 0 ;; esac
    done
    return 1
}

# What git ACTUALLY decided, by asking git which file supplied user.email
# rather than re-deriving the rules. Used to catch any drift between this
# script's understanding and git's.
ghma_account_from_git() {
    local origin a idf
    origin="$(git config --show-origin --get user.email 2>/dev/null | awk '{print $1}')"
    [ -n "$origin" ] || return 1
    origin="${origin#file:}"
    for a in "${ACCOUNTS[@]}"; do
        idf="$(ghma_identity_file "$a")"
        [ "$origin" = "$idf" ] && { echo "$a"; return 0; }
    done
    return 1
}

ghma_expected_email() {
    local idf; idf="$(ghma_identity_file "$1")" || return 1
    git config -f "$idf" --get user.email 2>/dev/null
}

# The identity git would really use, including GIT_AUTHOR_EMAIL / committer
# env overrides that plain `git config` does not show.
ghma_actual_author_email()    { git var GIT_AUTHOR_IDENT    2>/dev/null | sed -n 's/.*<\(.*\)>.*/\1/p'; }
ghma_actual_committer_email() { git var GIT_COMMITTER_IDENT 2>/dev/null | sed -n 's/.*<\(.*\)>.*/\1/p'; }

# Refuse to run when an environment token is set: GH_TOKEN / GITHUB_TOKEN
# outrank GH_CONFIG_DIR inside gh, so either silently pins every command to one
# account regardless of which wrapper was used.
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

ghma_colors() {
    if [ -t "${1:-1}" ] && [ -n "${TERM:-}" ] && [ "${TERM:-}" != "dumb" ]; then
        B=$(tput bold 2>/dev/null || echo ""); R=$(tput sgr0 2>/dev/null || echo "")
        RED=$(tput setaf 1 2>/dev/null || echo ""); GRN=$(tput setaf 2 2>/dev/null || echo "")
        YEL=$(tput setaf 3 2>/dev/null || echo ""); DIM=$(tput setaf 8 2>/dev/null || echo "")
    else
        B=""; R=""; RED=""; GRN=""; YEL=""; DIM=""
    fi
}

# Shared by pre-commit and pre-merge-commit: is the identity about to be used
# the right one for this repo? Prints an explanation and returns non-zero if not.
ghma_verify_pending_identity() {
    local account expected actual ghma_conflict
    ghma_colors 2

    if ghma_conflict="$(ghma_conflicting_remotes)"; then
        printf '%s%sgh-multi-account: this repo has remotes for MORE THAN ONE account (%s).%s\n' \
            "$B" "$RED" "$ghma_conflict" "$R" >&2
        {
            echo "  Which identity applies is decided by config ordering, which is"
            echo "  arbitrary. Refusing rather than picking one."
            echo "  Set an explicit identity for this repo:"
            echo "    git config user.email <the address you mean>"
            echo "  (then this check passes, because you stated the intent)"
        } >&2
        return 1
    fi

    if ! account="$(ghma_detect_account)"; then
        printf '%s%sgh-multi-account: this repo names no account, so I will not commit.%s\n' "$B" "$RED" "$R" >&2
        {
            echo "  Nothing identifies it as one of: ${ACCOUNTS[*]}"
            echo "  Fix with either:"
            echo "    git remote set-url origin git@github.com-<account>:owner/repo.git"
            echo "    or move it under $PROJECTS_ROOT/<account>"
            echo "  See: git whoami"
        } >&2
        return 1
    fi

    expected="$(ghma_expected_email "$account")"
    if [ -z "$expected" ]; then
        printf '%s%sgh-multi-account: no identity configured for "%s" yet.%s\n' "$B" "$RED" "$account" "$R" >&2
        echo "  Run:  ghma-setup $account" >&2
        return 1
    fi

    actual="$(ghma_actual_author_email)"
    if [ "$expected" != "$actual" ]; then
        printf '%s%sgh-multi-account: WRONG ACCOUNT — stopped.%s\n' "$B" "$RED" "$R" >&2
        {
            echo "  This repo belongs to:  $account"
            echo "  which commits as:      $expected"
            echo "  but git would use:     $actual"
            echo
            echo "  Something is overriding the account identity. Check:"
            echo "    git config --show-origin --get-all user.email"
            echo "    env | grep GIT_AUTHOR"
            echo
            echo "  Deliberate? Use: git commit --no-verify"
        } >&2
        return 1
    fi
    return 0
}

# Run a repo's own hook, which core.hooksPath would otherwise suppress.
# Do NOT use `git rev-parse --git-path hooks/<name>`: --git-path honours
# core.hooksPath, so it resolves to the global hook and exec'ing it recurses
# forever, hanging the command. The -ef test is a second guard.
ghma_chain_repo_hook() {
    local name="$1"; shift
    local gitdir repo_hook
    gitdir="$(git rev-parse --absolute-git-dir 2>/dev/null || true)"
    [ -n "$gitdir" ] || return 0
    repo_hook="$gitdir/hooks/$name"
    if [ -x "$repo_hook" ] && ! [ "$repo_hook" -ef "${BASH_SOURCE[1]:-$0}" ]; then
        exec "$repo_hook" "$@"
    fi
    return 0
}

# Back-compat aliases for anything referencing the older names.
github_detect_account()   { ghma_detect_account; }
github_config_dir()       { ghma_config_dir "$@"; }
github_guard_env_token()  { ghma_guard_env_token; }
REAL_GH="$GH_REAL"
