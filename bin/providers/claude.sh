# shellcheck shell=bash
# shellcheck disable=SC2034  # P_* vars are read by the engine after sourcing this file
# Claude Code adapter. Moved out of the old single-provider bin/swapkin
# unchanged: behaviour, storage layout ($ACCOUNTS/<name>/, $ACCOUNTS/active)
# and every helper here are byte-for-byte what shipped before providers existed.
# The watchdog that used to live here (`swapkin check`) is now shared by every
# watched provider, in bin/lib/watchdog.sh.
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
