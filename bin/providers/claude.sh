# shellcheck shell=bash
# shellcheck disable=SC2034  # P_* vars are read by the engine after sourcing this file
# Claude Code adapter. Moved out of the old single-provider bin/swapkin
# unchanged: behaviour, storage layout ($ACCOUNTS/<name>/, $ACCOUNTS/active)
# and every helper here are byte-for-byte what shipped before providers existed.
#
# Settings, sessions, skills, hooks and MCP logins stay where they are. A switch
# only swaps the Claude login (claudeAiOauth in .credentials.json) and the account
# profile (oauthAccount in .claude.json). Running sessions notice the new login on
# their next request, because Claude Code re-reads the file when its mtime changes.

P_ID=claude
P_NAME="Claude Code"
P_MODE=hot
P_CMD=claude
P_MARKER=oauth.json
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
P_STORE="$CONFIG_DIR/.credentials.json"
P_HOW="Switching updates the shared Claude Code login; open sessions notice it on their next request."
P_ADD_HINT="The first account is whatever is already signed in."

CREDS="$CONFIG_DIR/.credentials.json"
# Claude Code keeps .claude.json in $HOME unless CLAUDE_CONFIG_DIR moves it.
if [[ -n ${CLAUDE_CONFIG_DIR:-} ]]; then STATE="$CONFIG_DIR/.claude.json"; else STATE="$HOME/.claude.json"; fi

# A floating terminal starts from a bare environment, so a CLI installed by a
# version manager (mise, asdf, nvm, volta) is not on PATH yet. Find it anyway.
claude_bin() {
  local candidate
  if candidate=$(command -v claude 2>/dev/null); then echo "$candidate"; return; fi
  for candidate in "$HOME/.local/share/mise/shims/claude" "$HOME/.local/bin/claude" \
                   "$HOME/.claude/local/claude" "$HOME/.asdf/shims/claude" \
                   "$HOME/.volta/bin/claude" "/usr/local/bin/claude" "/usr/bin/claude"; do
    [[ -x $candidate ]] && { echo "$candidate"; return; }
  done
  candidate=$(bash -lc 'command -v claude' 2>/dev/null || true)
  [[ -n $candidate ]] && echo "$candidate"
}

p_installed() { [[ -n $(claude_bin) ]]; }
p_sessions() { pgrep -x claude 2>/dev/null | wc -l; }

ICONS="$PROVIDERS_DIR/../../icons"

# What .claude.json keys belong to the account rather than to this machine.
# They carry the plan: which models it may use, its org defaults, its extra-usage
# state. Carried across with the login, or a Pro account keeps a Max account's
# answers until Claude Code refetches them.
ACCOUNT_KEYS='["oauthAccount","userID","modelAccessCache","orgModelDefaultCache","passesEligibilityCache","additionalModelCostsCache","additionalModelOptionsCache","additionalModelOptionsAnsweredAt","cachedExtraUsageDisabledReason","cachedUsageUtilization","groveConfigCache","penguinModeOrgEnabled","opusProMigrationComplete"]'
# Per-user experiment flags: never worth carrying, always worth dropping, since
# Claude Code refetches them for whoever is signed in.
VOLATILE_KEYS='["cachedStatsigGates","cachedExperimentData","cachedExperimentFeatures","cachedGrowthBookFeatures","cachedGrowthBookFeaturesAt","autoCompactWindowsCache"]'

# Copy a login out of a config dir into a profile.
store() { # name creds-file state-file
  local dir; dir=$(account_dir "$1")
  mkdir -p "$dir"
  jq -e '.claudeAiOauth.refreshToken' "$2" >/dev/null 2>&1 || die "no Claude login found in $2"
  jq '.claudeAiOauth' "$2" > "$dir/oauth.json.tmp"
  jq --argjson keys "$ACCOUNT_KEYS" 'with_entries(select(.key as $k | $keys | index($k)))' "$3" > "$dir/account.json.tmp"
  mv "$dir/oauth.json.tmp" "$dir/oauth.json"
  mv "$dir/account.json.tmp" "$dir/account.json"
}

# Refresh tokens rotate, so the live login goes back to its profile before every switch.
p_save() {
  local name; name=$(active)
  [[ -n $name ]] || die "no active account yet; run: swapkin add <name>"
  store "$name" "$CREDS" "$STATE"
}

