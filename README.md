# Swapkin

Switch between several accounts, for several tools, from the Omarchy bar,
without re-logging in and without losing your sessions.

Swapkin now covers Claude Code, Codex CLI, and Copilot CLI (via `gh`). Each
provider switches its own way — some pick up the new account on their very
next message, others only for a session you start after the switch — see
[How switching works](#how-switching-works) below.

One shared config directory stays where it is. A switch swaps the login inside
it, so settings, sessions, skills, hooks and MCP logins are untouched.

![The Swapkin panel in the Omarchy bar](docs/panel.png)

## What it does

- **A wide popover with two columns.** Providers on the left, the one you picked
  on the right, and a "next message is paid by" strip on top. On a screen tall
  enough it never scrolls; on a shorter one the columns scroll inside it.
- **Switch accounts from the bar.** Every account is a card. Move over one to
  preview its limits, then switch. Keys: `↑` `↓` provider, `←` `→` account,
  `a` switch, `m` manage, `r` refresh.
- **Each account keeps its own colour**, shown in the bar icon, the account list
  and, if you want it, the Claude Code status line.
- **Limits for every account**, not only the active one: session window, weekly
  window and any model-specific window the plan has.
- **Pace, not just a percentage.** `13% used · budget 20% · 7% under pace`,
  `At this rate: about 64% at reset`, and the reset time. The budget grows only
  during the days and hours you work (see below).
- **A watchdog while the panel is closed.** It warns once when the active
  account passes your threshold. Hand-over when an account is spent is opt-in.
- **Today's tokens at API prices**, as an estimate you can sanity-check.

## Requirements

- Omarchy with the shell plugin system (`omarchy plugin --help` works)
- `jq` and `notify-send` for the warnings
- Whichever tools you actually switch: `claude` (Claude Code), `codex`
  (Codex CLI), `gh` with the Copilot CLI extension, or your own

## Install

```bash
omarchy plugin add https://github.com/viniciosrab/omarchy-swapkin --enable
```

Once the shell loads the plugin, `swapkin` is on your PATH: the service links
`~/.local/bin/swapkin` to the installed plugin (run `swapkin link` by hand from
the plugin's `bin/` if that folder isn't on your PATH). Only a missing entry or
a dangling link left by a removed plugin is (re)pointed; a regular file, a link
to another program or a live link to another swapkin copy is never replaced.

The widget replaces Omarchy's built-in Agents widget in the bar. To go back:

```bash
omarchy plugin remove io.github.viniciosrab.swapkin
```

## First run

Open the panel, press **manage**, then **+ add account**.

The first account is whoever is signed in right now — nothing to type. Every
account after that opens Claude Code in a throwaway config folder; run `/login`
and Swapkin saves the account and closes the window by itself. Your usual config
is never touched by that sign-in.

From a terminal, the same thing:

```bash
swapkin add work        # or just: swapkin add
swapkin use personal
swapkin list
```

## How switching works

Pick a provider with `swapkin -p <id> ...` (`claude` if you leave it out).
Each one switches a different way:

- **Claude Code — next message.** Claude Code keeps its login in
  `.credentials.json` and the account profile in `.claude.json`. Swapkin swaps
  only the account's own keys there and re-reads the file when its
  modification time changes, so a running session picks the new account up on
  its next request. Connectors may keep the old account until that session is
  restarted.

  | Swapped with the account | Left alone |
  | --- | --- |
  | `claudeAiOauth` in `.credentials.json` | `mcpOAuth` (Slack, Figma, …) |
  | The account keys in `.claude.json`: profile, user id, model access, org defaults, extra-usage state | Projects, history, onboarding, machine ids, settings, skills, hooks |

- **Codex CLI — new sessions.** Switching writes the account's saved login
  into `~/.codex/auth.json` (or `$CODEX_HOME/auth.json`), which a plain
  `codex`, `codex login status` and bar usage monitors all read, so they use
  the new account right away. A Codex session already running keeps the old
  account until you restart it. The switch refuses to overwrite a live login
  that isn't one of your saved accounts; save it first with `swapkin -p codex
  add <name>`. With a keyring login (no `auth.json` on disk) only the pointer
  moves; see [below](#codex-and-other-new-session-tools).
- **Copilot CLI — new sessions.** Copilot has no login file of its own; it
  rides on `gh`'s account. Switching runs `gh auth switch`, so new Copilot CLI
  sessions (and anything else that asks `gh` who's signed in, including `git
  push`) use the new account, but a Copilot CLI session already running keeps
  its token. A login made with `copilot login` directly, instead of through
  `gh`, isn't switched by Swapkin.

Every provider writes the outgoing account's live login back to its own saved
copy *before* swapping in, so a stored login is never the stale half of a
refresh-token rotation.

## Codex and other new-session tools

Codex follows a switch on its own when its login lives in `auth.json`
(the default): new sessions and bar monitors read the swapped file, and only
sessions already running need a restart. A Codex login kept in the system
keyring, or a tool of your own that reads its home from an environment
variable, only follows in a session launched with the active account's
environment:

```bash
eval "$(swapkin env)"      # add to your shell rc; sets CODEX_HOME etc. per shell
swapkin run codex           # or launch straight into the active account
```

`swapkin env [id]` prints the active account's environment as `export`
lines (no id switches every provider it knows); `swapkin run <id> [-- args]`
runs that provider's own CLI with the same environment already set. A Codex
account with its own saved `auth.json` needs nothing here, so it exports
nothing.

Upgrading from a version where Codex needed this: remove the
`eval "$(swapkin env)"` line from your shell rc if Codex was its only reason,
or at least open a new shell. An old shell may still carry a `CODEX_HOME`
that points into Swapkin's own folder; Swapkin ignores that one when it
switches, but a `codex` started from that shell would still read it.

## Your own tools

Any tool that reads its home directory from an environment variable can be
added without touching Swapkin's code. Describe it in
`~/.config/swapkin/providers.json`:

```json
{
  "providers": [
    { "id": "acme-cli", "name": "Acme CLI", "command": "acme", "mode": "cold",
      "homeEnv": "ACME_HOME", "defaultHome": "~/.acme", "loginCommand": "acme login" },

    { "id": "widget-agent", "name": "Widget Agent", "command": "widget", "mode": "cold",
      "homeEnv": "WIDGET_HOME", "defaultHome": "~/.widget" }
  ]
}
```

Both are **cold**: a separate home directory per account, so only an `acme`
or `widget` process started after `swapkin use` gets the new one. `acme-cli`
also names a `loginCommand`, which `add` runs with `ACME_HOME` pointed at the
new account's home so you can sign in.

Custom providers are cold-only. **Hot** mode — one shared login file swapped
in place, so a running session sees the new account on its next message — is
built in for Claude Code only: it overwrites a login file at a path the
config names, and that write could not be made safe against a symlink swap
in bash. A custom entry with `"mode": "hot"` or `loginFiles` is ignored with
a warning. Full contract (safety rules, `usageCommand`, sign-in flow) in
[`docs/providers.md`](docs/providers.md).

## Demo mode

`swapkin demo on` shows the panel filled with invented accounts and numbers
instead of your real ones — handy for a screenshot. `swapkin demo off` turns
it back off. Nothing it does ever reads or writes a real login.

## Commands

| Command | What it does |
| --- | --- |
| `swapkin status` | The active account and its plan |
| `swapkin list [--json]` | Saved accounts; `*` marks the active one |
| `swapkin add [name]` | Save a new account (the first is your current login) |
| `swapkin use <name>` | Switch every Claude Code session to that account |
| `swapkin colour <name> <#rrggbb>` | Set the colour that marks an account |
| `swapkin remove <name>` | Forget a saved account |
| `swapkin usage` | Refresh each account's limits |
| `swapkin check` | One watchdog pass: refresh, warn, hand over (every provider in `autoSwitchProviders`) |
| `swapkin cost` | Today's tokens priced at API rates, as JSON |
| `swapkin statusline [--plain]` | The active account, coloured, for a status line |

## Settings

Behaviour lives in `~/.local/share/swapkin/config.json`:

```json
{ "alertAt": 90, "autoSwitch": false }
```

- `alertAt` — the percentage that triggers one desktop warning per window, for
  every window in `autoSwitchWindows`.
- `autoSwitch` — off by default. Turn it on and a spent account hands over to the
  account with the most room left, with a notification saying so. Left off, you
  get the warning and decide yourself.
- `autoSwitchWindows` — which limit windows the watchdog watches, warns about and
  switches on: `"weekly"`, `"session"` (the 5-hour window), or both. Default
  `["weekly"]`. Unknown items are ignored; an empty or invalid value means the
  default.
- `autoSwitchAt` — the percentage at which a watched window counts as spent and
  the account hands over. Default `100`. A value outside 1–100 is clamped into
  it; anything that is not a number is ignored.
- `autoSwitchProviders` — which providers the watchdog watches: `"claude"`,
  `"codex"`, or both. Default `["claude"]`. Unknown items are ignored; an empty
  or invalid value means the default. Every provider listed uses the same
  `alertAt`, `autoSwitch`, `autoSwitchWindows` and `autoSwitchAt`, keeps its own
  warning state, and is handled on its own: one provider's switch never waits
  on, or depends on, another's.

With several accounts, the 5-hour session window is usually the one that runs
out first. To hand over as soon as it is nearly spent:

```json
{ "alertAt": 90, "autoSwitch": true, "autoSwitchWindows": ["weekly", "session"], "autoSwitchAt": 95 }
```

The account it hands over to must have room in every watched window; it is the
one with the most room left in its tightest window. When none has room, you get
a warning saying so and nothing switches, but every later check tries again
while the account stays spent, so the first account to free up is taken. A
switch that fails is reported once and retried the same way. Each warning names
its window and fires once per threshold until that window resets.

To let Codex hand over too:

```json
{ "alertAt": 90, "autoSwitch": true, "autoSwitchWindows": ["weekly", "session"], "autoSwitchProviders": ["claude", "codex"] }
```

Codex notices start with `Codex:`, and a few things work differently:

- **Running sessions keep their account.** The switch writes the new login into
  `~/.codex/auth.json`, so new sessions and bar monitors follow, but a Codex
  session already running keeps the previous account until you restart it. The
  notice says so. When the switch can't go in place (signed out, a keyring
  login, or an API-key login), only the pointer moves and the notice tells you
  to start new sessions with `swapkin run codex`. A switch swapkin refuses (a live
  login that belongs to none of your saved accounts, or a corrupt one) is a
  failed switch: reported once, retried on every check.
