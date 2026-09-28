# shellcheck shell=bash
# shellcheck disable=SC2034  # P_* vars are read by the engine after sourcing this file
# Codex adapter — cold. A switch writes the incoming account's login into the
# live ${CODEX_HOME:-~/.codex}/auth.json, which a plain `codex`, `codex
# app-server` (bar usage monitors) and `codex login status` all read. Each
# account keeps its own copy in providers/codex/<name>/auth.json. A running
# codex re-reads auth.json only before a token refresh, and refuses to refresh
# when the account_id there changed, so sessions already running keep the old
# account until they are restarted; they never write the swapped file back.

P_ID=codex
P_NAME=Codex
P_MODE=cold
P_CMD=codex
P_MARKER=codex.json
P_STORE='$CODEX_HOME/auth.json'
P_HOMEVAR=CODEX_HOME
P_HOW="New Codex sessions and bar usage monitors use the switched account. Codex sessions already running keep the old one; restart them to switch."
P_ADD_HINT="The first account is whatever CODEX_HOME is already signed into."

p_installed() { [[ -n $(tool_bin codex) ]]; }
# Running Codex sessions, leaving out app-server processes (the shared daemon,
# the ChatGPT app's server), which are not sessions of their own.
p_sessions() { { pgrep -ax codex 2>/dev/null || true; } | grep -vc -- app-server || true; }

home_of() { jq -r '.home // empty' "$(account_dir "$1")/codex.json" 2>/dev/null; } # name