# A profile has to hold something that can actually be a login. Anything shorter
# is test data or a half-written file, and switching to it logs the machine out.
plausible_login() { # account
  local length dir; dir=$(account_dir "$1")
  length=$(jq -r '(.refreshToken // "") | length' "$dir/oauth.json" 2>/dev/null || echo 0)
  (( length >= 40 ))
}

p_use() {
  local name="$1" dir; dir=$(account_dir "$name")
  [[ -f $dir/oauth.json ]] || die "no saved login for '$name'"
  plausible_login "$name" || die "'$name' has no usable login; sign in again with: swapkin add $name"
  [[ -n $(active) ]] && p_save
  replace "$CREDS" '.claudeAiOauth = $o[0]' --slurpfile o "$dir/oauth.json"
  # Drop the outgoing account's per-user flags, then lay the incoming account's
  # own keys on top. Everything else in .claude.json — projects, history,
  # onboarding, this machine's ids — stays exactly as it was.
  replace "$STATE" 'with_entries(select(.key as $k | $vol | index($k) | not)) * $a[0]' \
    --argjson vol "$VOLATILE_KEYS" --slurpfile a "$dir/account.json"
  set_active "$name"
  echo "Active: $name"
}

# The newest throwaway folder that already holds a finished sign-in, if any.
pending_login() {
  local newest="" dir
  for dir in "$ACCOUNTS"/.login.*/; do
    [[ -f $dir/.credentials.json ]] || continue
    [[ -z $newest || $dir -nt $newest ]] && newest="$dir"
  done
  [[ -n $newest ]] && echo "${newest%/}"
  return 0
}

# The first account is whoever is signed in now. Later ones sign in inside a
# throwaway config dir, so the shared ~/.claude is never touched by the login.
p_add() {
  local name="${1:-}"
  valid_name "$name"
  [[ -f $(account_dir "$name")/oauth.json ]] && die "'$name' already exists"

  if [[ -z $(profiles) ]]; then
    store "$name" "$CREDS" "$STATE"
    set_colour "$name" "$(next_colour "$name")"
    set_active "$name"
    echo "Saved the current login as '$name'."
    return
  fi

  # A sign-in that never reached this script still left its login on disk.
  # Offer it rather than asking the user to sign in twice.
  local pending; pending=$(pending_login || true)
  if [[ -n $pending ]]; then
    store "$name" "$pending/.credentials.json" "$pending/.claude.json"
    set_colour "$name" "$(next_colour "$name")"
    rm -rf "$pending"
    echo "Recovered the sign-in you already finished and saved it as '$name'."
    return
  fi

  # The trap fires after this function returns, so the folder it cleans up has
  # to outlive the local scope.
  LOGIN_DIR=$(mktemp -d "$ACCOUNTS/.login.XXXXXX")
  trap 'rm -rf "${LOGIN_DIR:-}"' EXIT
  local login="$LOGIN_DIR"
  # Carry the theme across so the throwaway session looks like the usual one.
  # Nothing about onboarding or login is copied: the sign-in flow must run intact.
  jq '{theme} | with_entries(select(.value != null))' "$STATE" > "$login/.claude.json"
  cat <<EOF
Claude Code opens in a throwaway config folder. Sign in with:

  /login

That is the whole job. This window closes by itself once the account is saved.
Your usual config, your sessions and your open Claude Code windows are untouched.

EOF

  local cli; cli=$(claude_bin)
  [[ -n $cli ]] || fail "cannot find the claude command. Open a terminal where 'claude' works and run: swapkin add $name"

  # Watch for the sign-in instead of asking the user to quit Claude Code: the
  # credentials file appears the moment /login succeeds. Saving it right then
  # also beats the throwaway session to its first token refresh, which would
  # rotate the token this profile just stored.
  CLAUDE_CONFIG_DIR="$login" "$cli" &
  local claude_pid=$!
  local waited=0
  while (( waited < 900 )); do
    if [[ -f $login/.credentials.json ]] && jq -e '.claudeAiOauth.refreshToken' "$login/.credentials.json" >/dev/null 2>&1; then
      sleep 1   # let Claude Code finish writing the account profile too
      store "$name" "$login/.credentials.json" "$login/.claude.json"
      set_colour "$name" "$(next_colour "$name")"
      kill "$claude_pid" 2>/dev/null || true
      wait "$claude_pid" 2>/dev/null || true
      echo
      echo "Saved '$name'. Pick it from the bar, or run: swapkin use $name"
      sleep 2
      return
    fi
    kill -0 "$claude_pid" 2>/dev/null || break
    sleep 1
    waited=$((waited + 1))
  done

  wait "$claude_pid" 2>/dev/null || true
  fail "no sign-in found, so nothing was saved. Run /login inside Claude Code."
}

