#!/usr/bin/env bash
# Test suite for gh-multi-account.
#
#   tests/run-tests.sh
#
# Everything runs inside a throwaway HOME, so your real setup is never touched.
# It installs from source into that sandbox, which means install.sh is under
# test too. No network and no GitHub account required — `gh` is stubbed, since
# nothing here needs a real API.

set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/ghma-tests.XXXXXX")"
H="$SANDBOX/home"
export GIT_CONFIG_SYSTEM=/dev/null      # ignore Xcode's system gitconfig
export GIT_CONFIG_NOSYSTEM=1

if [ -t 1 ] && [ -n "${TERM:-}" ] && [ "$TERM" != "dumb" ]; then
    GRN=$(tput setaf 2); RED=$(tput setaf 1); DIM=$(tput setaf 8); B=$(tput bold); R=$(tput sgr0)
else GRN=""; RED=""; DIM=""; B=""; R=""; fi

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  %s✓%s %s\n' "$GRN" "$R" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  %s✗%s %s\n' "$RED" "$R" "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }
group(){ printf '\n%s%s%s\n' "$B" "$1" "$R"; }

cleanup() { [ -n "${KEEP_SANDBOX:-}" ] || rm -rf "$SANDBOX"; }
trap cleanup EXIT

g() { HOME="$H" git "$@"; }

# assert_blocked <desc> <command...>  — command must fail
assert_blocked() { local d="$1"; shift
    if out="$("$@" 2>&1)"; then bad "$d (expected failure, it succeeded)"; else ok "$d"; fi; }
# assert_ok <desc> <command...>  — command must succeed
assert_ok() { local d="$1"; shift
    if out="$("$@" 2>&1)"; then ok "$d"; else bad "$d" "$(echo "$out" | head -2)"; fi; }
assert_eq() {
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }

# ---------------------------------------------------------------- install --
mkdir -p "$H" "$SANDBOX/fakebin"
cat > "$SANDBOX/fakebin/gh" <<'EOF'
#!/usr/bin/env bash
# stub: enough for install.sh's preflight and for wrappers to be traceable
case "$1" in
  --version) echo "gh version 0.0.0 (stub)" ;;
  *) echo "STUB_GH config_dir=${GH_CONFIG_DIR:-none} args=$*" ;;
esac
exit 0
EOF
chmod 755 "$SANDBOX/fakebin/gh"
export PATH="$SANDBOX/fakebin:$PATH"

printf '%sInstalling into sandbox %s%s\n' "$DIM" "$SANDBOX" "$R"
if ! out="$(env HOME="$H" PATH="$PATH" SHELL=/bin/bash TERM=dumb \
        bash "$SRC/install.sh" personal work -y 2>&1)"; then
    printf '%sinstall.sh FAILED%s\n%s\n' "$RED" "$R" "$out"; exit 1
fi

CFG="$H/.config/gh-multi-account"
export GHMA_LIB="$H/.local/libexec/gh-multi-account"
BIN="$H/.local/bin"

# simulate ghma-setup having run
printf '[user]\n\tname = P\n\temail = p@users.noreply.github.com\n' > "$CFG/git-personal.gitconfig"
printf '[user]\n\tname = W\n\temail = w@users.noreply.github.com\n' > "$CFG/git-work.gitconfig"

newrepo() { rm -rf "$1"; mkdir -p "$1"; cd "$1" || exit 1; g init -q .; }
commitfile() { echo "$RANDOM" > "$1"; g add "$1"; }

# ---------------------------------------------------------------- routing --
group "Identity routing"
newrepo "$H/Projects/work/a";     assert_eq "directory -> work"     "$(g config --get user.email)" "w@users.noreply.github.com"
newrepo "$H/Projects/personal/b"; assert_eq "directory -> personal" "$(g config --get user.email)" "p@users.noreply.github.com"

newrepo "$SANDBOX/r1"; g remote add origin "git@github.com-work:o/r.git"
assert_eq "scp-style remote -> work" "$(g config --get user.email)" "w@users.noreply.github.com"

