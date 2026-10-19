# codex-switch

**Switch between multiple Codex (ChatGPT) accounts on one machine — no logout, no re-login, and no lost local chats.**

The OpenAI Codex CLI keeps your active login in `auth.json` inside its home folder (`$CODEX_HOME`, by default `~/.codex`). `codex-switch` stores one saved copy of each account's login and swaps the selected one into place:

```bash
codex-switch next     # toggle to the other account, then just start codex again
```

Every account keeps using the **same** Codex home folder, so all accounts automatically share the same local workspace: sessions, thread history, prompt history and `config.toml`. `codex resume` shows chats from *every* account, and nothing is moved to the cloud.

## Quick start

```bash
codex-switch import account1    # save the account you are already logged in with
codex-switch login  account2    # browser sign-in for your second account
codex-switch limits             # see how much of each account's quota is left
codex-switch next               # switch between them whenever you like
```

## How it works

```
$CODEX_HOME  (default: ~/.codex)
├── auth.json               <- live login used by codex (managed by codex-switch)
└── accounts/
    ├── account1.json       <- saved login snapshot: account1
    ├── account2.json       <- saved login snapshot: account2
    └── .active             <- name of the snapshot currently in auth.json
```

A switch does three things:

1. Saves the **latest** `auth.json` back into the current account's snapshot
   (ChatGPT rotates refresh tokens, so snapshots must be kept fresh — this is what
   makes switching back reliable).
2. Copies the target account's snapshot into `auth.json`.
3. If the Codex app-server daemon (Codex Desktop app / IDE extension backend) is
   running, offers to restart it so those clients pick up the new account too.

Because all accounts use the same `$CODEX_HOME`, your projects, sessions and
chats are shared automatically. Only the login changes.

## Requirements