# One account's limits, from its own saved login and its own cache, so several
# accounts can be probed at once without mixing anything up.
p_probe() { # account
  local dir; dir=$(account_dir "$1")
  mkdir -p "$dir/shadow" "$dir/cache"
  jq '{claudeAiOauth: .}' "$dir/oauth.json" > "$dir/shadow/.credentials.json"
  local record
  record=$(CLAUDE_CONFIG_DIR="$dir/shadow" XDG_CACHE_HOME="$dir/cache" \
    timeout 20 omarchy-agent-usage-claude --limits-only --force 2>/dev/null) || return 0
  jq -e '(.limits // []) | length > 0' >/dev/null 2>&1 <<<"$record" || return 0
  jq -c '{limits, tierLabel, updatedAt}' <<<"$record" > "$dir/usage.json.tmp"
  mv "$dir/usage.json.tmp" "$dir/usage.json"
}

p_plan() { jq -r '.subscriptionType // empty' "$(account_dir "$1")/oauth.json" 2>/dev/null; }

CONFIG="$ACCOUNTS/config.json"
STATE_FILE="$ACCOUNTS/watch.json"

setting() { # key default
  jq -r --arg k "$1" --arg d "$2" '.[$k] // $d' "$CONFIG" 2>/dev/null || echo "$2"
}

# Same two-circle mark the panel draws for this account: a solid disc in its
# colour overlapped by an outline ring. One icon per palette colour ships with
# the plugin, so nothing is written to disk to show a notification. A colour
# outside the palette gets the neutral mark.
icon_for() { # account
  local colour="" c
  [[ ${1:-} =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] && colour=$(colour_of "$1")
  colour=${colour,,}
  for c in "${PALETTE[@]}"; do
    [[ $c == "$colour" ]] && { echo "$ICONS/account-${c#\#}.svg"; return; }
  done
  echo "$ICONS/account-default.svg"
}

notify() { # title body account
  command -v notify-send >/dev/null || return 0
  notify-send --app-name=Swapkin --icon="$(icon_for "${3:-}")" "$1" "$2" || true
}

# The label pattern of each window the watchdog can act on. The usage
# collector (omarchy-agent-usage-claude) titles the account-wide windows
# "Session (5-hour)" and "Weekly (7-day)" and lists them before any
# model-scoped ones ("<model> Session", "<model> Weekly"), so the first match
# is always the account-wide window. "5-hour", "five hour" and a bare "5h"
# count as the session too, which is how other tools word the same window.
window_re() { # weekly|session
  case $1 in
    weekly) echo 'week' ;;
    session) echo 'session|5-hour|five.hour|\b5h\b' ;;
  esac
}

window_field() { # account window field default
  jq -r --arg re "$(window_re "$2")" --arg f "$3" --arg d "$4" \
    '[.limits[]? | select((.label // "") | ascii_downcase | test($re))][0][$f] // $d' \
    "$(account_dir "$1")/usage.json" 2>/dev/null || echo "$4"
}

window_pct() { window_field "$1" "$2" percent -1; } # account window

# Whether a usage fraction (0-1) has reached a percentage. The tiny margin keeps
# float noise (0.29 * 100 = 28.999...) from missing an exact hit.
reached() { awk -v p="$1" -v t="$2" 'BEGIN{exit !(p * 100 + 1e-9 >= t)}'; } # fraction percent

# The windows the watchdog watches and acts on, from autoSwitchWindows: any of
# "weekly" and "session", always in that order. Unknown items are dropped, and
# an empty list, or anything that is not a list, means the default: the weekly
# window alone.
switch_windows() {
  local list
  list=$(setting autoSwitchWindows '["weekly"]' \
    | jq -r '[.[] | strings] as $w | ["weekly", "session"] | map(select(. as $k | $w | any(.[]; . == $k))) | join(" ")' 2>/dev/null || true)
  echo "${list:-weekly}"
}