- **Figures can be old.** Codex has no usage endpoint to ask; each account's
  figures are the rate limits from its last session on this machine. An account
  nobody uses can't see its usage go up, only down when a window resets, so an
  old figure is taken as an upper bound: a watched window has room when it has
  reset since, or when its last figure, however old, is below `autoSwitchAt`.
  If the same account is in use on another machine, that bound can be wrong;
  the worst case is a switch to a spent account, and the next check hands over
  again. An account that has never run a session on this machine has no
  figures at all; it is only chosen when no account with known room exists,
  and if it turns out spent, the watchdog hands over again once a session here
  has recorded its limits. The active account is read the same way: a window
  that reset since its last session is not spent.

The watchdog interval and the weekly budget are widget settings:

```bash
omarchy bar set io.github.viniciosrab.swapkin watchIntervalMin 5 --json
```

`budgetSpread` (`Working days` or `Every day`), `budgetDays` (`Mon,Tue,Wed,Thu,Fri`),
`budgetStartHour` (9) and `budgetEndHour` (19) shape the pace curve: only those
hours earn weekly budget. With no working day picked, or an end hour that is not
after the start, the budget grows evenly all week.

`prices.json`, next to the plugin, holds the per-million-token rates used for the
"at API prices" line. They change; edit the file rather than the code.

