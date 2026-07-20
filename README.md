# gh-multi-account

[![CI](https://github.com/voxzerr/gh-multi-account/actions/workflows/ci.yml/badge.svg)](https://github.com/voxzerr/gh-multi-account/actions/workflows/ci.yml)

Use two (or more) GitHub accounts on one machine without ever mixing them up.

No switching. No "which account am I on right now?" Each repo knows which
account it belongs to, and git and the `gh` CLI both follow along
automatically. If a repo is ambiguous, **git refuses to commit** rather than
guessing.

```console
$ git whoami
Repo        /Users/you/Projects/work/api
Account     work  (from remote URL)
Commits as  Your Name <1234+youatwork@users.noreply.github.com>
Remote      git@github.com-work:acme/api.git
gh CLI      logged in as youatwork
```

---

## The problem with switching

Most multi-account setups give you a command to switch the "active" account.
That works fine until you have two terminals open, or an editor running tasks
in the background, or an AI coding agent working in another repo. There is one
global setting, and whoever writes to it last wins. You find out days later,
when commits show up under the wrong name on someone else's project.

The deeper issue is that git does not fail safe here. With no identity
configured, git does **not** stop — it invents one from your username and
hostname and commits anyway:

```console
$ git commit -m "oops"
[main 1a2b3c4] oops
 Author: You <you@Your-MacBook-Pro.lan>   # now in history, forever
```

## The approach

Identity is a property of the repo, not of the machine's current state.

| How it's decided | Example | Result |
|---|---|---|
| The remote URL's host alias | `git@github.com-work:acme/api.git` | `work` |
| Where the repo lives | `~/Projects/personal/blog` | `personal` |

The remote URL wins when both apply. Repos matching neither are refused, not
guessed. Since nothing is stored globally, two shells in two repos resolve
their accounts independently and cannot interfere with each other.

---

## Install

Requires **git 2.36+**, **ssh**, and the [GitHub CLI](https://cli.github.com/).
macOS and Linux.

```sh
git clone https://github.com/voxzerr/gh-multi-account.git
cd gh-multi-account
./install.sh personal work
```

Use whatever labels you like — they become folder names and command arguments:

```sh
./install.sh personal clientA clientB --projects-root ~/code
```

Then sign in to each account (this is the only part that needs a human — it
opens a browser per account):

```sh
ghma-setup
```

That generates a separate SSH key per account, uploads each to the right
account, and sets each one's commit identity from the GitHub API.

### What it touches

Deliberately very little, and it backs up anything it edits:

- **one** `include` line added to `~/.gitconfig`
- **one** marked block added to `~/.ssh/config`
- everything else under `~/.config/gh-multi-account/`
- commands in `~/.local/bin/`

`./uninstall.sh` reverses it. `--purge` also removes keys and logins.

> If you already have a global `user.email`, the installer comments it out and
> tells you — a global identity silently overrides per-account ones, which
> would defeat the whole thing.

---

## Using it

```sh
git whoami                       # which account is this repo? what will I commit as?
git whoami --check               # ...and test the live SSH connection per account

gh-clone personal owner/repo     # clone into ~/Projects/personal, wired correctly
gh-clone work owner/repo

gha work pr create               # run gh as a specific account
gha auto pr create               # ...or let it pick from the current repo
gha accounts                     # who is logged in where
gh-work pr list                  # shorthand, generated per account
```

**Starting something new?** Create it under `~/Projects/<account>/` and the
identity is right from the first commit, before any remote exists.

**Already cloned a repo the normal way?** Point it at an account:

```sh
git remote set-url origin git@github.com-work:acme/api.git
git whoami   # confirm
```

### Optional: make plain `gh` route itself

```sh
./install.sh personal work --shadow-gh
```

This puts a `gh` shim earlier on your PATH that picks the account from the
current repo, so plain `gh pr create` does the right thing. It's off by default
because shadowing a binary you didn't install is a surprising thing to do
silently. The real `gh` is still used underneath.

---

## Checking on it

```sh
ghma-doctor            # check everything and say what's wrong
ghma-doctor --offline  # skip the network checks
```

Worth running after a macOS or git upgrade, or if anything looks odd. The most
useful thing it catches is a deleted SSH key — see *Things that will eventually
happen* below.

---

## The safety nets

Each layer catches something the others can't, and all of them fail loudly.

1. **No global identity + `user.useConfigOnly`** — a repo matching no account
   can't commit at all. Catches a *missing* identity.
2. **Unqualified URLs are rewritten to a hostname that doesn't resolve** —
   `git@github.com:...` fails instead of authenticating as whichever key ssh
   offers first. Catches an *ambiguous remote*.
3. **The credential helper is switched off** — see below. Catches a *shared
   HTTPS credential*.
4. **Commit-time hooks** compare the identity git would actually use against
   the account the repo resolves to. Catches a *wrong but present* identity —
   a repo-local `user.email`, or a `GIT_AUTHOR_EMAIL` env var, pointing at the
   other account. Layers 1–3 all miss this.
5. **A pre-push guard** re-checks every commit being pushed, author *and*
   committer. This is the backstop for commits that never saw a commit hook.
6. **`gha` refuses to guess**, and refuses to run at all if `GH_TOKEN` /
   `GITHUB_TOKEN` is set, since an environment token silently outranks the
   per-account config.
7. **Repos with remotes for two different accounts are refused** rather than
   resolved by config ordering, which is arbitrary.

### Which git commands are actually checked

This matters more than it sounds, and it is the reason the push guard exists.
Git does not run `pre-commit` for everything that creates a commit:

| Command | What protects it |
|---|---|
| `git commit`, `git commit --amend` | `pre-commit` — blocked before it happens |
| `git merge --no-ff` | `pre-merge-commit` — blocked before it happens |
| `git cherry-pick`, `git revert`, `git rebase` | **no pre-hook exists.** `post-commit` warns immediately; `pre-push` blocks |

So a cherry-picked commit under the wrong account *can* be created — you get an
immediate warning, and it cannot leave your machine. All of this is covered by
the test suite.

Bypass deliberately with `--no-verify` (works on commit, merge and push).

Repos that set `core.hooksPath` themselves — husky, the `pre-commit` framework
— override the global hooks and lose layers 4 and 5. They keep working; they
are just unprotected. Your own repo hooks still run: the global hooks chain to
them.

---

## Things that will eventually happen

Not bugs, just facts worth knowing before they confuse you at 2am.

**GitHub deletes SSH keys unused for 12 months.** If one account goes dormant
for a year, its key is deleted and pushes start failing with
`Permission denied (publickey)` — which reads like a local SSH problem, not an
account event. `ghma-doctor` checks for this explicitly. To fix:
`gha <account> ssh-key add ~/.ssh/id_ed25519_github_<account>.pub --title '<account>'`

**Revoking gh's authorization on GitHub deletes the SSH key it uploaded.** So
"tidying up authorized OAuth apps" breaks git, not just the CLI. Same fix.

**Joining an org with SAML/SSO** requires authorizing each SSH key for that org
through the browser. There is no CLI path for it.

**GitHub host key rotation** would show as
`WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!` for every account at once.
It has happened once, in March 2023. Re-run the installer to re-pin.

---

## Design notes

Some of these are non-obvious and were arrived at by testing, not by reading
docs — worth knowing if you're modifying this.

**`hasconfig:remote.*.url` globs are fussy.** `*` does not match across `/`,
and `**` is only special as a *complete path component*. So
`git@github.com-work:**` matches **nothing at all** — silently. The working
form is `git@github.com-work:*/**`, plus a separate rule for `ssh://` URLs.

**`IdentitiesOnly yes` is required.** Without it, ssh offers every key in the
agent in turn and GitHub authenticates you as whichever one matches first —
which may be the wrong account.

**The macOS keychain credential helper is a shared slot.** Xcode's command line
tools enable `credential.helper=osxkeychain` system-wide, and it keys on
hostname only, so a saved password for one account is handed to the other with
no prompt. This is the classic silent multi-account failure. The generated
config resets the helper list; auth goes over SSH.

**HTTPS is blocked asymmetrically.** `pushInsteadOf`, not `insteadOf` — cloning
and fetching public repos over HTTPS keeps working, and only *pushing* to an
unqualified HTTPS URL is blocked, since that's the direction that can write to
the wrong account.

**Don't use `git rev-parse --git-path hooks/pre-commit` in a global hook.**
`--git-path` honours `core.hooksPath`, so it resolves to the global hook
itself, and `exec`-ing it recurses forever and hangs every commit. Use
`--absolute-git-dir` and append `hooks/`.

**gh tokens are stored as files, not in the keychain.** gh names its keychain
entry per *host* (`gh:github.com`), not per config directory, so accounts
would share one slot, distinguished by an account field that
[cli/cli#12885](https://github.com/cli/cli/issues/12885) reports as unreliable.
Logging in with `--insecure-storage` gives each account its own token file at
mode 600, making the separation a filesystem fact. The trade-off is a token in
plaintext on disk — the same exposure your (passphrase-less) SSH keys already
have. Drop the flag in `bin/ghma-setup` if you'd rather have the keychain.

**Two separate SSH keys are mandatory**, not stylistic — GitHub rejects the
same public key on a second account.

---

**Symlinked paths are handled, but only because they were caught.** `git
rev-parse` reports physical paths and git resolves symlinks when matching
`gitdir:`, so a projects root reached through a symlink (a symlinked `/home`,
an external volume, `/tmp` on macOS) would compare unequal as a plain string
and make every repo look unaffiliated. Paths are normalised on both sides.

---

## Development

```sh
tests/run-tests.sh              # 29 tests, ~30s
KEEP_SANDBOX=1 tests/run-tests.sh   # keep the sandbox to poke at
```

Everything runs in a throwaway `HOME` and stubs `gh`, so no network, no GitHub
account, and your real setup is never touched. `install.sh` and `uninstall.sh`
are exercised by the suite rather than mocked. CI additionally runs shellcheck
and asserts the installer *refuses* git older than 2.36.

---

## Limitations

- `gh repo clone` writes an account-less remote and will therefore fail. Use
  `gh-clone` instead.
- SSH keys are generated without a passphrase. Add one with
  `ssh-keygen -p -f ~/.ssh/id_ed25519_github_<account>`; `UseKeychain` is
  already configured so you'd only be asked once.
- Only tested against github.com. GitHub Enterprise Cloud needs more than a
  hostname change — GHE.com uses the enterprise subdomain as the SSH *username*
  instead of `git`, which the host alias blocks assume.
- GUIs that reimplement git's config parsing rather than shelling out to it —
  libgit2-based tools such as TortoiseGit — don't support `hasconfig`, so they
  can miss the remote-URL rule. Tools that shell out to `git` (VS Code's built-in
  git, Git Credential Manager) are fine.
- Cherry-pick and revert can create a wrong-account commit locally before you
  are told. It cannot be pushed. See the coverage table above.

## License

MIT