newrepo "$SANDBOX/r2"; g remote add origin "ssh://git@github.com-personal/o/r.git"
assert_eq "ssh:// remote -> personal" "$(g config --get user.email)" "p@users.noreply.github.com"

newrepo "$H/Projects/personal/c"; g remote add origin "git@github.com-work:o/r.git"
assert_eq "remote beats directory" "$(g config --get user.email)" "w@users.noreply.github.com"

newrepo "$SANDBOX/r3"
assert_eq "unaffiliated repo has no identity" "$(g config --get user.email || echo NONE)" "NONE"

newrepo "$SANDBOX/r4"; g remote add origin "git@github.com:o/r.git"
assert_eq "bare github.com names no account" "$(g config --get user.email || echo NONE)" "NONE"

# label prefixes must not collide (work vs work2)
newrepo "$SANDBOX/r5"; g remote add origin "git@github.com-work2:o/r.git"
assert_eq "work2 does not match work" "$(g config --get user.email || echo NONE)" "NONE"

# ----------------------------------------------------------------- guards --
group "Commit guards"
newrepo "$SANDBOX/g1"; commitfile f
assert_blocked "unaffiliated repo cannot commit" g commit -m t

newrepo "$H/Projects/work/g2"; commitfile f
assert_ok "correct identity commits" g commit -m t

newrepo "$H/Projects/work/g3"; g config user.email "p@users.noreply.github.com"; commitfile f
assert_blocked "repo-local wrong identity is blocked" g commit -m t

newrepo "$H/Projects/work/g4"; commitfile f
assert_blocked "GIT_AUTHOR_EMAIL override is blocked" \
    env HOME="$H" GIT_AUTHOR_EMAIL=p@users.noreply.github.com GIT_COMMITTER_EMAIL=p@users.noreply.github.com git commit -m t

newrepo "$H/Projects/work/g5"; commitfile f
assert_ok "--no-verify bypasses deliberately" g commit --no-verify -m t

# --------------------------------------------------------- merge coverage --
group "Merge commits (git runs pre-merge-commit, not pre-commit)"
newrepo "$H/Projects/work/m1"; commitfile a; g commit -q -m base
g checkout -q -b side; commitfile b; g commit -q -m side
g checkout -q main 2>/dev/null || g checkout -q master
commitfile c; g commit -q -m main2
assert_ok "correct identity can merge" g merge --no-ff side -m merged

newrepo "$H/Projects/work/m2"; commitfile a; g commit -q -m base
g checkout -q -b side; commitfile b; g commit -q -m side
g checkout -q main 2>/dev/null || g checkout -q master
commitfile c; g commit -q -m main2
g config user.email "p@users.noreply.github.com"
assert_blocked "merge with wrong identity is blocked" g merge --no-ff side -m merged

# ------------------------------------------------------------- multi-remote --
group "Ambiguous remotes"
newrepo "$SANDBOX/mr"; g remote add origin "git@github.com-work:o/r.git"
g remote add other "git@github.com-personal:o/r.git"; commitfile f
assert_blocked "remotes for two accounts are refused" g commit -m t

# ----------------------------------------------------------------- push --
group "Push guard (the backstop for cherry-pick and revert)"
BARE="$SANDBOX/bare.git"; git init -q --bare "$BARE"
newrepo "$H/Projects/work/p1"; commitfile f; g commit -q -m good
g remote add origin "$BARE"
assert_ok "correct-identity commits push" g push -q origin HEAD:refs/heads/main

newrepo "$H/Projects/work/p2"; commitfile f; g commit -q -m good
# a commit that skipped the commit hook, exactly as cherry-pick/revert produce
g config user.email "p@users.noreply.github.com"
commitfile f2; g commit -q --no-verify -m "as if cherry-picked"
g config --unset user.email
BARE2="$SANDBOX/bare2.git"; git init -q --bare "$BARE2"; g remote add origin "$BARE2"
assert_blocked "wrong-account commit is blocked at push" g push -q origin HEAD:refs/heads/main