## Where things live

```
~/.local/share/swapkin/
  active                  the account in use
  config.json             alertAt, autoSwitch, autoSwitchWindows, autoSwitchAt,
                          autoSwitchProviders
  watch.json              which warnings were already sent, per window
  providers/codex/watch.json  the same, for Codex (with autoSwitchProviders)
  <account>/oauth.json    that account's login        (0600)
  <account>/account.json  its profile keys            (0600)
  <account>/meta.json     its colour
  <account>/usage.json    its last good limits
```

Logins are readable only by you. They never leave the machine: Swapkin talks to
the same Anthropic usage endpoint Claude Code already uses, one account at a
time, from that account's own saved login.

## Status line

Claude Code's status line is yours, so Swapkin does not touch it. It does print
a ready-made segment — the active account, in that account's colour:

```bash
swapkin statusline            # coloured, for a terminal
swapkin statusline --plain    # just @work
```

Add it to the script behind `statusLine` in your Claude Code settings:

```bash
printf '\n'; swapkin statusline
```

A line of its own survives a narrow or split pane, where a long first line is
cut off.

## Limitations

- Claude Code, Codex CLI and Copilot CLI ship built in; anything else with the
  same shape of login is a `providers.json` entry away.
- Token history is machine-wide, not per account — the session files do not
  record which account paid for them. Limits *are* per account.
- An idle account's figures are only as fresh as its login: when its token
  expires, the panel keeps the last good numbers and says how old they are.
- Switching touches undocumented internals of Claude Code's config. It has
  worked since day one here, but a future release could move things.

## Licence

MIT. Parts of the panel are derived from Omarchy's built-in agents plugin,
also MIT. Claude and Claude Code are trademarks of Anthropic; this is an
independent project and is not affiliated with or endorsed by Anthropic.