# The home a plain codex reads, and its login file. A CODEX_HOME inside
# swapkin's own codex folder is a leftover from an old `eval "$(swapkin env)"`
# that pointed a shell at one account's legacy home; that is not the live
# login, so it is ignored. Any other CODEX_HOME was set on purpose and wins.
live_home() {
  local root; root=$(readlink -m "$(provider_root codex)")
  if [[ -n ${CODEX_HOME:-} && $(readlink -m "$CODEX_HOME")/ != "$root"/* ]]; then
    echo "$CODEX_HOME"
  else
    echo "$HOME/.codex"
  fi
}
live_auth() { echo "$(live_home)/auth.json"; }
store_of() { echo "$(account_dir "$1")/auth.json"; } # name

# base64url -> base64, padded.
_b64url() {
  local s pad
  s=$(tr '_-' '/+' <<<"$1")
  pad=$(( (4 - ${#s} % 4) % 4 ))
  while (( pad-- > 0 )); do s+="="; done
  printf '%s' "$s"
}

# The decoded payload of an auth.json's id_token (never the token itself), or
# nothing when the file has no readable id_token (an API-key login, say). The
# signature is not checked: this only reads what the login says about itself.
id_payload() { # auth.json
  local jwt
  jwt=$(jq -r '.tokens.id_token // empty' "$1" 2>/dev/null) || return 0
  [[ -n $jwt ]] || return 0
  base64 -d <<<"$(_b64url "$(cut -d. -f2 <<<"$jwt")")" 2>/dev/null \
    | jq -c 'objects' 2>/dev/null || true
}

# The ChatGPT claims object of an auth.json's id_token, or nothing.
id_claims() { # auth.json
  id_payload "$1" | jq -c '."https://api.openai.com/auth" // empty' 2>/dev/null || true
}

# The email an account signed in with: the id_token's own email claim, from its
# store, or from its legacy home while it has not been migrated to one yet.
p_email() { # name
  local auth; auth=$(store_of "$1")
  [[ -f $auth ]] || auth="$(home_of "$1")/auth.json"
  id_payload "$auth" | jq -r '.email // empty | strings' 2>/dev/null || true
}

# Who an auth.json belongs to, as "<user>/<workspace>": the ChatGPT user id
# and account id in its id_token (the account id falls back to
# tokens.account_id). One user can sign in to several workspaces, so the user
# id alone is not enough. Logins are compared by this, never by bytes, since
# every refresh rewrites the file. Nothing when there is no user id.
codex_identity() { # auth.json
  local claims user acct
  claims=$(id_claims "$1")
  user=$(jq -r '.chatgpt_user_id // .user_id // empty' <<<"$claims" 2>/dev/null || true)
  [[ -n $user ]] || return 0
  acct=$(jq -r '.chatgpt_account_id // empty' <<<"$claims" 2>/dev/null || true)
  [[ -n $acct ]] || acct=$(jq -r '.tokens.account_id // empty' "$1" 2>/dev/null || true)
  printf '%s/%s\n' "$user" "$acct"
}

# An API-key login, told apart positively: auth_mode "apikey", or an API key
# with no tokens object. A file without a ChatGPT identity that is not this
# (corrupt, truncated, unreadable) is a broken login, not an API-key one.
is_apikey_login() { # auth.json
  jq -e '((.auth_mode // "") | ascii_downcase) == "apikey"
         or (((.OPENAI_API_KEY // "") != "") and ((.tokens | type) != "object"))' "$1" >/dev/null 2>&1
}

# When switches first went in place, as epoch seconds. Before it, the live
# home held only the live-home account's sessions; after it, any account's.
inplace_since_file() { echo "$(provider_root codex)/.inplace_since"; }

# Record that time once, just before the first in-place write of the live
# file; an existing record is never moved.
mark_inplace_since() {
  local f tmp; f=$(inplace_since_file)
  [[ -e $f ]] && return 0
  tmp=$(mktemp "$f.XXXXXX" 2>/dev/null) || return 1
  if date +%s > "$tmp" && mv -f "$tmp" "$f"; then return 0; fi
  rm -f "$tmp"
  return 1
}

# Copy a login file through a temp file next to the destination, so a reader
# never sees half a file, and keep it private. Fails (status 1) without
# touching the destination when any step does, and leaves no temp file.
install_auth() { # src dest
  local tmp
  tmp=$(mktemp "$2.XXXXXX" 2>/dev/null) || return 1
  if cat "$1" > "$tmp" && cmp -s "$1" "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$2"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# The file an account's store is migrated from: its legacy home's auth.json,
# or the live file when its home is the live one. Nothing without a home.
legacy_source() { # name
  local home; home=$(home_of "$1")
  [[ -n $home ]] || return 0
  if [[ $(readlink -m "$home") == "$(readlink -m "$(live_home)")" ]]; then live_auth; else echo "$home/auth.json"; fi
}

# Give every account that has none yet its own auth.json, copied from the home
# it used before switches went in place. The account whose home is the live
# one takes the live file. Legacy homes are left where they are: their
# sessions still feed the usage figures. Idempotent: a stored login is never
# overwritten here.
codex_migrate() {
  local name src
  for name in $(profiles); do
    [[ -f $(store_of "$name") ]] && continue
    src=$(legacy_source "$name")
    [[ -n $src && -f $src ]] || continue
    install_auth "$src" "$(store_of "$name")" \
      || die "could not save '$name''s login to $(store_of "$name"); nothing was switched"
  done
  return 0
}

# The saved account the live login belongs to (the active one first), or
# nothing when it belongs to none of them.
owner_of_live() {
  local id; id=$(codex_identity "$(live_auth)")
  [[ -n $id ]] || return 0
  local cur name; cur=$(active)
  for name in $cur $(profiles); do
    [[ -f $(store_of "$name") && $(codex_identity "$(store_of "$name")") == "$id" ]] && { echo "$name"; return 0; }
  done
  return 0
}

# Shared by add and use: true only when a line starts with "Logged in",
# never on a substring match ("Not logged in" must not pass). A keyring-only
# login (no auth.json on disk) still reports logged in here, and that is
# enough — neither caller should also require auth.json to exist.
codex_logged_in() { # home
  local home="$1" cli status_out rc
  cli=$(tool_bin codex)
  [[ -n $cli ]] || return 1
  status_out=$(CODEX_HOME="$home" "$cli" login status 2>/dev/null)
  rc=$?
  (( rc == 0 )) || return 1
  grep -qE '^Logged in' <<<"$status_out"
}

write_codex_json() { # dir home
  jq -n --arg home "$2" '{home:$home}' > "$1/codex.json.tmp"
  mv "$1/codex.json.tmp" "$1/codex.json"
}

p_add() { # name
  local name="${1:?usage: swapkin -p codex add <name>}"
  valid_name "$name"
  local dir; dir=$(account_dir "$name")
  [[ -e $dir/codex.json ]] && die "'$name' already exists"

  if [[ -z $(profiles) ]]; then
    local home; home=$(live_home)
    [[ -f $home/auth.json ]] || codex_logged_in "$home" || die "no Codex login found in $home"
    mkdir -p "$dir"
    # A keyring login has no file to snapshot; that account stays pointer-only.
    if [[ -f $home/auth.json ]]; then
      install_auth "$home/auth.json" "$(store_of "$name")" || die "could not save the login to $(store_of "$name")"
    fi
    write_codex_json "$dir" "$home"
    set_colour "$name" "$(next_colour "$name")"
    set_active "$name"
    echo "Saved the current Codex login as '$name'."
    return
  fi

  local home; home="$(provider_root codex)/$name/home"
  mkdir -p "$home"
  local default_home f; default_home=$(live_home)
  for f in config.toml AGENTS.md prompts skills rules; do
    [[ -e $default_home/$f ]] && ln -sf "$default_home/$f" "$home/$f"
  done
  local cli; cli=$(tool_bin codex)
  [[ -n $cli ]] || fail "cannot find the codex command. Sign in manually and run: swapkin -p codex add $name"
  echo "Codex opens to sign in. Complete the flow; this returns once it's done."
  CODEX_HOME="$home" "$cli" login -c 'cli_auth_credentials_store="file"' || true
  [[ -f $home/auth.json ]] || fail "no sign-in found, so nothing was saved."
  mkdir -p "$dir"
  install_auth "$home/auth.json" "$(store_of "$name")" || fail "could not save the login to $(store_of "$name")"
  write_codex_json "$dir" "$home"
  set_colour "$name" "$(next_colour "$name")"
  echo "Saved '$name'. Switch with: swapkin -p codex use $name"
}

# The switch as it was before it went in place: only the pointer moves, and
# only sessions started through `swapkin run codex` or `swapkin env` follow.
use_pointer_only() { # name reason
  local name="$1" home; home=$(home_of "$name")
  [[ -n $home ]] || die "'$name' has no usable login; sign in again with: swapkin -p codex add $name"
  # auth.json on disk is enough, but a keyring-only login that still reports
  # logged in (M3) must be accepted too — don't require the file to exist.
  [[ -f $home/auth.json ]] || codex_logged_in "$home" \
    || die "'$name' has no usable login; sign in again with: swapkin -p codex add $name"
  set_active "$name"
  echo "Codex sessions started with swapkin run codex, or in a shell set up with eval \"\$(swapkin env codex)\", use $name. Open ones keep their account."
  echo "$2"
}

p_use() { # name
  local name="$1" dir; dir=$(account_dir "$name")
  # Every switch starts with no daemon outcome, so the watchdog's notice never
  # reports a restart from an earlier switch.
  printf 'none\n' > "$DAEMON_OUTCOME" 2>/dev/null || true
  [[ -f $dir/codex.json ]] || die "no saved account '$name'"
  local live; live=$(live_auth)
  if [[ ! -f $live ]]; then
    use_pointer_only "$name" "There is no auth.json in $(live_home) (a keyring login, or signed out), so a plain codex and bar monitors keep their login."
    return
  fi
  # Both sides are classified before anything is written. An API-key login
  # has no ChatGPT identity to tell whose login the live file holds, so only
  # the pointer moves. A login with no identity that is not an API-key one is
  # broken, and the switch stops.
  if [[ -z $(codex_identity "$live") ]]; then
    if is_apikey_login "$live"; then
      use_pointer_only "$name" "The login in $live has no ChatGPT identity (an API-key login), so the switch can't go in place; it is left as it is."
      return
    fi
    die "the live auth.json at $live is unreadable or has no usable login, so nothing was switched."
  fi
  # The target's saved login, or the file migration would save it from.
  local store src; store=$(store_of "$name")
  src=$store
  [[ -f $src ]] || src=$(legacy_source "$name")
  if [[ -z $src || ! -f $src ]]; then
    use_pointer_only "$name" "'$name' has no auth.json of its own (a keyring login), so $(live_home) keeps its current login."
    return
  fi
  local want; want=$(codex_identity "$src")
  if [[ -z $want ]]; then
    if is_apikey_login "$src"; then
      use_pointer_only "$name" "'$name' is an API-key login with no ChatGPT identity, so the switch can't go in place; $(live_home) keeps its current login."
      return
    fi
    die "'$name' has no usable login; sign in again with: swapkin -p codex add $name"
  fi
  codex_migrate

  # Save the live login back to its own account first: a refresh since the
  # last switch rotated its refresh token, and the stored copy is now spent.
  # A live login that belongs to no saved account would simply be lost.
  local owner; owner=$(owner_of_live)
  [[ -n $owner ]] || die "the Codex login in $live is not one of your saved accounts, and switching would lose it. Save it first with: swapkin -p codex add <name> (signing in to that same account), then switch."
  install_auth "$live" "$(store_of "$owner")" \
    || die "could not save the live login back to '$owner'; nothing was switched"
  mark_inplace_since || die "could not record $(inplace_since_file); nothing was switched"

  # A running codex may have refreshed (and rotated) the live login since it
  # was saved back. Overwriting it now would lose the new refresh token, so
  # stop instead: the live file still holds the newest login for its owner,
  # and the next switch saves it back first. Identical bytes also mean the
  # owner found above still owns it. A refresh landing between this check
  # and the move below can still be lost; that gap is tiny and can only be
  # closed by a lock codex itself honours.
  cmp -s "$live" "$(store_of "$owner")" \
    || die "Codex refreshed its login in $live while switching, so nothing was switched. Run the switch again."
  install_auth "$store" "$live" || die "could not write '$name' into $live; nothing was switched"
  if [[ $(codex_identity "$live") != "$want" ]]; then
    install_auth "$(store_of "$owner")" "$live" \
      || die "could not write '$name' into $live, and it could not be restored either. '$owner''s login is saved in $(store_of "$owner"); copy it back to $live."
    die "could not write '$name' into $live; it still holds '$owner'"
  fi
  set_active "$name"
  echo "Codex now uses $name: new sessions, codex login status and bar monitors all follow."
  local running; running=$(p_sessions || true)
  if (( ${running:-0} > 0 )); then
    echo "$running running Codex session(s) keep the previous account until you restart them."
  fi
  restart_daemon "$name"
}

# Codex 0.157 runs a shared background server (`codex app-server
# --managed-daemon`) that a plain `codex` connects to. It loaded its login when
# it started and keeps it in memory, so after an in-place switch it must be
# restarted for new sessions to use the new account. Sessions it was running
# are interrupted; `codex resume` brings them back. The outcome is left in
# DAEMON_OUTCOME for the watchdog's notice, which runs in another shell.
DAEMON_OUTCOME="$(provider_root codex)/.daemon_restart"
DAEMON_HINT="run: codex app-server daemon restart"

# codexDaemonRestart, default true. Read with has(): jq's `//` would turn an
# explicit false into the default. A missing or broken config means the default.
daemon_restart_wanted() {
  local v
  v=$(jq -r 'if type == "object" and has("codexDaemonRestart") then .codexDaemonRestart | tostring else "true" end' \
    "$ACCOUNTS/config.json" 2>/dev/null) || v=true
  [[ $v != false ]]
}

restart_daemon() { # name
  local outcome=none cli
  # Only this user's daemon: another user's is not ours to restart.
  if pgrep -u "$(id -u)" -f -- --managed-daemon >/dev/null 2>&1; then
    if ! daemon_restart_wanted; then
      outcome=disabled
      echo "The Codex daemon keeps the previous account until it is restarted; $DAEMON_HINT"
    # 9>&-: the switch holds $ACCOUNTS/.lock on fd 9, and the new daemon would
    # inherit it and keep every later switch locked out for as long as it runs.
    elif cli=$(tool_bin codex) && [[ -n $cli ]] && timeout 30 "$cli" app-server daemon restart >/dev/null 2>&1 9>&-; then
      outcome=restarted
      echo "Restarted the Codex daemon so new sessions use $1. Sessions it was running were interrupted; bring them back with codex resume."
    else
      outcome=failed
      echo "Could not restart the Codex daemon, so new sessions may keep the previous account; $DAEMON_HINT"
    fi
  fi
  printf '%s\n' "$outcome" > "$DAEMON_OUTCOME" 2>/dev/null || true
}

p_env() { # name
  # When the switch went in place, the account is already live in the live
  # home and needs nothing, except undoing a leftover CODEX_HOME that
  # live_home ignores. Otherwise (a keyring login, signed out, or no saved
  # auth.json) point the shell at the account's own home as before.
  local store id=""; store=$(store_of "$1")
  [[ -f $store ]] && id=$(codex_identity "$store")
  if [[ -n $id && -f $(live_auth) && $(codex_identity "$(live_auth)") == "$id" ]]; then
    [[ -n ${CODEX_HOME:-} && $CODEX_HOME != "$(live_home)" ]] && echo "CODEX_HOME=$(live_home)"
    return 0
  fi
  local home; home=$(home_of "$1")
  [[ -n $home ]] || return 0
  echo "CODEX_HOME=$home"
}

# The account's newest own rollout that holds a rate_limits line, from the
# live home (shared by every account since switches went in place) and its
# legacy home. Files are walked newest first and owners are checked on the
# way, so a busy account never pushes a quieter one's files out; at most the
# newest 500 are opened, so a huge sessions folder can't stall the bar. A
# file is this account's by its session_meta:
#   - creator_user_id and creator_account_id: both must match this account;
#   - creator_user_id only: it must match, and no other saved account may
#     share that user id (two workspaces of one user can't be told apart);
#   - no creator at all: an older codex wrote it before switches went in
#     place, when every home held only its own account, so it counts only
#     for the account whose legacy home it lives in. In the live home that
#     holds only until the first in-place switch (.inplace_since); after it,
#     any account may have written there.
own_rollout() { # name identity
  local name="$1" id="$2" user="${2%%/*}" legacy h homes=() seen="" f
  legacy=$(home_of "$name")
  [[ -n $legacy ]] && legacy="$(readlink -f "$legacy")/sessions/"
  local live_sessions since=""
  live_sessions="$(readlink -f "$(live_home)")/sessions/"
  if [[ -f $(inplace_since_file) ]]; then
    since=$(cat "$(inplace_since_file)" 2>/dev/null || true)
    # An unreadable record still means a switch happened at some point.
    [[ $since =~ ^[0-9]+$ ]] || since=0
  fi
  for h in "$(live_home)" "$(home_of "$name")"; do
    [[ -n $h && -d $h/sessions ]] || continue
    h=$(readlink -f "$h")
    [[ $seen == *$'\n'"$h"$'\n'* ]] && continue
    seen+=$'\n'"$h"$'\n'
    homes+=("$h/sessions")
  done
  (( ${#homes[@]} )) || return 0

  # How many saved accounts sign in as this user, whatever the workspace.
  local other same_user=0
  for other in $(profiles); do
    [[ -f $(store_of "$other") ]] || continue
    [[ $(codex_identity "$(store_of "$other")") == "$user"/* ]] && same_user=$((same_user + 1))
  done

  local meta cu ca
  while IFS= read -r f; do
    meta=$(head -n1 "$f" 2>/dev/null | jq -r 'select(.type == "session_meta")
      | [(.payload.creator_user_id // ""), (.payload.creator_account_id // "")] | @tsv' 2>/dev/null) || continue
    [[ -n $meta ]] || continue
    IFS=$'\t' read -r cu ca <<<"$meta"
    if [[ -n $cu && -n $ca ]]; then
      [[ "$cu/$ca" == "$id" ]] || continue
    elif [[ -n $cu ]]; then
      [[ $cu == "$user" ]] && (( same_user == 1 )) || continue
    elif [[ -z $ca ]]; then
      [[ -n $legacy && $f == "$legacy"* ]] || continue
      if [[ -n $since && $f == "$live_sessions"* ]]; then
        local mtime; mtime=$(stat -c %Y "$f" 2>/dev/null) || continue
        (( mtime < since )) || continue
      fi
    else
      continue
    fi
    grep -q '"rate_limits"' "$f" 2>/dev/null || continue
    printf '%s\n' "$f"
    return 0
  done < <(find "${homes[@]}" -name 'rollout-*.jsonl' -type f -printf '%T@\t%p\n' 2>/dev/null \
             | sort -rn | head -500 | cut -f2-)
  return 0
}

p_probe() { # name
  local name="$1" dir; dir=$(account_dir "$name")
  local home; home=$(home_of "$name")
  local auth; auth=$(store_of "$name")
  local files=()
  if [[ -f $auth ]]; then
    local id; id=$(codex_identity "$auth")
    [[ -n $id ]] || return 0
    mapfile -t files < <(own_rollout "$name" "$id")
  else
    # Not migrated yet: its home has only ever held this account's sessions.
    auth="$home/auth.json"
    [[ -n $home && -d $home/sessions ]] || return 0
    mapfile -t files < <(find "$home/sessions" -name 'rollout-*.jsonl' -type f 2>/dev/null | sort -r | head -5)
  fi
  (( ${#files[@]} )) || return 0

  local f line="" rl_file=""
  for f in "${files[@]}"; do
    line=$(tac "$f" 2>/dev/null | grep -m1 '"rate_limits"' || true)
    [[ -n $line ]] && { rl_file="$f"; break; }
  done
  [[ -n $line ]] || return 0

  local payload; payload=$(jq -c '.payload.rate_limits // empty' <<<"$line" 2>/dev/null) || return 0
  [[ -n $payload && $payload != null ]] || return 0
  local mtime; mtime=$(stat -c %Y "$rl_file")
  local updated_at; updated_at=$(date -u -d "@$mtime" +%Y-%m-%dT%H:%M:%SZ)

  local plan=""
  plan=$(jq -r '.plan_type // empty' <<<"$payload")
  if [[ -z $plan && -f $auth ]]; then
    plan=$(jq -r '.chatgpt_plan_type // empty' <<<"$(id_claims "$auth")" 2>/dev/null || true)
  fi

  local limits='[]' key
  for key in primary secondary; do
    local node; node=$(jq -c --arg k "$key" '.[$k] // empty' <<<"$payload")
    [[ -n $node && $node != null ]] || continue
    local used_pct win resets_at resets_in iso=""
    IFS=$'\t' read -r used_pct win resets_at resets_in <<<"$(jq -r \
      '[(.used_percent // 0), (.window_minutes // 0), (.resets_at // ""), (.resets_in_seconds // "")] | @tsv' \
      <<<"$node")"
    if [[ -n $resets_at ]]; then
      iso=$(date -u -d "@$resets_at" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
    elif [[ -n $resets_in ]]; then
      iso=$(date -u -d "@$((mtime + resets_in))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
    fi
    local label
    if [[ $win == 300 ]]; then label="5h window"
    elif [[ $win == 10080 ]]; then label="Weekly"
    elif (( win > 0 && win % 60 == 0 )); then label="$((win/60))h window"
    else label="${win}m window"; fi
    limits=$(jq -c --argjson limits "$limits" --arg label "$label" --argjson pct "$used_pct" --arg resets "$iso" \
      -n '$limits + [{label:$label, percent: ($pct/100), resetsAt:$resets}]')
  done

  jq -n --argjson limits "$limits" --arg plan "$plan" --arg updated "$updated_at" \
    '{limits:$limits, counts:[], tierLabel:$plan, note:"", updatedAt:$updated}' > "$dir/usage.json.tmp"
  mv "$dir/usage.json.tmp" "$dir/usage.json"
}

p_plan() { jq -r '.tierLabel // empty' "$(account_dir "$1")/usage.json" 2>/dev/null; }

# --- the watchdog (bin/lib/watchdog.sh), when autoSwitchProviders has "codex" ---

# Codex figures are never fetched live: p_probe reads them from the account's
# last session on this machine, so a window that reset since then has room.
P_WATCH_RESETS_EXPIRE=1
# An account with no session on this machine has no figures at all. Its usage
# can only be what other machines spent, so it is a last resort when no account
# with known room exists. If it turns out spent, the watchdog hands over again
# once a session on this machine has recorded its limits.
P_WATCH_UNKNOWN_IS_ROOM=1

# A candidate the watchdog may hand over to: a saved account whose login file,
# when there is one, holds a ChatGPT identity or an API key. A corrupt one is
# skipped. One with no file at all (a keyring login) is left to p_use, which
# checks that it still signs in.
plausible_login() { # account
  [[ -f $(account_dir "$1")/codex.json ]] || return 1
  local src; src=$(store_of "$1")
  [[ -f $src ]] || src=$(legacy_source "$1")
  [[ -n $src && -f $src ]] || return 0
  [[ -n $(codex_identity "$src") ]] || is_apikey_login "$src"
}

# Whether a candidate's figures can be trusted: always, for Codex. Claude's
# rule (usage.json under 2 hours old) does not fit here: p_probe rewrites
# usage.json on every check, and its figures are the rate limits of the
# account's last session, which for an idle account can be days old. But an
# account nobody uses can't see its usage go up, only down when a window
# resets, so an old figure is an upper bound on its usage now. Each watched
# window therefore has room when its reset has passed (window_pct reads it as
# 0) or when its figure, however old, is below autoSwitchAt, which is what the
# watchdog's ranking already checks. That bound assumes the account isn't in
# use on another machine at the same time; if it is, the worst case is a
# switch to a spent account, and the next check hands over again.
p_watch_fresh() { return 0; } # account windows...

# The "switched" notice. The live login changed, but a running codex keeps
# the account it started with until it is restarted. When the switch could not
# go in place (no live auth.json, or an API-key login), only sessions started
# through swapkin follow.
p_watch_switched() { # from reason to
  local body="$1 $2. Running Codex sessions keep $1 until they are restarted."
  local want; want=$(codex_identity "$(store_of "$3")")
  if [[ -z $want || ! -f $(live_auth) || $(codex_identity "$(live_auth)") != "$want" ]]; then
    body+=" The switch could not go in place, so start new sessions with swapkin run codex."
  fi
  case $(cat "$DAEMON_OUTCOME" 2>/dev/null) in
    restarted) body+=" Restarted the Codex daemon; codex resume brings back what it was running." ;;
    failed|disabled) body+=" The Codex daemon still has $1; $DAEMON_HINT." ;;
  esac
  printf '%s\n' "$body"
}
