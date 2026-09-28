# shellcheck shell=bash
# The watchdog behind `swapkin check`, shared by every provider it can watch.
# The engine sources this file once, then runs watch_check for each watched
# provider in its own subshell, with that provider's adapter loaded. Everything
# provider-specific reaches it through the adapter:
#   - profiles, active, account_dir, p_use and p_probe (the usual contract);
#   - plausible_login <account>, when defined: a candidate must pass it;
#   - p_watch_fresh <account> <windows...>, when defined: whether a candidate's
#     figures can be trusted. Without it, usage.json must be under 2 hours old;
#   - P_WATCH_RESETS_EXPIRE=1: figures are not fetched live, so a window whose
#     reset has already passed reads as untouched (0%);
#   - p_watch_switched <from> <reason> <to>, when defined: the body of the
#     "switched" notice. Without it, open sessions follow on their next message.
# Notices from any provider but Claude are prefixed with its name.
# State (which warnings were sent) lives in that provider's own watch.json.

CONFIG="$ACCOUNTS/config.json"
ICONS="$REPO_ROOT/icons"

setting() { # key default
  jq -r --arg k "$1" --arg d "$2" '.[$k] // $d' "$CONFIG" 2>/dev/null || echo "$2"
}

# The providers the watchdog checks, from autoSwitchProviders: any of "claude"
# and "codex", always in that order. Unknown items are dropped, and an empty
# list, or anything that is not a list, means the default: Claude alone.
watch_providers() {
  local list
  list=$(setting autoSwitchProviders '["claude"]' \
    | jq -r '[.[] | strings] as $p | ["claude", "codex"] | map(select(. as $k | $p | any(.[]; . == $k))) | join(" ")' 2>/dev/null || true)
  echo "${list:-claude}"
}

# One watchdog pass over every watched provider. Each runs in its own subshell,
# so one adapter's functions never leak into the next, and a failure in one
# never skips another. errexit stays on inside each (a failing step stops that
# provider's pass) but off around it, so the loop goes on; any failure still
# fails the run, for the service log.
watch_all() {
  local id rc=0 had_e=0
  [[ $- == *e* ]] && had_e=1
  for id in $(watch_providers); do
    set +e
    ( set -e; load_adapter "$id"; watch_check )
    (( $? == 0 )) || rc=1
    (( had_e )) && set -e
  done
  return "$rc"
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
  notify-send --app-name=Swapkin --icon="$(icon_for "${3:-}")" "$(watch_title "$1")" "$2" || true
}

# Claude's titles stay as they always were; any other provider's name leads
# its own, so "Codex: work is at 95% of its 5-hour window" can't be mistaken
# for a Claude account of the same name.
watch_title() { # title
  if [[ $P_ID == claude ]]; then printf '%s' "$1"; else printf '%s: %s' "$P_NAME" "${1,}"; fi
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

# Whether a window's reset, as usage.json has it, is already in the past.
window_reset_passed() { # account window
  local raw secs; raw=$(window_field "$1" "$2" resetsAt "")
  [[ -n $raw ]] || return 1
  secs=$(date -u -d "$raw" +%s 2>/dev/null) || return 1
  (( secs <= $(date +%s) ))
}

# A window's usage (0-1), or -1 when there is no figure for it. When figures
# are not fetched live (P_WATCH_RESETS_EXPIRE), a window that reset since they
# were taken has started over, so it reads as 0.
window_pct() { # account window
  if [[ ${P_WATCH_RESETS_EXPIRE:-0} == 1 ]] && window_reset_passed "$1" "$2"; then echo 0; return; fi
  window_field "$1" "$2" percent -1
}

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
# the one passed in. Every account is filtered before it is ranked: one that
# already reached the switch threshold in any watched window has no room, and
# one that can't be verified (usable_candidate) is never handed over to, so an
# untrusted account with more room never hides a usable one. Among the usable
# ones the ranking is unchanged; with the weekly window alone it is the old
# weekly ranking.
roomiest() { # account-to-ignore switch-at windows...
  local ignore=$1 at=$2; shift 2
  local best="" best_pct=2 name pct
  for name in $(profiles); do
    [[ $name == "$ignore" ]] && continue
    pct=$(tightest_of "$name" "$@")
    awk -v p="$pct" 'BEGIN{exit !(p >= 0)}' || continue
    reached "$pct" "$at" && continue
    usable_candidate "$name" "$@" || continue
    if awk -v p="$pct" -v b="$best_pct" 'BEGIN{exit !(p < b)}'; then
      best="$name"
      best_pct="$pct"
    fi
  done
  echo "$best"
}

# Whether a candidate can be handed over to: a real login (the adapter's
# plausible_login, when it has one), and figures fresh enough to trust (the
# adapter's p_watch_fresh, or else a usage.json under 2 hours old).
usable_candidate() { # account windows...
  local name=$1; shift
  if declare -F plausible_login >/dev/null; then plausible_login "$name" || return 1; fi
  if declare -F p_watch_fresh >/dev/null; then p_watch_fresh "$name" "$@"; return; fi
  local age=$(( $(date +%s) - $(stat -c %Y "$(account_dir "$name")/usage.json" 2>/dev/null || echo 0) ))
  (( age <= 7200 ))
}

# How a notification names each window.
window_span() { case $1 in weekly) echo "its week" ;; session) echo "its 5-hour window" ;; esac; }
window_spent() { case $1 in weekly) echo "ran out of weekly quota" ;; session) echo "hit its 5-hour limit" ;; esac; }

# One pass of the watchdog for the loaded provider: refresh the figures, warn
# once per threshold per window, and hand over to another account when this
# one is spent.
watch_check() {
  STATE_FILE="$(provider_root "$P_ID")/watch.json"
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
    local body="$cur $reason. Open sessions follow on their next message."
    declare -F p_watch_switched >/dev/null && body=$(p_watch_switched "$cur" "$reason" "$other")
    notify "Switched to $other" "$body" "$other"
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