newrepo "$H/Projects/work/p3"; commitfile f; g commit -q -m good
BARE3="$SANDBOX/bare3.git"; git init -q --bare "$BARE3"; g remote add origin "$BARE3"
g push -q origin HEAD:refs/heads/main
# delete a NON-default branch: a bare repo refuses to delete its own HEAD
# branch for reasons of its own, which has nothing to do with our hook
g push -q origin HEAD:refs/heads/scratch
assert_ok "branch deletion is not blocked" g push -q origin :refs/heads/scratch

# ------------------------------------------------------- post-commit warn --
group "post-commit warning (cherry-pick/revert have no pre-hook at all)"
newrepo "$H/Projects/work/pc"; commitfile f; g commit -q -m base
g config user.email "p@users.noreply.github.com"
commitfile f2
out="$(g commit --no-verify -m sneaky 2>&1)"
if echo "$out" | grep -q "wrong account"; then ok "post-commit warns about a wrong-account commit"
else bad "post-commit warns about a wrong-account commit" "no warning in output"; fi

# ------------------------------------------------------------ hook chaining --
group "Repo-local hooks still work"
newrepo "$H/Projects/work/h1"
mkdir -p .git/hooks
printf '#!/usr/bin/env bash\necho REPO_HOOK_RAN\nexit 0\n' > .git/hooks/pre-commit
chmod 755 .git/hooks/pre-commit
commitfile f
out="$(g commit -m t 2>&1)"
if echo "$out" | grep -q REPO_HOOK_RAN; then ok "repo-local pre-commit is chained"
else bad "repo-local pre-commit is chained" "hook output missing"; fi

newrepo "$H/Projects/work/h2"
mkdir -p .git/hooks
printf '#!/usr/bin/env bash\nexit 1\n' > .git/hooks/pre-commit
chmod 755 .git/hooks/pre-commit
commitfile f
assert_blocked "repo-local hook can still veto" g commit -m t

# ----------------------------------------------------------- gh wrapper --
group "gh account routing"
cd "$H/Projects/work/a"
out="$(HOME="$H" "$BIN/gha" auto api user 2>&1)"
if echo "$out" | grep -q "gh-work"; then ok "gha auto picks the repo's account"
else bad "gha auto picks the repo's account" "$out"; fi

cd "$SANDBOX"
if HOME="$H" "$BIN/gha" auto api user >/dev/null 2>&1; then
    bad "gha auto refuses outside a known repo"
else ok "gha auto refuses outside a known repo"; fi

out="$(HOME="$H" GH_TOKEN=xyz "$BIN/gha" personal api user 2>&1)"
if echo "$out" | grep -qi "GH_TOKEN"; then ok "env token is refused"
else bad "env token is refused" "$out"; fi

# ----------------------------------------------------------------- doctor --
group "Doctor"
cd "$H"
out="$(HOME="$H" "$BIN/ghma-doctor" --offline 2>&1)"; rc=$?
if [ $rc -eq 0 ]; then ok "doctor passes on a healthy sandbox"
else bad "doctor passes on a healthy sandbox" "$(echo "$out" | grep '✗' | head -3)"; fi

mv "$CFG/git-work.gitconfig" "$CFG/git-work.gitconfig.bak"
if HOME="$H" "$BIN/ghma-doctor" --offline >/dev/null 2>&1; then
    bad "doctor fails when an identity is missing"
else ok "doctor fails when an identity is missing"; fi
mv "$CFG/git-work.gitconfig.bak" "$CFG/git-work.gitconfig"

# --------------------------------------------------------------- uninstall --
group "Uninstall"
assert_ok "uninstall runs cleanly" env HOME="$H" PATH="$PATH" TERM=dumb bash "$SRC/uninstall.sh"
newrepo "$SANDBOX/post"; commitfile f
assert_ok "git works normally again afterwards" \
    env HOME="$H" git -c user.email=a@b.c -c user.name=T commit -m t

# ------------------------------------------------------------------ done --
printf '\n%s%s passed%s' "$GRN" "$PASS" "$R"
[ "$FAIL" -gt 0 ] && printf ', %s%s failed%s' "$RED" "$FAIL" "$R"
printf '\n'
[ -n "${KEEP_SANDBOX:-}" ] && printf '%ssandbox kept at %s%s\n' "$DIM" "$SANDBOX" "$R"
[ "$FAIL" -eq 0 ]