# The percentage at which a window counts as spent and the watchdog hands over.
# Anything that is not a number is ignored (the default, 100); a number outside
# 1-100 is clamped into it.
switch_at() {
  local raw; raw=$(setting autoSwitchAt 100)
  [[ $raw =~ ^-?[0-9]+([.][0-9]+)?$ ]] || raw=100
  awk -v v="$raw" 'BEGIN{ if (v < 1) v = 1; if (v > 100) v = 100; print v + 0 }'
}

# A window's reset, reduced to a key that stays put for the whole window: the
# endpoint restamps resetsAt on every fetch, so the full value would read as a
# new window on each check() run and re-notify every time. The week keeps its
# date, the key watch.json has always used. A session resets several times a
# day on a whole minute, restamped with sub-second jitter either side, so its
# key is the reset rounded to the nearest minute (UTC). An idle account has no
# session reset yet; "none" holds that place, and since each window keeps only
# its current reset, the first real reset replaces it.
reset_key() { # account window
  local raw secs=""; raw=$(window_field "$1" "$2" resetsAt "")
  case $2 in
    weekly) printf '%s' "${raw:0:10}" ;;
    session)
      [[ -n $raw ]] && secs=$(date -u -d "$raw" +%s.%N 2>/dev/null) || true
      [[ -n $secs ]] || { echo none; return; }
      date -u -d "@$(awk -v t="$secs" 'BEGIN{printf "%d", int((t + 30) / 60) * 60}')" +%Y-%m-%dT%H:%M ;;
  esac
}

# The stage last notified for one window of one account in that window's reset:
# 1 warned at alertAt, 2 warned at autoSwitchAt, 3 also told that the automatic
# switch failed. watch.json holds
# {account: {weekly: {reset: stage}, session: {reset: stage}}}.
# Before the session window existed it held {account: {reset: stage}} for the
# week alone, so a weekly stage still falls back to that shape.
last_stage() { # account window reset-key
  jq -r --arg a "$1" --arg w "$2" --arg r "$3" '
    (if type == "object" then .[$a] else null end) as $s
    | (if ($s | type) != "object" then null
       else ($s[$w] | if type == "object" then .[$r] else null end)
            // (if $w == "weekly" then $s[$r] else null end) end)
    | if type == "number" then floor else 0 end' "$STATE_FILE" 2>/dev/null || echo 0
}

# The tightest of the given windows for an account: its highest usage, or -1
# when none of them has a figure. A window missing from figures that do exist
# counts as untouched, since an idle account's session may simply not be listed.
tightest_of() { # account windows...
  local name=$1 w pct tight=-1; shift
  for w in "$@"; do
    pct=$(window_pct "$name" "$w")
    awk -v p="$pct" 'BEGIN{exit !(p >= 0)}' || continue
    awk -v p="$pct" -v t="$tight" 'BEGIN{exit !(p > t)}' && tight=$pct
  done
  echo "$tight"
}

# The account with the most room left in its tightest watched window, ignoring
# the one passed in. An account that already reached the switch threshold in any
# watched window has no room. With the weekly window alone this is the old
# weekly ranking.
roomiest() { # account-to-ignore switch-at windows...
  local ignore=$1 at=$2; shift 2
  local best="" best_pct=2 name pct
  for name in $(profiles); do
    [[ $name == "$ignore" ]] && continue
    pct=$(tightest_of "$name" "$@")
    awk -v p="$pct" 'BEGIN{exit !(p >= 0)}' || continue
    reached "$pct" "$at" && continue
    if awk -v p="$pct" -v b="$best_pct" 'BEGIN{exit !(p < b)}'; then
      best="$name"
      best_pct="$pct"
    fi
  done
  echo "$best"
}

# How a notification names each window.
window_span() { case $1 in weekly) echo "its week" ;; session) echo "its 5-hour window" ;; esac; }
window_spent() { case $1 in weekly) echo "ran out of weekly quota" ;; session) echo "hit its 5-hour limit" ;; esac; }