- [OpenAI Codex CLI](https://github.com/openai/codex) installed and working
  (`codex` on your `PATH`), logged in with at least one account.
- PowerShell:
  - **Windows 10/11** — built-in Windows PowerShell 5.1, nothing to install.
  - **macOS / Linux** — PowerShell 7 (`pwsh`):
    [install guide](https://learn.microsoft.com/powershell/scripting/install/installing-powershell)
    (on macOS: `brew install --cask powershell`).

## Installation

### 1. Get the files

Copy or clone this folder to a permanent location, for example:

- Windows: `%USERPROFILE%\tools\codex-switch`
- macOS / Linux: `~/tools/codex-switch`

Keep the files together — `codex-switch.ps1` plus its launcher
(`codex-switch.cmd` on Windows, `codex-switch` on macOS/Linux).

### 2. Put `codex-switch` on your PATH

**Windows (PowerShell):**

```powershell
$dir = "$env:USERPROFILE\tools\codex-switch"    # <- adjust to where you put the folder
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ([string]::IsNullOrEmpty($userPath)) { $userPath = '' }
if (($userPath -split ';') -notcontains $dir) {
    [Environment]::SetEnvironmentVariable('Path', $userPath.TrimEnd(';') + ';' + $dir, 'User')
}
```

Open a **new** terminal afterwards. (The provided `.cmd` launcher also bypasses
PowerShell execution-policy issues for you.)

**macOS / Linux:**

```bash
chmod +x ~/tools/codex-switch/codex-switch
mkdir -p ~/.local/bin
ln -sf ~/tools/codex-switch/codex-switch ~/.local/bin/codex-switch
```

Make sure `~/.local/bin` is on your `PATH` (most Linux distros do; on macOS add
`export PATH="$HOME/.local/bin:$PATH"` to `~/.zshrc` and restart the terminal).

Verify the setup:

```bash
codex-switch list
```

### 3. Save your accounts

```bash
codex-switch import account1    # capture the login you are already using
codex-switch login  account2    # opens the browser to sign in your second account
```

`account1` / `account2` are just names — use anything you like (letters, digits,
`.`, `-`, `_`). If you are not logged in yet, run `codex login` once first, or
use `codex-switch login account1`.

Done. From now on a single command switches accounts.

## Checking your remaining limits

`codex-switch limits` asks OpenAI for the live usage of **every** saved account —
not just the active one — so you can see which account has room before switching:

```
$ codex-switch limits
Reading live usage for 2 account(s) from OpenAI...

  ACCOUNT        PLAN    WINDOW REMAINING
  ----------------------------------------------------------------------------
* account1       plus    5h      86% left [#########-]  resets in 4h 47m (18:42)
                         1w      53% left [#####-----]  resets in 5d 23h (Sun 13:01)
                         1 rate-limit reset credit(s) available
  account2       plus    5h       1% left [----------]  resets in 38m (14:32)
                         1w      63% left [######----]  resets in 6d 6h (Sun 20:49)

  * = active account
```

- `5h` / `1w` are the rolling windows reported by the backend (Codex shows the
  same two bars), with the percentage **remaining** and when each one resets.
- The bar is green at 50%+ remaining, yellow below 50%, and red below 20%, so
  you can see at a glance when an account is nearly spent.
- Any "rate-limit reset credits" your plan has available are listed too.
- `n/a` for an account means its saved login has expired — refresh it with
  `codex-switch login <name>`.

How it works: the command runs a short-lived, isolated Codex app-server in a
temporary folder seeded with that account's saved login, reads
`account/rateLimits/read`, then shuts it down. **It never changes your active
account or touches your live `auth.json`**, and if OpenAI rotates the tokens
during the read, the refreshed snapshot is written back so your saved logins
stay valid. Reading takes a few seconds per account.

## Daily use

When one account hits its usage/rate limit:

```bash
codex-switch next
```

then start a new session (`codex` or `codex resume`). With two accounts it
toggles; with more it cycles through them.

If the Codex Desktop app or IDE extension is open, answer `y` to the
daemon-restart prompt so they switch too — or run `codex-switch next -y` to do
it all in one go.

## Commands

| Command | Description |
|---|---|
| `codex-switch next` | Switch to the next saved account (with 2 accounts: toggles) |
| `codex-switch use <name>` | Switch to a specific saved account |
| `codex-switch list` | Show saved accounts and which one is active (`ls`, `status`) |
| `codex-switch limits` | Show live rate-limit usage for every saved account (`usage`) |
| `codex-switch whoami` | Show the account Codex is currently logged in with |
| `codex-switch import <name>` | Save the current login as `<name>` |
| `codex-switch login <name>` | Log in a new account (browser flow) and save it as `<name>` |
| `codex-switch remove <name>` | Delete a saved account |
| `codex-switch help` | Show help |

Flags:

- `-y` / `-yes` — answer all confirmations with yes (also auto-restarts the
  app-server daemon).
- `-f` / `-force` — same as `-y`.

## Notes

- One account is active machine-wide at a time (all Codex clients read the same
  `auth.json`). Running sessions keep the account they were started with; new
  sessions pick up a switch immediately.
- Desktop app / IDE extension backend: run `codex app-server daemon restart`
  after switching (codex-switch offers to do this for you). On Codex versions
  without the daemon, simply restart the app.
- If the live login doesn't match any saved account (e.g. you logged in manually
  with `codex login`), nothing is lost: `codex-switch` saves it as an
  `untracked-<timestamp>` snapshot rather than overwriting anything, and
  `codex-switch list` re-detects the live account automatically.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `codex-switch: command not found` | Open a new terminal (PATH changes apply to new sessions), or run the launcher by full path, e.g. `& "$env:USERPROFILE\tools\codex-switch\codex-switch.cmd" list` on Windows or `~/tools/codex-switch/codex-switch list` elsewhere. |
| Windows: *"running scripts is disabled on this system"* | Use the `.cmd` launcher (it uses `-ExecutionPolicy Bypass`), or run `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` once. |
| macOS / Linux: `pwsh: command not found` | Install PowerShell 7 (see Requirements). |
| Codex Desktop still shows the old account | `codex app-server daemon restart`, or close and reopen the app. |
| Old sessions still use the old account | Restart them — already-running processes keep the account they were started with. |
| `limits` shows `n/a` for an account | That saved login has expired or was revoked. Refresh it: `codex-switch login <name>`. |
| `limits` is slow | It starts a small Codex process per account and waits on the network; a few seconds per account is normal. |
| Want to rename an account | `codex-switch remove <old>` (after switching away), then `codex-switch import <new>` or `codex-switch login <new>`. |

## Security

- `$CODEX_HOME/accounts/*.json` contain **credentials** (access + refresh
  tokens). Never commit, upload, or share them. This folder ships with a
  `.gitignore` that blocks `auth*.json` and `accounts/`.
- On macOS/Linux you can harden permissions:
  `chmod 700 ~/.codex/accounts && chmod 600 ~/.codex/accounts/*.json`.

## Uninstall

1. Delete this folder and remove it from your `PATH` (reverse the install step;
   on macOS/Linux also remove the `~/.local/bin/codex-switch` symlink).
2. Optionally delete `~/.codex/accounts` (the saved snapshots). Your active
   login in `~/.codex/auth.json` and all chats are untouched.

## Files

| File | Purpose |
|---|---|
| `codex-switch.ps1` | The switcher itself (PowerShell 5.1+ / PowerShell 7+) |
| `codex-switch.cmd` | Windows launcher |
| `codex-switch` | macOS/Linux launcher (bash wrapper around `pwsh`; also works in Git Bash) |
| `README.md` | This file |