# One pass of the watchdog: refresh the figures, warn once per threshold per
# window, and hand over to another account when this one is spent. `check` is
# Claude-only, always run through this entry point regardless of -p.
claude_check() {
  cmd_usage
  local cur; cur=$(active)
  [[ -n $cur ]] || return 0

  local warn_at; warn_at=$(setting alertAt 90)
  # Off by default: taking over an account is the user's call, not the plugin's.
  local auto_switch; auto_switch=$(setting autoSwitch false)
  local at; at=$(switch_at)
  local windows; read -ra windows <<<"$(switch_windows)"

  # Each watched window climbs its own stages, 1 at alertAt and 2 at
  # autoSwitchAt, and each stage is notified once per reset of that window.
  local w pct key last stage update='{}'
  local news=() news_pct=() spent=() spent_key=() spent_last=()
  for w in "${windows[@]}"; do
    pct=$(window_pct "$cur" "$w")
    awk -v p="$pct" 'BEGIN{exit !(p >= 0)}' || continue
    key=$(reset_key "$cur" "$w")
    last=$(last_stage "$cur" "$w" "$key")
    stage=0
    reached "$pct" "$warn_at" && stage=1
    reached "$pct" "$at" && stage=2
    if (( stage == 2 )); then
      spent+=("$w")
      spent_key+=("$key")
      spent_last+=("$last")
    fi
    (( stage > last )) || continue
    news+=("$w")
    news_pct+=("$pct")
    update=$(jq -c --arg w "$w" --arg k "$key" --argjson s "$stage" '. + {($w): {($k): $s}}' <<<"$update")
  done
  # A spent account keeps trying to hand over on every check, so a candidate
  # that frees up later is still taken. Warnings stay once per stage per reset.
  local handover=false
  (( ${#spent[@]} )) && [[ $auto_switch == true ]] && handover=true
  (( ${#news[@]} )) || [[ $handover == true ]] || return 0

  local other; other=$(roomiest "$cur" "$at" "${windows[@]}")
  # Never hand over to an account that cannot be verified: a real login, and
  # figures fresh enough to trust.
  if [[ -n $other ]]; then
    local age=$(( $(date +%s) - $(stat -c %Y "$(account_dir "$other")/usage.json" 2>/dev/null || echo 0) ))
    if ! plausible_login "$other" || (( age > 7200 )); then other=""; fi
  fi
  local switched=false failed=false
  if [[ $handover == true && -n $other ]]; then
    # Take the same lock a `use` from the panel would, so the watchdog's
    # auto-switch can't race a concurrent switch and mix logins.
    # SWAPKIN_LOCK_WAIT (seconds, default 10) bounds the wait for it.
    local lock_wait=${SWAPKIN_LOCK_WAIT:-10} rc=0 had_e=0
    [[ $lock_wait =~ ^[0-9]+$ ]] || lock_wait=10
    # errexit has to stay on inside the subshell, so a failing step stops
    # p_use, but off around it, so a blocked or failed switch is handled here
    # instead of ending the run. An `if ( ... )` would not do: bash ignores
    # errexit for everything inside a condition, set -e included. So it is
    # switched off around the subshell alone and put back as it was.
    [[ $- == *e* ]] && had_e=1
    set +e
    ( set -e; exec 9>"$ACCOUNTS/.lock"; flock -w "$lock_wait" 9 || exit 75; p_use "$other" >/dev/null )
    rc=$?
    (( had_e )) && set -e
    case $rc in
      0) switched=true ;;
      75) echo "swapkin: another switch holds the lock; handing over to $other on the next check" >&2 ;;
      *) failed=true
         echo "swapkin: handing over to $other failed; the next check tries again" >&2 ;;
    esac
  fi

  if [[ $switched == true ]]; then
    local reason="" i
    for i in "${!spent[@]}"; do
      (( i )) && reason+=" and "
      reason+=$(window_spent "${spent[$i]}")
    done
    notify "Switched to $other" "$cur $reason. Open sessions follow on their next message." "$other"
  else
    # A switch that did not happen still owes the warnings due, and a spent
    # account keeps retrying on later checks whatever stage is saved.
    local i pretty free=""
    [[ -n $other ]] && free=$(awk -v p="$(tightest_of "$other" "${windows[@]}")" 'BEGIN{printf "%d", (1 - p) * 100}')
    for i in "${!news[@]}"; do
      pretty=$(awk -v p="${news_pct[$i]}" 'BEGIN{printf "%d", p * 100}')
      if [[ -n $other ]]; then
        notify "$cur is at ${pretty}% of $(window_span "${news[$i]}")" "$other has ${free}% free. Switch from the bar, or press a in the panel." "$cur"
      else
        notify "$cur is at ${pretty}% of $(window_span "${news[$i]}")" "No other account has room right now." "$cur"
      fi
    done
    # A failed switch is told once per reset of the spent windows (stage 3).
    if [[ $failed == true ]]; then
      local told=false
      for i in "${!spent[@]}"; do
        (( spent_last[i] < 3 )) || continue
        told=true
        update=$(jq -c --arg w "${spent[$i]}" --arg k "${spent_key[$i]}" '. + {($w): {($k): 3}}' <<<"$update")
      done
      [[ $told == true ]] && notify "Could not switch to $other" "$cur is still active; the next check tries again. Switch from the bar, or press a in the panel." "$cur"
    fi
  fi

  # Only the windows with news, or a spent window whose switch just failed
  # (stage 3), are rewritten, each down to its current reset, so old session
  # resets never pile up. Weekly stages left in the old shape
  # stay readable through last_stage's fallback.
  if [[ $update != '{}' ]]; then
    local tmp; tmp=$(mktemp "$STATE_FILE.XXXXXX")
    jq -n --arg a "$cur" --argjson u "$update" --slurpfile old <(cat "$STATE_FILE" 2>/dev/null || echo '{}') '
      ($old[0] | if type == "object" then . else {} end)
      | .[$a] = ((.[$a] | if type == "object" then . else {} end) + $u)' > "$tmp"
    mv "$tmp" "$STATE_FILE"
  fi
  # A failed switch still fails the run, for the service log.
  [[ $failed == false ]] || return 1
}

RECORD="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/agents/usage/claude.json"
PRICES="$PROVIDERS_DIR/../../prices.json"

# What today's tokens would have cost on the API. The collector reports today's
# tokens per model but not how they split between input, output and cache, so the
# split is taken from that model's all-time mix. An estimate, and labelled as one.
p_cost() {
  [[ -f $RECORD && -f $PRICES ]] || { echo '{"today":null}'; return; }
  jq -c --slurpfile prices "$PRICES" '
    ($prices[0].models // {}) as $rates
    | def rate($model): ($rates | to_entries | map(select(.key as $k | $model | startswith($k)))[0].value // null);
      (.modelUsage // {}) as $mix
    | [ (.todayTokensByModel // {}) | to_entries[]
        | . as $day
        | (rate($day.key)) as $r
        | ($mix[$day.key] // {}) as $m
        | (($m.inputTokens // 0) + ($m.outputTokens // 0)
           + ($m.cacheReadInputTokens // 0) + ($m.cacheCreationInputTokens // 0)) as $total
        | select($r != null and $total > 0)
        | ($day.value / $total) as $scale
        | ((($m.inputTokens // 0) * $scale * $r.input
            + ($m.outputTokens // 0) * $scale * $r.output
            + ($m.cacheReadInputTokens // 0) * $scale * $r.cacheRead
            + ($m.cacheCreationInputTokens // 0) * $scale * $r.cacheWrite) / 1000000) ]
      | add // 0
      | { today: (. * 100 | round / 100) }' "$RECORD"
}

# A ready-made segment for Claude Code's status line: the active account in its
# own colour. Print it from your status line command.
p_statusline() {
  local name; name=$(active)
  [[ -n $name ]] || return 0
  local colour; colour=$(colour_of "$name")
  [[ $colour =~ ^#[0-9a-fA-F]{6}$ ]] || colour="#d97757"
  if [[ ${1:-} == --plain ]]; then
    printf '@%s' "$name"
    return
  fi
  printf '\033[38;2;%d;%d;%dm@%s\033[0m' \
    "$((16#${colour:1:2}))" "$((16#${colour:3:2}))" "$((16#${colour:5:2}))" "$name"
}

p_status() {
  local name; name=$(active)
  [[ -n $name ]] || { echo "No accounts yet. Run: swapkin add <name>"; return; }
  printf '%s · %s\n' "$name" "$(jq -r '.claudeAiOauth.subscriptionType // "?"' "$CREDS")"
}
