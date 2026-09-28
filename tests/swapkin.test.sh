#!/usr/bin/env bash
# Run: bash tests/swapkin.test.sh
#
# No real HOME, SWAPKIN_DIR, gh config or network is ever touched: every test
# below builds its own temp HOME/SWAPKIN_DIR/XDG dirs and puts stub claude/
# codex/gh commands on PATH first.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
ROOT="$(dirname "$HERE")"
SWAPKIN="$ROOT/bin/swapkin"
FIXTURES="$HERE/fixtures"

PASS=0
FAIL=0
ALL_OUTPUT_LOG="$(mktemp)"
trap 'rm -f "$ALL_OUTPUT_LOG"' EXIT

ok() { PASS=$((PASS+1)); echo "  ok - $1"; }
bad() { FAIL=$((FAIL+1)); echo "  NOT OK - $1"; }

assert_eq() { # desc expected actual
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected [$2] got [$3])"; fi
}
assert_true() { if "$@" >/dev/null 2>&1; then ok "$*"; else bad "$*"; fi; }
assert_contains() { # desc haystack needle
  if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1 (missing [$3])"; fi
}
assert_not_contains() { # desc haystack needle
  if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1 (found forbidden [$3])"; fi
}

# Every real swapkin invocation in the suite goes through here, so its output
# also lands in ALL_OUTPUT_LOG for the final "no fixture token leaked" check.
sk() { # env-assignments... -- args...
  local out
  out=$("$@" 2>&1)
  echo "$out" >> "$ALL_OUTPUT_LOG"
  printf '%s' "$out"
}

# --- a fresh sandbox: temp HOME, SWAPKIN_DIR, XDG dirs, stub PATH ---
STUBS="$(mktemp -d)"
mk_stub() { # name body
  cat > "$STUBS/$1" <<EOF
#!/usr/bin/env bash
$2
EOF
  chmod +x "$STUBS/$1"
}

sandbox() {
  local dir; dir=$(mktemp -d)
  mkdir -p "$dir/home" "$dir/data" "$dir/config" "$dir/state" "$dir/cache"
  echo "$dir"
}

# ============================================================ 1. claude use ==
echo "1. claude use saves the live login back before switching"
S=$(sandbox)
export HOME="$S/home" SWAPKIN_DIR="$S/data" CLAUDE_CONFIG_DIR="$S/home/.claude" \
       XDG_CONFIG_HOME="$S/config" XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" \
       PATH="$STUBS:$PATH" SWAPKIN_DEMO=0
unset SWAPKIN_PROVIDER
mkdir -p "$CLAUDE_CONFIG_DIR"
LIVE_TOKEN="live-token-for-work-AAAAAAAAAAAAAAAAAAAAAAAAAAAA"
STALE_TOKEN="stale-token-for-work-BBBBBBBBBBBBBBBBBBBBBBBBBBBB"
PERSONAL_TOKEN="token-for-personal-CCCCCCCCCCCCCCCCCCCCCCCCCCCC"
jq -n --arg t "$LIVE_TOKEN" '{claudeAiOauth:{refreshToken:$t, subscriptionType:"max"}}' > "$CLAUDE_CONFIG_DIR/.credentials.json"
jq -n '{theme:"dark"}' > "$CLAUDE_CONFIG_DIR/.claude.json"
mkdir -p "$SWAPKIN_DIR/work" "$SWAPKIN_DIR/personal"
jq -n --arg t "$STALE_TOKEN" '{refreshToken:$t, subscriptionType:"max"}' > "$SWAPKIN_DIR/work/oauth.json"
echo '{}' > "$SWAPKIN_DIR/work/account.json"
jq -n '{colour:"#7fa7d9"}' > "$SWAPKIN_DIR/work/meta.json"
jq -n --arg t "$PERSONAL_TOKEN" '{refreshToken:$t, subscriptionType:"pro"}' > "$SWAPKIN_DIR/personal/oauth.json"
echo '{}' > "$SWAPKIN_DIR/personal/account.json"
jq -n '{colour:"#d97757"}' > "$SWAPKIN_DIR/personal/meta.json"
echo work > "$SWAPKIN_DIR/active"

out=$(sk "$SWAPKIN" use personal)
assert_contains "use prints the new active account" "$out" "Active: personal"
saved_back=$(jq -r .refreshToken "$SWAPKIN_DIR/work/oauth.json")
assert_eq "outgoing account's live login was saved back before the switch" "$LIVE_TOKEN" "$saved_back"
live_now=$(jq -r .claudeAiOauth.refreshToken "$CLAUDE_CONFIG_DIR/.credentials.json")
assert_eq "live credentials now hold the incoming account's token" "$PERSONAL_TOKEN" "$live_now"
assert_eq "active pointer updated" "personal" "$(cat "$SWAPKIN_DIR/active")"

# ======================================================= 2. codex writes no auth.json ==
echo "2. codex use writes no auth.json anywhere"
S=$(sandbox)
export HOME="$S/home" SWAPKIN_DIR="$S/data" XDG_CONFIG_HOME="$S/config" \
       XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" PATH="$STUBS:$PATH"
unset CLAUDE_CONFIG_DIR
mkdir -p "$S/codex-home-a" "$S/codex-home-b"
echo '{"tokens":{"id_token":"x"}}' > "$S/codex-home-a/auth.json"
echo '{"tokens":{"id_token":"x"}}' > "$S/codex-home-b/auth.json"
before_a=$(md5sum "$S/codex-home-a/auth.json" | cut -d' ' -f1)
before_b=$(md5sum "$S/codex-home-b/auth.json" | cut -d' ' -f1)
mkdir -p "$SWAPKIN_DIR/providers/codex/work" "$SWAPKIN_DIR/providers/codex/side-project"
jq -n --arg h "$S/codex-home-a" '{home:$h}' > "$SWAPKIN_DIR/providers/codex/work/codex.json"
jq -n '{colour:"#7fa7d9"}' > "$SWAPKIN_DIR/providers/codex/work/meta.json"
jq -n --arg h "$S/codex-home-b" '{home:$h}' > "$SWAPKIN_DIR/providers/codex/side-project/codex.json"
jq -n '{colour:"#d97757"}' > "$SWAPKIN_DIR/providers/codex/side-project/meta.json"
echo work > "$SWAPKIN_DIR/providers/codex/active"

before_count=$(find "$S" -name auth.json | wc -l)
out=$(sk "$SWAPKIN" -p codex use side-project)
assert_contains "codex use reports the new active account" "$out" "side-project"
after_count=$(find "$S" -name auth.json | wc -l)
assert_eq "no new auth.json files appeared anywhere under the sandbox" "$before_count" "$after_count"
assert_eq "codex-home-a/auth.json untouched" "$before_a" "$(md5sum "$S/codex-home-a/auth.json" | cut -d' ' -f1)"
assert_eq "codex-home-b/auth.json untouched" "$before_b" "$(md5sum "$S/codex-home-b/auth.json" | cut -d' ' -f1)"
assert_eq "active pointer switched" "side-project" "$(cat "$SWAPKIN_DIR/providers/codex/active")"

# ==================================================== 3. codex probe: new + old fields ==
echo "3. codex probe parses a rollout fixture (new and old reset fields)"
S=$(sandbox)
export HOME="$S/home" SWAPKIN_DIR="$S/data" XDG_CONFIG_HOME="$S/config" \
       XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" PATH="$STUBS:$PATH"
mkdir -p "$S/home-new/sessions" "$S/home-old/sessions"
cp "$FIXTURES/rollout-new.jsonl" "$S/home-new/sessions/rollout-001.jsonl"
cp "$FIXTURES/rollout-old.jsonl" "$S/home-old/sessions/rollout-001.jsonl"
mkdir -p "$SWAPKIN_DIR/providers/codex/newfmt" "$SWAPKIN_DIR/providers/codex/oldfmt"
jq -n --arg h "$S/home-new" '{home:$h}' > "$SWAPKIN_DIR/providers/codex/newfmt/codex.json"
jq -n '{colour:"#7fa7d9"}' > "$SWAPKIN_DIR/providers/codex/newfmt/meta.json"
jq -n --arg h "$S/home-old" '{home:$h}' > "$SWAPKIN_DIR/providers/codex/oldfmt/codex.json"
jq -n '{colour:"#d97757"}' > "$SWAPKIN_DIR/providers/codex/oldfmt/meta.json"

sk "$SWAPKIN" -p codex usage >/dev/null
newfmt_label=$(jq -r '.limits[0].label' "$SWAPKIN_DIR/providers/codex/newfmt/usage.json" 2>/dev/null)
newfmt_pct=$(jq -r '.limits[0].percent' "$SWAPKIN_DIR/providers/codex/newfmt/usage.json" 2>/dev/null)
newfmt_weekly_label=$(jq -r '.limits[1].label' "$SWAPKIN_DIR/providers/codex/newfmt/usage.json" 2>/dev/null)
newfmt_resets=$(jq -r '.limits[0].resetsAt' "$SWAPKIN_DIR/providers/codex/newfmt/usage.json" 2>/dev/null)
assert_eq "new-format: 300min window labelled '5h window'" "5h window" "$newfmt_label"
assert_eq "new-format: percent converted from used_percent" "0.42" "$newfmt_pct"
assert_eq "new-format: 10080min window labelled 'Weekly'" "Weekly" "$newfmt_weekly_label"
assert_contains "new-format: resets_at (unix seconds) turned into ISO" "$newfmt_resets" "T"

oldfmt_label=$(jq -r '.limits[0].label' "$SWAPKIN_DIR/providers/codex/oldfmt/usage.json" 2>/dev/null)
oldfmt_pct=$(jq -r '.limits[0].percent' "$SWAPKIN_DIR/providers/codex/oldfmt/usage.json" 2>/dev/null)
oldfmt_resets=$(jq -r '.limits[0].resetsAt' "$SWAPKIN_DIR/providers/codex/oldfmt/usage.json" 2>/dev/null)
assert_eq "old-format: 300min window labelled '5h window'" "5h window" "$oldfmt_label"
assert_eq "old-format: percent converted from used_percent" "0.09" "$oldfmt_pct"
assert_contains "old-format: resets_in_seconds turned into ISO" "$oldfmt_resets" "T"

# ================================================ 4. copilot probe + no token in argv ==
echo "4. copilot probe parses a fixture and never puts the token in argv"
S=$(sandbox)
export HOME="$S/home" SWAPKIN_DIR="$S/data" XDG_CONFIG_HOME="$S/config" \
       XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" PATH="$STUBS:$PATH"
GH_ARGV_LOG="$S/gh-argv.log"; : > "$GH_ARGV_LOG"
GH_SECRET_TOKEN="ghs_SENTINEL_NEVER_IN_ARGV_0000000000"
mk_stub gh "
ARGV_LOG=\"$GH_ARGV_LOG\"
echo \"\$@\" >> \"\$ARGV_LOG\"
case \"\$1\" in
  auth)
    case \"\$2\" in
      status) cat '$FIXTURES/gh-auth-status.json' ;;
      token) echo '$GH_SECRET_TOKEN' ;;
      switch) exit 0 ;;
    esac ;;
  api) cat '$FIXTURES/copilot-user.json' ;;
esac
"
mkdir -p "$SWAPKIN_DIR/providers/copilot/work"
jq -n '{user:"octo-work"}' > "$SWAPKIN_DIR/providers/copilot/work/copilot.json"
jq -n '{colour:"#7fa7d9"}' > "$SWAPKIN_DIR/providers/copilot/work/meta.json"
echo work > "$SWAPKIN_DIR/providers/copilot/active"

sk "$SWAPKIN" -p copilot usage >/dev/null
plan=$(jq -r .tierLabel "$SWAPKIN_DIR/providers/copilot/work/usage.json" 2>/dev/null)
premium_pct=$(jq -r '.limits[0].percent' "$SWAPKIN_DIR/providers/copilot/work/usage.json" 2>/dev/null)
chat_count=$(jq -r '.counts[] | select(.label=="Chat") | .value' "$SWAPKIN_DIR/providers/copilot/work/usage.json" 2>/dev/null)
assert_eq "plan mapped from access_type_sku (individual -> Pro)" "Pro" "$plan"
assert_eq "premium requests percent = used/entitlement" "0.62" "$premium_pct"
assert_eq "unlimited quota becomes a count, not a percent" "unlimited" "$chat_count"
argv_content=$(cat "$GH_ARGV_LOG")
assert_not_contains "gh's argv log never contains the token" "$argv_content" "$GH_SECRET_TOKEN"

# =========================================================== 6. custom cold env ==
echo "6. custom cold env"
S=$(sandbox)
export HOME="$S/home" SWAPKIN_DIR="$S/data" XDG_CONFIG_HOME="$S/config" \
       XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" PATH="$STUBS:$PATH"
mkdir -p "$XDG_CONFIG_HOME/swapkin"
cat > "$XDG_CONFIG_HOME/swapkin/providers.json" <<JSON
{"providers":[{"id":"othertool","name":"Other Tool","command":"othertool","mode":"cold","homeEnv":"OTHER_HOME","defaultHome":"~/.other"}]}
JSON
chmod 600 "$XDG_CONFIG_HOME/swapkin/providers.json"
mkdir -p "$SWAPKIN_DIR/providers/othertool/side-project"
jq -n --arg h "$S/other-home" '{mode:"cold", home:$h}' > "$SWAPKIN_DIR/providers/othertool/side-project/custom.json"
jq -n '{colour:"#8fb572"}' > "$SWAPKIN_DIR/providers/othertool/side-project/meta.json"
echo side-project > "$SWAPKIN_DIR/providers/othertool/active"

out=$(sk "$SWAPKIN" env othertool)
assert_contains "env prints export OTHER_HOME=..." "$out" "export OTHER_HOME="
assert_contains "env points at the account's own home" "$out" "$S/other-home"

# =========================================== 7. unsafe custom config is ignored ==
echo "7. unsafe custom config file is ignored with a stderr warning"
S=$(sandbox)
export HOME="$S/home" SWAPKIN_DIR="$S/data" XDG_CONFIG_HOME="$S/config" \
       XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" PATH="$STUBS:$PATH"
mkdir -p "$XDG_CONFIG_HOME/swapkin"
cat > "$XDG_CONFIG_HOME/swapkin/providers.json" <<JSON
{"providers":[{"id":"unsafe","name":"Unsafe","command":"unsafe","mode":"cold","homeEnv":"DUMMY_HOME","defaultHome":"~/.dummy"}]}
JSON
chmod 666 "$XDG_CONFIG_HOME/swapkin/providers.json"

out=$("$SWAPKIN" providers --json 2>"$S/stderr.log")
echo "$out" >> "$ALL_OUTPUT_LOG"
cat "$S/stderr.log" >> "$ALL_OUTPUT_LOG"
assert_contains "a warning is printed to stderr" "$(cat "$S/stderr.log")" "ignoring"
assert_not_contains "the unsafe provider is not in the output" "$out" '"id":"unsafe"'

# ============================================ 8. demo mode: sentinel HOME untouched ==
echo "8. demo mode leaves a sentinel HOME untouched and never prints sentinel token text"
S=$(sandbox)
export HOME="$S/home" SWAPKIN_DIR="$S/data" XDG_CONFIG_HOME="$S/config" \
       XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" PATH="$STUBS:$PATH" \
       SWAPKIN_DEMO=1 SWAPKIN_DEMO_FILE="$FIXTURES/demo-providers.json"
mkdir -p "$HOME/.claude"
SENTINEL_TOKEN="SENTINEL-REAL-REFRESH-TOKEN-DO-NOT-TOUCH-0000000000"
jq -n --arg t "$SENTINEL_TOKEN" '{claudeAiOauth:{refreshToken:$t, subscriptionType:"max"}}' > "$HOME/.claude/.credentials.json"
before_sum=$(md5sum "$HOME/.claude/.credentials.json" | cut -d' ' -f1)
before_tree=$(find "$HOME" -type f | sort)

demo_out=""
for args in "providers --json" "list --json" "status" "statusline" "cost" \
            "use personal" "add personal" "remove personal" "save" "usage" "check" \
            "env" "-p codex run codex"; do
  # shellcheck disable=SC2086
  demo_out+=$(sk "$SWAPKIN" $args)
  demo_out+=$'\n'
done

after_sum=$(md5sum "$HOME/.claude/.credentials.json" | cut -d' ' -f1)
after_tree=$(find "$HOME" -type f | sort)
assert_eq "sentinel credentials file byte-identical after every demo command" "$before_sum" "$after_sum"
assert_eq "no files created or removed under the sentinel HOME" "$before_tree" "$after_tree"
assert_not_contains "no demo output contains the sentinel token" "$demo_out" "$SENTINEL_TOKEN"
assert_contains "write commands say demo mode, nothing changed" "$demo_out" "demo mode, nothing changed"

# ======================================================= 9. providers --json shape ==
echo "9. providers --json output validates against the documented shape"
S=$(sandbox)
export HOME="$S/home" SWAPKIN_DIR="$S/data" XDG_CONFIG_HOME="$S/config" \
       XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" PATH="$STUBS:$PATH" SWAPKIN_DEMO=0
unset SWAPKIN_DEMO_FILE
mkdir -p "$SWAPKIN_DIR/work"
echo '{"refreshToken":"'"$(printf 'x%.0s' {1..40})"'","subscriptionType":"max"}' > "$SWAPKIN_DIR/work/oauth.json"
echo '{}' > "$SWAPKIN_DIR/work/account.json"
jq -n '{colour:"#7fa7d9"}' > "$SWAPKIN_DIR/work/meta.json"
echo work > "$SWAPKIN_DIR/active"

out=$(sk "$SWAPKIN" providers --json)
shape_ok=$(jq -e '
  (.demo == false) and
  (.providers | type == "array") and
  (.providers | all(
    (has("id") and has("name") and has("mode") and has("modeLabel") and has("modeWords")
     and has("store") and has("how") and has("addHint") and has("installed") and has("sessions") and has("accounts"))
    and (.mode as $m | ["hot","cold","never"] | index($m) != null)
    and (.accounts | type == "array")
    and (.accounts | all(has("name") and has("active") and has("colour") and has("plan") and has("age")))
  ))
' <<<"$out" >/dev/null 2>&1 && echo yes || echo no)
assert_eq "providers --json matches the documented shape" "yes" "$shape_ok"
assert_contains "the claude provider with its saved account is present" "$out" '"id":"claude"'

# ==================================== 11. H2: remove providers / path traversal ==
echo "11. remove providers is rejected; path traversal in remove is rejected"
S=$(sandbox)
export HOME="$S/home" SWAPKIN_DIR="$S/data" CLAUDE_CONFIG_DIR="$S/home/.claude" \
       XDG_CONFIG_HOME="$S/config" XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" \
       PATH="$STUBS:$PATH"
mkdir -p "$SWAPKIN_DIR/providers/codex/other"
jq -n --arg h "$S/codex-home" '{home:$h}' > "$SWAPKIN_DIR/providers/codex/other/codex.json"
jq -n '{colour:"#7fa7d9"}' > "$SWAPKIN_DIR/providers/codex/other/meta.json"

out=$("$SWAPKIN" -p claude remove providers 2>&1); rc=$?
echo "$out" >> "$ALL_OUTPUT_LOG"
assert_true [ "$rc" -ne 0 ]
assert_contains "'providers' is rejected as an account name" "$out" "reserved"
assert_true [ -d "$SWAPKIN_DIR/providers/codex/other" ]

out=$("$SWAPKIN" -p codex remove '../x' 2>&1); rc=$?
echo "$out" >> "$ALL_OUTPUT_LOG"
assert_true [ "$rc" -ne 0 ]
assert_contains "path traversal in remove is rejected" "$out" "account names use"

# ============================================ 13. M2: malformed usage.json ==
echo "13. a non-object usage.json never breaks providers --json / list --json"
S=$(sandbox)
export HOME="$S/home" SWAPKIN_DIR="$S/data" CLAUDE_CONFIG_DIR="$S/home/.claude" \
       XDG_CONFIG_HOME="$S/config" XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" \
       PATH="$STUBS:$PATH" SWAPKIN_DEMO=0
mkdir -p "$CLAUDE_CONFIG_DIR" "$SWAPKIN_DIR/work"
echo '{"refreshToken":"'"$(printf 'x%.0s' {1..40})"'","subscriptionType":"max"}' > "$SWAPKIN_DIR/work/oauth.json"
echo '{}' > "$SWAPKIN_DIR/work/account.json"
jq -n '{colour:"#7fa7d9"}' > "$SWAPKIN_DIR/work/meta.json"
echo '[1,2,3]' > "$SWAPKIN_DIR/work/usage.json"
echo work > "$SWAPKIN_DIR/active"

json_valid() { printf '%s' "$1" | jq -e . >/dev/null 2>&1; }

out=$("$SWAPKIN" providers --json 2>&1); rc=$?
echo "$out" >> "$ALL_OUTPUT_LOG"
assert_eq "providers --json still exits 0 with a malformed usage.json on disk" 0 "$rc"
assert_true json_valid "$out"
assert_contains "claude is still present in providers --json" "$out" '"id":"claude"'

out2=$("$SWAPKIN" list --json 2>&1); rc2=$?
echo "$out2" >> "$ALL_OUTPUT_LOG"
assert_eq "list --json still exits 0 with a malformed usage.json on disk" 0 "$rc2"
assert_true json_valid "$out2"

# ============================================== 14. M3: codex 'Not logged in' ==
echo "14. codex add refuses on 'Not logged in'; accepts a keyring-only login for add and use"
S=$(sandbox)
export HOME="$S/home" SWAPKIN_DIR="$S/data" XDG_CONFIG_HOME="$S/config" \
       XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" PATH="$STUBS:$PATH"
mkdir -p "$S/codex-home-notloggedin" "$S/codex-home-keyring"
mk_stub codex "
case \"\$1 \$2\" in
  'login status')
    case \"\$CODEX_HOME\" in
      *codex-home-notloggedin) echo 'Not logged in'; exit 1 ;;
      *codex-home-keyring) echo 'Logged in using ChatGPT'; exit 0 ;;
    esac ;;
esac
"
out=$(CODEX_HOME="$S/codex-home-notloggedin" "$SWAPKIN" -p codex add notloggedin 2>&1); rc=$?
echo "$out" >> "$ALL_OUTPUT_LOG"
assert_true [ "$rc" -ne 0 ]
assert_contains "'Not logged in' is refused, not accepted as a substring match" "$out" "no Codex login found"

out2=$(CODEX_HOME="$S/codex-home-keyring" "$SWAPKIN" -p codex add keyringacct 2>&1); rc2=$?
echo "$out2" >> "$ALL_OUTPUT_LOG"
assert_eq "a keyring-only login (no auth.json) is accepted by add" 0 "$rc2"
mkdir -p "$SWAPKIN_DIR/providers/codex/other"
jq -n --arg h "$S/codex-other-home" '{home:$h}' > "$SWAPKIN_DIR/providers/codex/other/codex.json"
jq -n '{colour:"#d97757"}' > "$SWAPKIN_DIR/providers/codex/other/meta.json"
echo other > "$SWAPKIN_DIR/providers/codex/active"
out3=$(CODEX_HOME="$S/codex-home-keyring" "$SWAPKIN" -p codex use keyringacct 2>&1); rc3=$?
echo "$out3" >> "$ALL_OUTPUT_LOG"
assert_eq "the same keyring-only login is accepted by use too, without auth.json" 0 "$rc3"

# ==================================================== 15. M8: run -- passthrough ==
echo "15. run -- passes every following argument to the child untouched, including -p"
S=$(sandbox)
export HOME="$S/home" SWAPKIN_DIR="$S/data" XDG_CONFIG_HOME="$S/config" \
       XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" PATH="$STUBS:$PATH"
CODEX_ARGV_LOG="$S/codex-argv.log"
mk_stub codex "echo \"\$@\" > \"$CODEX_ARGV_LOG\""
mkdir -p "$SWAPKIN_DIR/providers/codex/work"
jq -n --arg h "$S/codex-home" '{home:$h}' > "$SWAPKIN_DIR/providers/codex/work/codex.json"
jq -n '{colour:"#7fa7d9"}' > "$SWAPKIN_DIR/providers/codex/work/meta.json"
echo work > "$SWAPKIN_DIR/providers/codex/active"

sk "$SWAPKIN" run codex -- -p myprofile exec hi >/dev/null
argv=$(cat "$CODEX_ARGV_LOG" 2>/dev/null)
assert_eq "codex's own -p reaches it unchanged" "-p myprofile exec hi" "$argv"

# ============================================ 16. M9: copilot active from gh ==
echo "16. copilot's active account follows gh's real login, and use always calls gh auth switch"
S=$(sandbox)
export HOME="$S/home" SWAPKIN_DIR="$S/data" XDG_CONFIG_HOME="$S/config" \
       XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" PATH="$STUBS:$PATH"
GH_SWITCH_LOG="$S/gh-switch.log"; : > "$GH_SWITCH_LOG"
mk_stub gh "
case \"\$1 \$2\" in
  'auth status') cat '$FIXTURES/gh-auth-status.json' ;;
  'auth switch') echo \"\$@\" >> \"$GH_SWITCH_LOG\"; exit 0 ;;
esac
"
mkdir -p "$SWAPKIN_DIR/providers/copilot/work" "$SWAPKIN_DIR/providers/copilot/other"
jq -n '{user:"octo-work"}' > "$SWAPKIN_DIR/providers/copilot/work/copilot.json"
jq -n '{colour:"#7fa7d9"}' > "$SWAPKIN_DIR/providers/copilot/work/meta.json"
jq -n '{user:"octo-other"}' > "$SWAPKIN_DIR/providers/copilot/other/copilot.json"
jq -n '{colour:"#d97757"}' > "$SWAPKIN_DIR/providers/copilot/other/meta.json"
# The stored pointer says 'other', but gh (the fixture) says octo-work is active.
echo other > "$SWAPKIN_DIR/providers/copilot/active"

out=$(sk "$SWAPKIN" -p copilot status)
assert_contains "status reads gh's real active login, not the stale stored pointer" "$out" "work"

out2=$(sk "$SWAPKIN" -p copilot use work)
switch_log=$(cat "$GH_SWITCH_LOG")
assert_contains "use still calls gh auth switch even though gh already agrees" "$switch_log" "octo-work"

# ============================================ 17. M5: cold remove vs a live process ==
echo "17. codex remove refuses while a running process holds that CODEX_HOME open"
S=$(sandbox)
export HOME="$S/home" SWAPKIN_DIR="$S/data" XDG_CONFIG_HOME="$S/config" \
       XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" PATH="$STUBS:$PATH"
mkdir -p "$S/codex-home-busy" "$S/codex-home-current"
mkdir -p "$SWAPKIN_DIR/providers/codex/busy" "$SWAPKIN_DIR/providers/codex/current"
jq -n --arg h "$S/codex-home-busy" '{home:$h}' > "$SWAPKIN_DIR/providers/codex/busy/codex.json"
jq -n '{colour:"#7fa7d9"}' > "$SWAPKIN_DIR/providers/codex/busy/meta.json"
jq -n --arg h "$S/codex-home-current" '{home:$h}' > "$SWAPKIN_DIR/providers/codex/current/codex.json"
jq -n '{colour:"#d97757"}' > "$SWAPKIN_DIR/providers/codex/current/meta.json"
echo current > "$SWAPKIN_DIR/providers/codex/active"

CODEX_HOME="$S/codex-home-busy" sleep 30 &
BUSY_PID=$!
sleep 0.3

out=$("$SWAPKIN" -p codex remove busy 2>&1); rc=$?
echo "$out" >> "$ALL_OUTPUT_LOG"
assert_true [ "$rc" -ne 0 ]
assert_contains "remove refuses while a running process still holds that CODEX_HOME" "$out" "in use"
assert_true [ -d "$SWAPKIN_DIR/providers/codex/busy" ]

kill "$BUSY_PID" 2>/dev/null; wait "$BUSY_PID" 2>/dev/null

out2=$("$SWAPKIN" -p codex remove busy 2>&1); rc2=$?
echo "$out2" >> "$ALL_OUTPUT_LOG"
assert_eq "remove succeeds once no process holds that CODEX_HOME any more" 0 "$rc2"

# ==================================== 18. M7: watchdog auto-switch takes the lock ==
echo "18. the watchdog's auto-switch waits for \$ACCOUNTS/.lock instead of racing a concurrent use"
S=$(sandbox)
export HOME="$S/home" SWAPKIN_DIR="$S/data" CLAUDE_CONFIG_DIR="$S/home/.claude" \
       XDG_CONFIG_HOME="$S/config" XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" \
       PATH="$STUBS:$PATH" SWAPKIN_DEMO=0
mkdir -p "$CLAUDE_CONFIG_DIR"
jq -n '{claudeAiOauth:{refreshToken:"'"$(printf 'x%.0s' {1..40})"'", subscriptionType:"max"}}' > "$CLAUDE_CONFIG_DIR/.credentials.json"
jq -n '{theme:"dark"}' > "$CLAUDE_CONFIG_DIR/.claude.json"
mkdir -p "$SWAPKIN_DIR/spent" "$SWAPKIN_DIR/roomy"
echo '{"refreshToken":"'"$(printf 'x%.0s' {1..40})"'","subscriptionType":"max"}' > "$SWAPKIN_DIR/spent/oauth.json"
echo '{}' > "$SWAPKIN_DIR/spent/account.json"
jq -n '{colour:"#7fa7d9"}' > "$SWAPKIN_DIR/spent/meta.json"
jq -n '{limits:[{label:"Weekly",percent:1.0}]}' > "$SWAPKIN_DIR/spent/usage.json"
echo '{"refreshToken":"'"$(printf 'y%.0s' {1..40})"'","subscriptionType":"max"}' > "$SWAPKIN_DIR/roomy/oauth.json"
echo '{}' > "$SWAPKIN_DIR/roomy/account.json"
jq -n '{colour:"#d97757"}' > "$SWAPKIN_DIR/roomy/meta.json"
jq -n '{limits:[{label:"Weekly",percent:0.1}]}' > "$SWAPKIN_DIR/roomy/usage.json"
echo spent > "$SWAPKIN_DIR/active"
jq -n '{autoSwitch:true, alertAt:90}' > "$SWAPKIN_DIR/config.json"
# No omarchy-agent-usage-claude stub on PATH: cmd_usage's probe finds nothing
# to run and leaves the usage.json files above exactly as seeded.

( exec 9>"$SWAPKIN_DIR/.lock"; flock 9; sleep 3 ) &
LOCK_PID=$!
sleep 0.3

start=$(date +%s)
out=$(sk "$SWAPKIN" check)
elapsed=$(( $(date +%s) - start ))
wait "$LOCK_PID" 2>/dev/null

assert_true [ "$elapsed" -ge 2 ]
assert_eq "auto-switch only lands once the lock is free" "roomy" "$(cat "$SWAPKIN_DIR/active")"

# ============== 20. custom defaultHome must resolve under $HOME, symlinks followed ==
echo "20. a custom defaultHome that resolves outside \$HOME is refused; one symlinked inside \$HOME is fine"
# Custom providers are cold-only, and a cold provider never writes to
# defaultHome: swapkin resolves it once, stores the string in custom.json and
# hands it to the tool through homeEnv. There is no check-then-write on that
# path left to race, so this is not a TOCTOU test. What it does pin is the
# weaker, real property: the check follows symlinks (readlink -f -m), so an
# ancestor pointing outside $HOME is refused rather than stored, and a
# dotfile directory symlinked to somewhere else inside $HOME is accepted.
S=$(sandbox)
export HOME="$S/home" SWAPKIN_DIR="$S/data" XDG_CONFIG_HOME="$S/config" \
       XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" PATH="$STUBS:$PATH"
mkdir -p "$XDG_CONFIG_HOME/swapkin"
cat > "$XDG_CONFIG_HOME/swapkin/providers.json" <<JSON
{"providers":[{"id":"acme","name":"Acme CLI","command":"acme","mode":"cold","homeEnv":"ACME_HOME","defaultHome":"~/.acme/home"}]}
JSON
chmod 600 "$XDG_CONFIG_HOME/swapkin/providers.json"

# ~/.acme (an ancestor of defaultHome, not the leaf) points outside $HOME.
OUTSIDE="$S/outside-home"
mkdir -p "$OUTSIDE/home"
ln -s "$OUTSIDE" "$HOME/.acme"
out=$("$SWAPKIN" -p acme add mallory 2>&1); rc=$?
echo "$out" >> "$ALL_OUTPUT_LOG"
assert_true [ "$rc" -ne 0 ]
assert_contains "a defaultHome resolving outside \$HOME is refused" "$out" "must resolve under \$HOME"
assert_true [ ! -e "$SWAPKIN_DIR/providers/acme/mallory" ]

# The same ancestor symlinked to a directory inside $HOME is a normal
# dotfiles setup, and is accepted with the resolved path stored.
rm -f "$HOME/.acme"
mkdir -p "$HOME/dotfiles/acme/home"
ln -s "$HOME/dotfiles/acme" "$HOME/.acme"
out=$(sk "$SWAPKIN" -p acme add work)
assert_contains "a defaultHome symlinked inside \$HOME is accepted" "$out" "Saved the current Acme CLI login as 'work'."
stored=$(jq -r '.home' "$SWAPKIN_DIR/providers/acme/work/custom.json" 2>/dev/null)
assert_eq "the stored home is the resolved path" "$(readlink -f "$HOME")/dotfiles/acme/home" "$stored"

# ====================== 21. custom hot mode / loginFiles are refused, nothing written ==
echo "21. a custom provider asking for hot mode or loginFiles is refused before anything is written"
S=$(sandbox)
export HOME="$S/home" SWAPKIN_DIR="$S/data" XDG_CONFIG_HOME="$S/config" \
       XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" PATH="$STUBS:$PATH"
# Installed stubs, so that without the refusal both would be listed.
mk_stub acmehot 'exit 0'
mk_stub acmelegacy 'exit 0'
mkdir -p "$XDG_CONFIG_HOME/swapkin" "$HOME/.acmehot"
cat > "$XDG_CONFIG_HOME/swapkin/providers.json" <<JSON
{"providers":[
 {"id":"acmehot","name":"Acme Hot","command":"acmehot","mode":"hot","loginFiles":["~/.acmehot/session.json"]},
 {"id":"acmelegacy","name":"Acme Legacy","command":"acmelegacy","mode":"cold","homeEnv":"ACME_LEGACY_HOME","defaultHome":"~/.acmelegacy","loginFiles":["~/.acmelegacy/session.json"]}
]}
JSON
chmod 600 "$XDG_CONFIG_HOME/swapkin/providers.json"
echo '{"session":"hot-live"}' > "$HOME/.acmehot/session.json"

out=$("$SWAPKIN" providers --json 2>"$S/stderr.log")
err=$(cat "$S/stderr.log")
echo "$out" >> "$ALL_OUTPUT_LOG"; echo "$err" >> "$ALL_OUTPUT_LOG"
assert_contains "providers --json warns about the hot entry" "$err" "swapkin: ignoring custom provider 'acmehot' (custom providers are cold-only"
assert_contains "providers --json warns about the loginFiles entry" "$err" "swapkin: ignoring custom provider 'acmelegacy' (custom providers are cold-only"
assert_not_contains "the hot entry is not listed" "$out" '"id":"acmehot"'
assert_not_contains "the loginFiles entry is not listed" "$out" '"id":"acmelegacy"'

for id in acmehot acmelegacy; do
  out=$("$SWAPKIN" -p "$id" add work 2>&1); rc=$?
  echo "$out" >> "$ALL_OUTPUT_LOG"
  assert_true [ "$rc" -ne 0 ]
  assert_contains "$id add is refused with the cold-only message" "$out" "custom providers are cold-only"
  assert_true [ ! -e "$SWAPKIN_DIR/providers/$id" ]
done
assert_eq "the live login file is untouched" '{"session":"hot-live"}' "$(cat "$HOME/.acmehot/session.json")"

# ========================================= 22. sync scan caps a hostile folder ==
echo "22. the optional sync scan skips oversized files and caps file count and total bytes"
# The script is extracted from Main.qml as text, never hand-copied, so this
# test tracks the real source and goes red on drift.
SYNC_SCRIPT=$(node -e '
const fs = require("fs");
const src = fs.readFileSync(process.argv[1], "utf8");
const m = src.match(/var script = "((?:[^"\\]|\\.)*)"/);
if (!m) { process.exit(1); }
process.stdout.write(JSON.parse("\"" + m[1] + "\""));
' "$ROOT/Main.qml")
if [[ -z "$SYNC_SCRIPT" ]]; then
  bad "extracted the sync scan script from Main.qml's startSyncScan()"
else
  ok "extracted the sync scan script from Main.qml's startSyncScan()"

  SYNC_DIR=$(mktemp -d)
  # Two valid, real-sized snapshots.
  echo '{"providers":{"acme":{"days":{"2026-09-27":{"model-a":1}}}}}' > "$SYNC_DIR/work.json"
  echo '{"providers":{"orbit":{"days":{"2026-09-27":{"model-b":2}}}}}' > "$SYNC_DIR/personal.json"
  # One hostile file, bigger than the per-file cap (256 KiB).
  python3 -c "print('{\"providers\":{\"evil\":\"' + 'A' * 400000 + '\"}}')" > "$SYNC_DIR/huge.json"
  # More files than the file-count cap (32): 40 small, same-content files.
  for i in $(seq 1 40); do
    echo "{\"providers\":{\"peer$i\":{\"days\":{}}}}" > "$SYNC_DIR/peer$i.json"
  done
  touch -d "2020-01-01" "$SYNC_DIR"/peer*.json

  sync_out=$(bash -c "$SYNC_SCRIPT" "$SYNC_DIR")

  block_count=$(grep -c "^=== EOM ===$" <<<"$sync_out")
  total_bytes=$(printf '%s' "$sync_out" | wc -c)

  assert_not_contains "the oversized file's content is not in stdout" "$sync_out" "AAAAAAAAAA"
  assert_contains "a valid file still parses (path marker present)" "$sync_out" "===$SYNC_DIR/work.json==="
  assert_contains "a valid file's body survived" "$sync_out" '"model-a":1'
  assert_true [ "$block_count" -le 32 ]
  assert_true [ "$total_bytes" -le 2097152 ]

  # Same-content valid blocks JSON.parse cleanly with the app's own split logic.
  parse_ok=$(node -e '
    const fs = require("fs");
    const text = fs.readFileSync(process.argv[1], "utf8");
    const lines = text.split("\n");
    let path = "", buf = [], parsed = 0;
    function flush() {
      if (path === "") return;
      try {
        const j = JSON.parse(buf.join("\n").trim());
        if (j && j.providers) parsed++;
      } catch (e) {}
      path = ""; buf = [];
    }
    for (const line of lines) {
      const m = line.match(/^===(.*)===$/);
      if (m && m[1] !== " EOM ") { flush(); path = m[1]; continue; }
      if (line === "=== EOM ===") { flush(); continue; }
      if (path !== "") buf.push(line);
    }
    flush();
    process.stdout.write(String(parsed));
  ' <(printf '%s' "$sync_out"))
  assert_true [ "$parse_ok" -ge 2 ]

  rm -rf "$SYNC_DIR"
fi

# ================================ 23. add prompts for a name when none is given ==
echo "23. add with no name prompts for one (the panel's add button passes none)"
S=$(sandbox)
export HOME="$S/home" SWAPKIN_DIR="$S/data" XDG_CONFIG_HOME="$S/config" \
       XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" PATH="$STUBS:$PATH"
mkdir -p "$S/codex-home"
mk_stub codex "
case \"\$1 \$2\" in
  'login status') echo 'Logged in using ChatGPT'; exit 0 ;;
esac
"
out=$(printf 'prompted\n' | CODEX_HOME="$S/codex-home" "$SWAPKIN" -p codex add 2>&1); rc=$?
echo "$out" >> "$ALL_OUTPUT_LOG"
assert_eq "codex add with the name typed at the prompt exits 0" 0 "$rc"
assert_true test -f "$SWAPKIN_DIR/providers/codex/prompted/codex.json"
assert_contains "the prompt asks for an account name" "$out" "Name for this account"

out2=$(printf '\n' | CODEX_HOME="$S/codex-home" "$SWAPKIN" -p codex add 2>&1); rc2=$?
echo "$out2" >> "$ALL_OUTPUT_LOG"
assert_true [ "$rc2" -ne 0 ]
assert_contains "an empty answer still fails with the usage line" "$out2" "usage: swapkin -p codex add <name>"

# A fresh data dir, so this is a first account again rather than a sign-in.
out4=$(printf 'nonewline' | SWAPKIN_DIR="$S/data-eof" CODEX_HOME="$S/codex-home" "$SWAPKIN" -p codex add 2>&1); rc4=$?
echo "$out4" >> "$ALL_OUTPUT_LOG"
assert_eq "a name ending at EOF without a newline is kept" 0 "$rc4"
assert_true test -f "$S/data-eof/providers/codex/nonewline/codex.json"

# A caller that keeps stdin open without writing must not hang the prompt,
# which runs under the switch lock.
start=$SECONDS
out3=$(SWAPKIN_PROMPT_TIMEOUT=1 CODEX_HOME="$S/codex-home" "$SWAPKIN" -p codex add 2>&1 < <(sleep 8 2>/dev/null)); rc3=$?
echo "$out3" >> "$ALL_OUTPUT_LOG"
assert_true [ "$rc3" -ne 0 ]
assert_true [ $(( SECONDS - start )) -lt 5 ]
assert_contains "a silent stdin times out into the usage line" "$out3" "usage: swapkin -p codex add <name>"

# ======================================= 24. link puts swapkin on PATH safely ==
echo "24. link symlinks swapkin into ~/.local/bin without clobbering anything foreign"
S=$(sandbox)
export HOME="$S/home" SWAPKIN_DIR="$S/data" XDG_CONFIG_HOME="$S/config" \
       XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" PATH="$STUBS:$PATH"
BIN="$HOME/.local/bin"
out=$("$SWAPKIN" link 2>&1); rc=$?
echo "$out" >> "$ALL_OUTPUT_LOG"
assert_eq "link exits 0 when ~/.local/bin/swapkin is absent" 0 "$rc"
assert_eq "link points ~/.local/bin/swapkin at this swapkin" "$(readlink -f "$SWAPKIN")" "$(readlink -f "$BIN/swapkin" 2>/dev/null)"

"$SWAPKIN" link >/dev/null 2>&1; rc=$?
assert_eq "link is idempotent" 0 "$rc"

mkdir -p "$S/old-plugin/bin"
ln -sfn "$S/old-plugin/bin/swapkin" "$BIN/swapkin"
"$SWAPKIN" link >/dev/null 2>&1
assert_eq "a stale link to another swapkin is repointed here" "$(readlink -f "$SWAPKIN")" "$(readlink -f "$BIN/swapkin" 2>/dev/null)"

mkdir -p "$S/alias"; ln -sfn "$(dirname "$(readlink -f "$SWAPKIN")")" "$S/alias/bin"
ln -sfn "$S/alias/bin/swapkin" "$BIN/swapkin"
out=$("$SWAPKIN" link 2>&1); rc=$?
echo "$out" >> "$ALL_OUTPUT_LOG"
assert_eq "a link that already resolves here through another path exits 0" 0 "$rc"
assert_not_contains "and stays quiet about it" "$out" "not touching"

mkdir -p "$S/dev-checkout/bin"
printf '#!/bin/sh\necho dev\n' > "$S/dev-checkout/bin/swapkin"; chmod +x "$S/dev-checkout/bin/swapkin"
ln -sfn "$S/dev-checkout/bin/swapkin" "$BIN/swapkin"
out=$("$SWAPKIN" link 2>&1); rc=$?
echo "$out" >> "$ALL_OUTPUT_LOG"
assert_eq "a live link to another swapkin copy still exits 0" 0 "$rc"
assert_eq "a live link to another swapkin copy is left alone" "$S/dev-checkout/bin/swapkin" "$(readlink "$BIN/swapkin")"
assert_contains "and link says it left the other copy alone" "$out" "not touching"

ln -sfn /usr/bin/true "$BIN/swapkin"
out=$("$SWAPKIN" link 2>&1); rc=$?
echo "$out" >> "$ALL_OUTPUT_LOG"
assert_eq "a link to some other program still exits 0" 0 "$rc"
assert_eq "a link to some other program is left alone" "/usr/bin/true" "$(readlink "$BIN/swapkin")"

rm -f "$BIN/swapkin"; printf '#!/bin/sh\necho mine\n' > "$BIN/swapkin"
out=$("$SWAPKIN" link 2>&1); rc=$?
echo "$out" >> "$ALL_OUTPUT_LOG"
assert_eq "a regular file still exits 0" 0 "$rc"
assert_contains "a regular file is left alone" "$(cat "$BIN/swapkin")" "echo mine"
assert_contains "and link says why it did nothing" "$out" "not touching"

# ================== 25-31. codex switches in place: ~/.codex/auth.json follows ==
# Fake logins only: an id_token is base64url(header).base64url(claims).sig with
# made-up claims, and every refresh token is a fixture string that section 19
# checks never reaches captured output.
b64url() { printf '%s' "$1" | base64 -w0 | tr '+/' '-_' | tr -d '='; }
fake_codex_auth() { # file user_id account_id plan refresh_token
  local claims jwt
  claims=$(jq -cn --arg u "$2" --arg a "$3" --arg p "$4" \
    '{"https://api.openai.com/auth":{chatgpt_user_id:$u, chatgpt_account_id:$a, chatgpt_plan_type:$p}}')
  jwt="$(b64url '{"alg":"none","typ":"JWT"}').$(b64url "$claims").fakesig"
  mkdir -p "$(dirname "$1")"
  jq -n --arg j "$jwt" --arg a "$3" --arg r "$5" \
    '{auth_mode:"chatgpt", OPENAI_API_KEY:null, tokens:{id_token:$j, access_token:"fake-access", refresh_token:$r, account_id:$a}, last_refresh:"2026-09-01T00:00:00Z"}' > "$1"
  chmod 600 "$1"
}
# The identity swapkin must see: the chatgpt_user_id claim of the id_token.
codex_user_of() { # auth.json
  local body; body=$(jq -r '.tokens.id_token' "$1" 2>/dev/null | cut -d. -f2 | tr '_-' '/+')
  while (( ${#body} % 4 )); do body+="="; done
  base64 -d <<<"$body" 2>/dev/null | jq -r '."https://api.openai.com/auth".chatgpt_user_id // empty' 2>/dev/null
}
refresh_of() { jq -r '.tokens.refresh_token' "$1" 2>/dev/null; }
sum_of() { md5sum "$1" 2>/dev/null | cut -d' ' -f1; }
# Like sk, but keeps swapkin's own exit status in rc (sk returns printf's).
sk_rc() { out=$("$@" 2>&1); rc=$?; echo "$out" >> "$ALL_OUTPUT_LOG"; }
CODEX_A_OLD="codex-refresh-A-old-DDDDDDDDDDDDDDDDDDDDDDDDDDDD"
CODEX_A_ROTATED="codex-refresh-A-rotated-EEEEEEEEEEEEEEEEEEEEEEEE"
CODEX_B_TOKEN="codex-refresh-B-FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"
CODEX_B_ROTATED="codex-refresh-B-rotated-GGGGGGGGGGGGGGGGGGGGGGGG"
CODEX_C_TOKEN="codex-refresh-C-HHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHH"
CODEX_Z_TOKEN="codex-refresh-Z-IIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII"
CODEX_WS1_TOKEN="codex-refresh-ws1-JJJJJJJJJJJJJJJJJJJJJJJJJJJJJJ"
CODEX_WS2_TOKEN="codex-refresh-ws2-KKKKKKKKKKKKKKKKKKKKKKKKKKKKKK"
CODEX_WS2_ROTATED="codex-refresh-ws2-rotated-LLLLLLLLLLLLLLLLLLLLLL"
CODEX_WS2_RACE="codex-refresh-ws2-race-MMMMMMMMMMMMMMMMMMMMMMMMM"
CODEX_Q_TOKEN="codex-refresh-Q-NNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNN"
CODEX_API_KEY="fake-sk-codex-api-key-OOOOOOOOOOOOOOOOOOOOOOOO"

echo "25. codex use migrates a legacy layout into per-account stores and swaps ~/.codex/auth.json"
S=$(sandbox)
export HOME="$S/home" SWAPKIN_DIR="$S/data" XDG_CONFIG_HOME="$S/config" \
       XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" PATH="$STUBS:$PATH"
unset CODEX_HOME
mk_stub pgrep 'exit 1'
mk_stub codex 'exit 0'
CX="$SWAPKIN_DIR/providers/codex"
LIVE_AUTH="$HOME/.codex/auth.json"
fake_codex_auth "$LIVE_AUTH" user-A acct-A plus "$CODEX_A_OLD"
fake_codex_auth "$CX/codex02/home/auth.json" user-B acct-B pro "$CODEX_B_TOKEN"
mkdir -p "$CX/work"
jq -n --arg h "$HOME/.codex" '{home:$h}' > "$CX/work/codex.json"
jq -n '{colour:"#7fa7d9"}' > "$CX/work/meta.json"
jq -n --arg h "$CX/codex02/home" '{home:$h}' > "$CX/codex02/codex.json"
jq -n '{colour:"#d97757"}' > "$CX/codex02/meta.json"
echo work > "$CX/active"

sk_rc "$SWAPKIN" -p codex use codex02
assert_eq "use codex02 exits 0" 0 "$rc"
assert_eq "work's store was migrated from the live login" user-A "$(codex_user_of "$CX/work/auth.json")"
assert_eq "codex02's store was migrated from its own home" user-B "$(codex_user_of "$CX/codex02/auth.json")"
assert_eq "the live auth.json now holds codex02's login" user-B "$(codex_user_of "$LIVE_AUTH")"
assert_eq "active pointer is codex02" codex02 "$(cat "$CX/active")"
assert_eq "the live auth.json is mode 600" 600 "$(stat -c %a "$LIVE_AUTH")"
assert_eq "work's store is mode 600" 600 "$(stat -c %a "$CX/work/auth.json")"
assert_eq "codex02's store is mode 600" 600 "$(stat -c %a "$CX/codex02/auth.json")"
assert_true test -f "$CX/codex02/home/auth.json"
assert_contains "use says new sessions and monitors follow" "$out" "codex02"

sums_before="$(sum_of "$CX/work/auth.json") $(sum_of "$CX/codex02/auth.json") $(sum_of "$LIVE_AUTH")"
sk "$SWAPKIN" -p codex use codex02 >/dev/null
sums_after="$(sum_of "$CX/work/auth.json") $(sum_of "$CX/codex02/auth.json") $(sum_of "$LIVE_AUTH")"
assert_eq "a second use changes nothing" "$sums_before" "$sums_after"

echo "26. switching back saves the rotated live login and restores the other account"
# Codex refreshed while codex02 was live: the refresh token rotated in place.
fake_codex_auth "$LIVE_AUTH" user-B acct-B pro "$CODEX_B_ROTATED"
# A later change to a legacy home must not be migrated again over a store.
fake_codex_auth "$CX/codex02/home/auth.json" user-Z acct-Z pro "$CODEX_Z_TOKEN"
sk_rc "$SWAPKIN" -p codex use work
assert_eq "use work exits 0" 0 "$rc"
assert_eq "the live auth.json is back on work" user-A "$(codex_user_of "$LIVE_AUTH")"
assert_eq "codex02's store kept the rotated refresh token" "$CODEX_B_ROTATED" "$(refresh_of "$CX/codex02/auth.json")"
assert_eq "codex02's store was not re-migrated from its legacy home" user-B "$(codex_user_of "$CX/codex02/auth.json")"
assert_eq "active pointer is work" work "$(cat "$CX/active")"

echo "27. use codex02 saves work's rotated login back and warns about running sessions"
fake_codex_auth "$LIVE_AUTH" user-A acct-A plus "$CODEX_A_ROTATED"
mk_stub pgrep 'echo 4242'
sk_rc "$SWAPKIN" -p codex use codex02
mk_stub pgrep 'exit 1'
assert_eq "use codex02 exits 0" 0 "$rc"
assert_eq "work's store holds its latest live refresh token" "$CODEX_A_ROTATED" "$(refresh_of "$CX/work/auth.json")"
assert_eq "the live auth.json holds codex02 again" "$CODEX_B_ROTATED" "$(refresh_of "$LIVE_AUTH")"
assert_eq "the live auth.json is still mode 600" 600 "$(stat -c %a "$LIVE_AUTH")"
assert_contains "running Codex sessions are told to restart" "$out" "restart"

echo "28. an unknown live login is never overwritten"
fake_codex_auth "$LIVE_AUTH" user-C acct-C plus "$CODEX_C_TOKEN"
sums_before="$(sum_of "$CX/work/auth.json") $(sum_of "$CX/codex02/auth.json") $(sum_of "$LIVE_AUTH") $(cat "$CX/active")"
sk_rc "$SWAPKIN" -p codex use work
sums_after="$(sum_of "$CX/work/auth.json") $(sum_of "$CX/codex02/auth.json") $(sum_of "$LIVE_AUTH") $(cat "$CX/active")"
assert_true [ "$rc" -ne 0 ]
assert_eq "live, stores and active are unchanged" "$sums_before" "$sums_after"
assert_contains "the refusal says how to save that login first" "$out" "swapkin -p codex add <name>"
fake_codex_auth "$LIVE_AUTH" user-B acct-B pro "$CODEX_B_ROTATED"

echo "29. codex usage attributes each rollout to the account that wrote it"
rollout() { # file user used_percent_5h account
  mkdir -p "$(dirname "$1")"
  # An empty user or account leaves that creator field out, as older codex did.
  jq -cn --arg u "$2" --arg a "$4" '{type:"session_meta", payload:({id:"s"}
    + (if $u == "" then {} else {creator_user_id:$u} end)
    + (if $a == "" then {} else {creator_account_id:$a} end))}' > "$1"
  jq -cn --argjson p "$3" '{type:"event_msg", payload:{rate_limits:{primary:{used_percent:$p, window_minutes:300, resets_at:1790000000}}}}' >> "$1"
}
SESS="$HOME/.codex/sessions/2026/09/28"
rollout "$SESS/rollout-2026-09-28T10-00-00-a.jsonl" user-A 11 acct-A
rollout "$SESS/rollout-2026-09-28T11-00-00-b.jsonl" user-B 77 acct-B
rollout "$CX/codex02/home/sessions/2026/09/20/rollout-2026-09-20T09-00-00-b.jsonl" user-B 5 acct-B
# The newest file of all belongs to nobody saved here; it must not be used.
rollout "$SESS/rollout-2026-09-28T12-00-00-c.jsonl" user-C 99 acct-C
touch -d '2026-09-20 09:00' "$CX/codex02/home/sessions/2026/09/20/rollout-2026-09-20T09-00-00-b.jsonl"
touch -d '2026-09-28 10:00' "$SESS/rollout-2026-09-28T10-00-00-a.jsonl"
touch -d '2026-09-28 11:00' "$SESS/rollout-2026-09-28T11-00-00-b.jsonl"
touch -d '2026-09-28 12:00' "$SESS/rollout-2026-09-28T12-00-00-c.jsonl"
sk "$SWAPKIN" -p codex usage >/dev/null
assert_eq "work's usage comes from work's own rollout" 0.11 "$(jq -r '.limits[0].percent' "$CX/work/usage.json" 2>/dev/null)"
assert_eq "codex02's usage comes from its newest own rollout" 0.77 "$(jq -r '.limits[0].percent' "$CX/codex02/usage.json" 2>/dev/null)"
assert_eq "work's plan is read from its store's id_token" plus "$(jq -r '.tierLabel' "$CX/work/usage.json" 2>/dev/null)"
assert_eq "codex02's plan is read from its store's id_token" pro "$(jq -r '.tierLabel' "$CX/codex02/usage.json" 2>/dev/null)"

echo "30. env codex no longer points a migrated account at its legacy home"
out=$(sk "$SWAPKIN" env codex)
assert_not_contains "env codex does not export codex02's legacy home" "$out" "$CX/codex02/home"
assert_not_contains "env codex exports no CODEX_HOME for a migrated account" "$out" "CODEX_HOME"

echo "31. with no live auth.json (keyring or signed out) use stays pointer-only and says why"
S=$(sandbox)
export HOME="$S/home" SWAPKIN_DIR="$S/data" XDG_CONFIG_HOME="$S/config" \
       XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" PATH="$STUBS:$PATH"
mk_stub codex "
case \"\$1 \$2\" in
  'login status') echo 'Logged in using ChatGPT'; exit 0 ;;
esac
"
CX="$SWAPKIN_DIR/providers/codex"
mkdir -p "$CX/work" "$CX/codex02" "$HOME/.codex"
jq -n --arg h "$HOME/.codex" '{home:$h}' > "$CX/work/codex.json"
jq -n --arg h "$S/codex02-home" '{home:$h}' > "$CX/codex02/codex.json"
echo work > "$CX/active"
sk_rc "$SWAPKIN" -p codex use codex02
assert_eq "pointer-only use exits 0" 0 "$rc"
assert_eq "active pointer is codex02" codex02 "$(cat "$CX/active")"
assert_true test ! -e "$HOME/.codex/auth.json"
assert_contains "use says why ~/.codex cannot follow" "$out" "no auth.json"

echo "32. two workspaces of one ChatGPT user are told apart by account id"
S=$(sandbox)
export HOME="$S/home" SWAPKIN_DIR="$S/data" XDG_CONFIG_HOME="$S/config" \
       XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" PATH="$STUBS:$PATH"
unset CODEX_HOME
mk_stub pgrep 'exit 1'
mk_stub codex 'exit 0'
CX="$SWAPKIN_DIR/providers/codex"
LIVE_AUTH="$HOME/.codex/auth.json"
mkdir -p "$CX/ws1" "$CX/ws2"
jq -n --arg h "$HOME/.codex" '{home:$h}' > "$CX/ws1/codex.json"
jq -n --arg h "$CX/ws2/home" '{home:$h}' > "$CX/ws2/codex.json"
fake_codex_auth "$CX/ws1/auth.json" user-U acct-X plus "$CODEX_WS1_TOKEN"
fake_codex_auth "$CX/ws2/auth.json" user-U acct-Y team "$CODEX_WS2_TOKEN"
# Signed in by hand to the other workspace, which then rotated its token.
fake_codex_auth "$LIVE_AUTH" user-U acct-Y team "$CODEX_WS2_ROTATED"
echo ws1 > "$CX/active"
ws1_sum=$(sum_of "$CX/ws1/auth.json")
sk_rc "$SWAPKIN" -p codex use ws2
assert_eq "use ws2 exits 0" 0 "$rc"
assert_eq "the other workspace's store is never overwritten" "$ws1_sum" "$(sum_of "$CX/ws1/auth.json")"
assert_eq "the live login was saved back to its own workspace" "$CODEX_WS2_ROTATED" "$(refresh_of "$CX/ws2/auth.json")"
assert_eq "the live auth.json holds ws2's latest login" "$CODEX_WS2_ROTATED" "$(refresh_of "$LIVE_AUTH")"
assert_eq "active pointer is ws2" ws2 "$(cat "$CX/active")"

SESS="$HOME/.codex/sessions/2026/09/28"
rollout "$SESS/rollout-2026-09-28T10-00-00-x.jsonl" user-U 10 acct-X
rollout "$SESS/rollout-2026-09-28T11-00-00-y.jsonl" user-U 60 acct-Y
touch -d '2026-09-28 10:00' "$SESS/rollout-2026-09-28T10-00-00-x.jsonl"
touch -d '2026-09-28 11:00' "$SESS/rollout-2026-09-28T11-00-00-y.jsonl"
sk "$SWAPKIN" -p codex usage >/dev/null
assert_eq "ws1's usage comes from its own workspace only" 0.1 "$(jq -r '.limits[0].percent' "$CX/ws1/usage.json" 2>/dev/null)"
assert_eq "ws2's usage comes from its own workspace only" 0.6 "$(jq -r '.limits[0].percent' "$CX/ws2/usage.json" 2>/dev/null)"

echo "33. a failed save-back aborts the switch before the live login is touched"
snapshot() { echo "$(sum_of "$CX/ws1/auth.json") $(sum_of "$CX/ws2/auth.json") $(sum_of "$LIVE_AUTH") $(cat "$CX/active")"; }
before=$(snapshot)
mk_stub chmod 'exit 1'
sk_rc "$SWAPKIN" -p codex use ws1
rm -f "$STUBS/chmod"
assert_true [ "$rc" -ne 0 ]
assert_eq "live, stores and active are unchanged after a failed copy" "$before" "$(snapshot)"
assert_eq "no temp file is left next to the store" "" "$(find "$CX/ws2" -maxdepth 1 -name 'auth.json.*')"
assert_contains "the failure says the login could not be saved" "$out" "could not save"
chmod 500 "$CX/ws2"
sk_rc "$SWAPKIN" -p codex use ws1
chmod 700 "$CX/ws2"
assert_true [ "$rc" -ne 0 ]
assert_eq "a read-only store folder changes nothing either" "$before" "$(snapshot)"

echo "34. a token refresh landing mid-switch aborts it without overwriting the new login"
REAL_MV=$(command -v mv)
RACE_MARKER="$S/race-armed"; : > "$RACE_MARKER"
fake_codex_auth "$S/race-new.json" user-U acct-Y team "$CODEX_WS2_RACE"
# Right after the save-back lands in ws2's store, a running codex refreshes.
mk_stub mv "
'$REAL_MV' \"\$@\"; rc=\$?
if [[ -f '$RACE_MARKER' && \${@: -1} == '$CX/ws2/auth.json' ]]; then
  rm -f '$RACE_MARKER'; cat '$S/race-new.json' > '$LIVE_AUTH'
fi
exit \$rc
"
ws1_sum=$(sum_of "$CX/ws1/auth.json")
sk_rc "$SWAPKIN" -p codex use ws1
rm -f "$STUBS/mv"
assert_true [ "$rc" -ne 0 ]
assert_eq "the refreshed live login is not overwritten" "$CODEX_WS2_RACE" "$(refresh_of "$LIVE_AUTH")"
assert_eq "active pointer is still ws2" ws2 "$(cat "$CX/active")"
assert_eq "ws1's store is unchanged" "$ws1_sum" "$(sum_of "$CX/ws1/auth.json")"
assert_contains "the abort says Codex refreshed its login meanwhile" "$out" "refreshed"
assert_true test ! -e "$RACE_MARKER"

echo "35. with no live auth.json, env still points the active account at its own home"
S=$(sandbox)
export HOME="$S/home" SWAPKIN_DIR="$S/data" XDG_CONFIG_HOME="$S/config" \
       XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" PATH="$STUBS:$PATH"
mk_stub codex "
case \"\$1 \$2\" in
  'login status') echo 'Logged in using ChatGPT'; exit 0 ;;
esac
"
CX="$SWAPKIN_DIR/providers/codex"
mkdir -p "$CX/work" "$CX/codex02" "$HOME/.codex"
jq -n --arg h "$HOME/.codex" '{home:$h}' > "$CX/work/codex.json"
jq -n --arg h "$S/codex02-home" '{home:$h}' > "$CX/codex02/codex.json"
fake_codex_auth "$CX/codex02/auth.json" user-B acct-B pro "$CODEX_B_TOKEN"
echo work > "$CX/active"
sk_rc "$SWAPKIN" -p codex use codex02
assert_eq "pointer-only use exits 0" 0 "$rc"
assert_contains "the pointer-only message names the ways to follow the switch" "$out" "swapkin run codex"
out=$(sk "$SWAPKIN" env codex)
assert_contains "env exports CODEX_HOME for the pointer-only switch" "$out" "export CODEX_HOME="
assert_contains "env points at codex02's own home" "$out" "$S/codex02-home"

echo "36. an inherited CODEX_HOME inside swapkin's own folder is ignored; any other is honoured"
S=$(sandbox)
export HOME="$S/home" SWAPKIN_DIR="$S/data" XDG_CONFIG_HOME="$S/config" \
       XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" PATH="$STUBS:$PATH"
mk_stub codex 'exit 0'
CX="$SWAPKIN_DIR/providers/codex"
LIVE_AUTH="$HOME/.codex/auth.json"
fake_codex_auth "$LIVE_AUTH" user-A acct-A plus "$CODEX_A_OLD"
fake_codex_auth "$CX/codex02/home/auth.json" user-B acct-B pro "$CODEX_B_TOKEN"
mkdir -p "$CX/work"
jq -n --arg h "$HOME/.codex" '{home:$h}' > "$CX/work/codex.json"
jq -n --arg h "$CX/codex02/home" '{home:$h}' > "$CX/codex02/codex.json"
echo work > "$CX/active"
legacy_sum=$(sum_of "$CX/codex02/home/auth.json")
sk_rc env CODEX_HOME="$CX/codex02/home" "$SWAPKIN" -p codex use codex02
assert_eq "use with a leftover CODEX_HOME exits 0" 0 "$rc"
assert_eq "~/.codex/auth.json followed the switch" user-B "$(codex_user_of "$LIVE_AUTH")"
assert_eq "the legacy home named by CODEX_HOME is untouched" "$legacy_sum" "$(sum_of "$CX/codex02/home/auth.json")"
out=$(sk env CODEX_HOME="$CX/codex02/home" "$SWAPKIN" env codex)
assert_not_contains "env never re-exports the leftover legacy home" "$out" "$CX/codex02/home"

fake_codex_auth "$S/elsewhere/auth.json" user-B acct-B pro "$CODEX_B_ROTATED"
home_sum=$(sum_of "$LIVE_AUTH")
sk_rc env CODEX_HOME="$S/elsewhere" "$SWAPKIN" -p codex use work
assert_eq "use with a CODEX_HOME outside swapkin exits 0" 0 "$rc"
assert_eq "that CODEX_HOME's auth.json is the one switched" user-A "$(codex_user_of "$S/elsewhere/auth.json")"
assert_eq "~/.codex is left alone then" "$home_sum" "$(sum_of "$LIVE_AUTH")"
assert_eq "codex02's store got the rotated login back" "$CODEX_B_ROTATED" "$(refresh_of "$CX/codex02/auth.json")"

echo "37. rollouts written before creator ids existed are attributed without guessing"
S=$(sandbox)
export HOME="$S/home" SWAPKIN_DIR="$S/data" XDG_CONFIG_HOME="$S/config" \
       XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" PATH="$STUBS:$PATH"
unset CODEX_HOME
mk_stub pgrep 'exit 1'
mk_stub codex 'exit 0'
CX="$SWAPKIN_DIR/providers/codex"
LIVE_AUTH="$HOME/.codex/auth.json"
fake_codex_auth "$LIVE_AUTH" user-A acct-A plus "$CODEX_A_OLD"
for acct in work ws1 ws2 solo; do mkdir -p "$CX/$acct"; done
jq -n --arg h "$HOME/.codex" '{home:$h}' > "$CX/work/codex.json"
for acct in ws1 ws2 solo; do jq -n --arg h "$CX/$acct/home" '{home:$h}' > "$CX/$acct/codex.json"; done
fake_codex_auth "$CX/work/auth.json" user-A acct-A plus "$CODEX_A_OLD"
fake_codex_auth "$CX/ws1/auth.json" user-U acct-X plus "$CODEX_WS1_TOKEN"
fake_codex_auth "$CX/ws2/auth.json" user-U acct-Y team "$CODEX_WS2_TOKEN"
fake_codex_auth "$CX/solo/auth.json" user-S acct-S pro "$CODEX_B_TOKEN"
echo work > "$CX/active"
SESS="$HOME/.codex/sessions/2026/09/28"
# Only a user id: solo is the one saved account with user-S.
rollout "$SESS/rollout-2026-09-28T10-00-00-s.jsonl" user-S 21 ""
# No creator at all, in ws1's own legacy home.
rollout "$CX/ws1/home/sessions/2026/09/20/rollout-2026-09-20T10-30-00-x.jsonl" "" 44 ""
# No creator at all, in the live home: only the live-home account (work).
rollout "$SESS/rollout-2026-09-28T11-00-00-n.jsonl" "" 33 ""
# Only a user id shared by two workspaces: nobody can claim it.
rollout "$SESS/rollout-2026-09-28T12-00-00-u.jsonl" user-U 99 ""
touch -d '2026-09-28 10:00' "$SESS/rollout-2026-09-28T10-00-00-s.jsonl"
touch -d '2026-09-28 10:30' "$CX/ws1/home/sessions/2026/09/20/rollout-2026-09-20T10-30-00-x.jsonl"
touch -d '2026-09-28 11:00' "$SESS/rollout-2026-09-28T11-00-00-n.jsonl"
touch -d '2026-09-28 12:00' "$SESS/rollout-2026-09-28T12-00-00-u.jsonl"
sk "$SWAPKIN" -p codex usage >/dev/null
pct_of() { jq -r '.limits[0].percent' "$CX/$1/usage.json" 2>/dev/null; }
assert_eq "a user-id-only rollout counts for the one account with that user" 0.21 "$(pct_of solo)"
assert_eq "a creator-less rollout in the live home counts for the live-home account" 0.33 "$(pct_of work)"
assert_eq "a creator-less rollout in a legacy home counts for that home's account" 0.44 "$(pct_of ws1)"
assert_true test ! -e "$CX/ws2/usage.json"

echo "38. a failed write into the live login is rolled back, and a failed rollback says where the login is"
BOGUS="$S/bogus.json"
fake_codex_auth "$BOGUS" user-Q acct-Q plus "$CODEX_Q_TOKEN"
REAL_MV=$(command -v mv)
MV_COUNT="$S/mv-count"
# The first move into the live file lands the wrong login; the second (the
# rollback) fails when ROLLBACK_FAILS is set.
mk_stub mv "
if [[ \${@: -1} == '$LIVE_AUTH' ]]; then
  n=\$(cat '$MV_COUNT' 2>/dev/null || echo 0); echo \$((n + 1)) > '$MV_COUNT'
  if (( n == 0 )); then '$REAL_MV' \"\$@\" && cat '$BOGUS' > '$LIVE_AUTH'; exit \$?; fi
  [[ -n \${ROLLBACK_FAILS:-} ]] && exit 1
fi
exec '$REAL_MV' \"\$@\"
"
rm -f "$MV_COUNT"
sk_rc env ROLLBACK_FAILS=1 "$SWAPKIN" -p codex use ws1
assert_true [ "$rc" -ne 0 ]
assert_contains "a failed rollback says the live file could not be restored" "$out" "could not be restored"
assert_contains "and names the saved copy to recover from" "$out" "$CX/work/auth.json"
assert_eq "active pointer is unchanged" work "$(cat "$CX/active")"
# Recover the way the message says to, then try the rollback that works.
cp "$CX/work/auth.json" "$LIVE_AUTH"
rm -f "$MV_COUNT"
sk_rc "$SWAPKIN" -p codex use ws1
rm -f "$STUBS/mv"
assert_true [ "$rc" -ne 0 ]
assert_contains "a successful rollback says the live file still holds the owner" "$out" "still holds 'work'"
assert_eq "the live login was rolled back to work" user-A "$(codex_user_of "$LIVE_AUTH")"

echo "39. API-key logins (no ChatGPT identity) fall back to a pointer-only switch"
fake_apikey_auth() { # file
  mkdir -p "$(dirname "$1")"
  jq -n --arg k "$CODEX_API_KEY" '{auth_mode:"apikey", OPENAI_API_KEY:$k, tokens:null, last_refresh:null}' > "$1"
  chmod 600 "$1"
}
S=$(sandbox)
export HOME="$S/home" SWAPKIN_DIR="$S/data" XDG_CONFIG_HOME="$S/config" \
       XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" PATH="$STUBS:$PATH"
unset CODEX_HOME
mk_stub pgrep 'exit 1'
mk_stub codex 'exit 0'
CX="$SWAPKIN_DIR/providers/codex"
LIVE_AUTH="$HOME/.codex/auth.json"
mkdir -p "$CX/work" "$CX/apikey"
jq -n --arg h "$HOME/.codex" '{home:$h}' > "$CX/work/codex.json"
jq -n --arg h "$CX/apikey/home" '{home:$h}' > "$CX/apikey/codex.json"
fake_codex_auth "$LIVE_AUTH" user-A acct-A plus "$CODEX_A_OLD"
fake_codex_auth "$CX/work/auth.json" user-A acct-A plus "$CODEX_A_OLD"
fake_apikey_auth "$CX/apikey/home/auth.json"
fake_apikey_auth "$CX/apikey/auth.json"
echo work > "$CX/active"
snap() { echo "$(sum_of "$LIVE_AUTH") $(for a in "$@"; do sum_of "$CX/$a/auth.json"; done)"; }
before=$(snap work apikey)
sk_rc "$SWAPKIN" -p codex use apikey
assert_eq "switching to an API-key login exits 0" 0 "$rc"
assert_eq "the live login and every store are untouched" "$before" "$(snap work apikey)"
assert_eq "active pointer is apikey" apikey "$(cat "$CX/active")"
assert_contains "the reason names the API-key login" "$out" "API-key login"
assert_not_contains "it never asks to sign in again" "$out" "sign in again"
assert_not_contains "it never asks to add the account" "$out" "codex add"
out=$(sk "$SWAPKIN" env codex)
assert_contains "env points the API-key account at its own home" "$out" "export CODEX_HOME=$CX/apikey/home"

S=$(sandbox)
export HOME="$S/home" SWAPKIN_DIR="$S/data" XDG_CONFIG_HOME="$S/config" \
       XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" PATH="$STUBS:$PATH"
CX="$SWAPKIN_DIR/providers/codex"
LIVE_AUTH="$HOME/.codex/auth.json"
mkdir -p "$CX/work" "$CX/codex02"
jq -n --arg h "$HOME/.codex" '{home:$h}' > "$CX/work/codex.json"
jq -n --arg h "$CX/codex02/home" '{home:$h}' > "$CX/codex02/codex.json"
fake_apikey_auth "$LIVE_AUTH"
fake_apikey_auth "$CX/work/auth.json"
fake_codex_auth "$CX/codex02/home/auth.json" user-B acct-B pro "$CODEX_B_TOKEN"
fake_codex_auth "$CX/codex02/auth.json" user-B acct-B pro "$CODEX_B_TOKEN"
echo work > "$CX/active"
before=$(snap work codex02)
sk_rc "$SWAPKIN" -p codex use codex02
assert_eq "switching away from a live API-key login exits 0" 0 "$rc"
assert_eq "the live API-key login and every store are untouched" "$before" "$(snap work codex02)"
assert_eq "active pointer is codex02" codex02 "$(cat "$CX/active")"
assert_contains "the reason says the live login has no ChatGPT identity" "$out" "no ChatGPT identity"
assert_not_contains "it never asks to add the live login" "$out" "codex add"
out=$(sk "$SWAPKIN" env codex)
assert_contains "env points codex02 at its own home" "$out" "export CODEX_HOME=$CX/codex02/home"

echo "40. a corrupt login is an error, not an API-key login"
S=$(sandbox)
export HOME="$S/home" SWAPKIN_DIR="$S/data" XDG_CONFIG_HOME="$S/config" \
       XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" PATH="$STUBS:$PATH"
unset CODEX_HOME
mk_stub pgrep 'exit 1'
mk_stub codex 'exit 0'
CX="$SWAPKIN_DIR/providers/codex"
LIVE_AUTH="$HOME/.codex/auth.json"
mkdir -p "$CX/work" "$CX/codex02"
jq -n --arg h "$HOME/.codex" '{home:$h}' > "$CX/work/codex.json"
jq -n --arg h "$CX/codex02/home" '{home:$h}' > "$CX/codex02/codex.json"
fake_codex_auth "$LIVE_AUTH" user-A acct-A plus "$CODEX_A_OLD"
fake_codex_auth "$CX/work/auth.json" user-A acct-A plus "$CODEX_A_OLD"
fake_codex_auth "$CX/codex02/home/auth.json" user-B acct-B pro "$CODEX_B_TOKEN"
printf '{"auth_mode":"chatgpt","tokens":{"id_token":"trunc' > "$CX/codex02/auth.json"
echo work > "$CX/active"
snap_all() { echo "$(snap work codex02 | tr "\n" " ")$(cat "$CX/active")"; }
before=$(snap_all)
sk_rc "$SWAPKIN" -p codex use codex02
assert_true [ "$rc" -ne 0 ]
assert_contains "a corrupt target store asks to sign in again" "$out" "'codex02' has no usable login; sign in again with: swapkin -p codex add codex02"
assert_eq "nothing changed after a corrupt target store" "$before" "$(snap_all)"

fake_codex_auth "$CX/codex02/auth.json" user-B acct-B pro "$CODEX_B_TOKEN"
printf '{"tokens":{"id_token":"trunc' > "$LIVE_AUTH"
echo work > "$CX/active"
before=$(snap_all)
sk_rc "$SWAPKIN" -p codex use codex02
assert_true [ "$rc" -ne 0 ]
assert_contains "a corrupt live file is reported" "$out" "unreadable or has no usable login"
assert_eq "nothing changed after a corrupt live file" "$before" "$(snap_all)"

echo "41. creator-less rollouts in the live home stop counting once switches go in place"
S=$(sandbox)
export HOME="$S/home" SWAPKIN_DIR="$S/data" XDG_CONFIG_HOME="$S/config" \
       XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" PATH="$STUBS:$PATH"
CX="$SWAPKIN_DIR/providers/codex"
LIVE_AUTH="$HOME/.codex/auth.json"
mkdir -p "$CX/work" "$CX/codex02"
jq -n --arg h "$HOME/.codex" '{home:$h}' > "$CX/work/codex.json"
jq -n --arg h "$CX/codex02/home" '{home:$h}' > "$CX/codex02/codex.json"
fake_codex_auth "$LIVE_AUTH" user-A acct-A plus "$CODEX_A_OLD"
fake_codex_auth "$CX/work/auth.json" user-A acct-A plus "$CODEX_A_OLD"
fake_codex_auth "$CX/codex02/auth.json" user-B acct-B pro "$CODEX_B_TOKEN"
echo work > "$CX/active"
SESS="$HOME/.codex/sessions/2026/09/28"
OLD_ROLLOUT="$SESS/rollout-old-n.jsonl"
rollout "$OLD_ROLLOUT" "" 12 ""
touch -d "@$(( $(date +%s) - 86400 ))" "$OLD_ROLLOUT"
sk "$SWAPKIN" -p codex usage >/dev/null
assert_eq "before any in-place switch a creator-less live rollout counts" 0.12 "$(jq -r '.limits[0].percent' "$CX/work/usage.json" 2>/dev/null)"
sk_rc "$SWAPKIN" -p codex use codex02
SINCE_FILE="$CX/.inplace_since"
since=$(cat "$SINCE_FILE" 2>/dev/null)
assert_true test -n "$since"
NEW_ROLLOUT="$SESS/rollout-new-n.jsonl"
rollout "$NEW_ROLLOUT" "" 88 ""
touch -d "@$(( ${since:-$(date +%s)} + 60 ))" "$NEW_ROLLOUT"
LEGACY_ROLLOUT="$CX/codex02/home/sessions/2026/09/28/rollout-legacy-n.jsonl"
rollout "$LEGACY_ROLLOUT" "" 55 ""
touch -d "@$(( ${since:-$(date +%s)} + 120 ))" "$LEGACY_ROLLOUT"
sk "$SWAPKIN" -p codex usage >/dev/null
assert_eq "a creator-less live rollout after the switch-over does not count" 0.12 "$(jq -r '.limits[0].percent' "$CX/work/usage.json" 2>/dev/null)"
assert_eq "a creator-less rollout in a separate legacy home still counts" 0.55 "$(jq -r '.limits[0].percent' "$CX/codex02/usage.json" 2>/dev/null)"
sk_rc "$SWAPKIN" -p codex use work
assert_eq "a later switch never moves the switch-over time" "$since" "$(cat "$SINCE_FILE" 2>/dev/null)"

echo "42. a busy account never pushes a quieter one's rollouts out of the scan"
S=$(sandbox)
export HOME="$S/home" SWAPKIN_DIR="$S/data" XDG_CONFIG_HOME="$S/config" \
       XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" PATH="$STUBS:$PATH"
CX="$SWAPKIN_DIR/providers/codex"
LIVE_AUTH="$HOME/.codex/auth.json"
mkdir -p "$CX/work" "$CX/codex02"
jq -n --arg h "$HOME/.codex" '{home:$h}' > "$CX/work/codex.json"
jq -n --arg h "$CX/codex02/home" '{home:$h}' > "$CX/codex02/codex.json"
fake_codex_auth "$LIVE_AUTH" user-B acct-B pro "$CODEX_B_TOKEN"
fake_codex_auth "$CX/work/auth.json" user-A acct-A plus "$CODEX_A_OLD"
fake_codex_auth "$CX/codex02/auth.json" user-B acct-B pro "$CODEX_B_TOKEN"
echo codex02 > "$CX/active"
SESS="$HOME/.codex/sessions/2026/09/28"
rollout "$SESS/rollout-quiet-a.jsonl" user-A 17 acct-A
touch -d '2026-09-01 08:00' "$SESS/rollout-quiet-a.jsonl"
base=$(date -d '2026-09-28 10:00' +%s)
for i in $(seq 1 60); do
  rollout "$SESS/rollout-busy-b-$i.jsonl" user-B 70 acct-B
  touch -d "@$(( base + i * 60 ))" "$SESS/rollout-busy-b-$i.jsonl"
done
sk "$SWAPKIN" -p codex usage >/dev/null
assert_eq "the quiet account still gets its own figure" 0.17 "$(jq -r '.limits[0].percent' "$CX/work/usage.json" 2>/dev/null)"
assert_eq "the busy account gets its own figure" 0.7 "$(jq -r '.limits[0].percent' "$CX/codex02/usage.json" 2>/dev/null)"

# ========== 43-48. opt-in auto-switch on the session (5-hour) window ==
# Every account below gets a fake 40+ character login that starts with
# SW_TOKEN_PREFIX, so the summary's leak check covers all of them at once.
# A section-local stub collector fails, so `check` keeps the seeded usage.json
# files exactly as written, and a notify-send stub records each notification.
SW_TOKEN_PREFIX="session-switch-fixture-token"
SW_STUBS="$(mktemp -d)"
cat > "$SW_STUBS/omarchy-agent-usage-claude" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
cat > "$SW_STUBS/notify-send" <<'EOF'
#!/usr/bin/env bash
# The last two arguments are the title and the body.
[[ -n ${NOTIFY_LOG:-} ]] && printf '%s | %s\n' "${@: -2:1}" "${@: -1}" >> "$NOTIFY_LOG"
exit 0
EOF
chmod +x "$SW_STUBS/omarchy-agent-usage-claude" "$SW_STUBS/notify-send"

SW_SESSION_RESET="2026-09-28T15:00:00.412345+00:00"
SW_WEEKLY_RESET="2026-10-02T09:00:00+00:00"

sw_sandbox() { # config-json
  S=$(sandbox)
  export HOME="$S/home" SWAPKIN_DIR="$S/data" CLAUDE_CONFIG_DIR="$S/home/.claude" \
         XDG_CONFIG_HOME="$S/config" XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" \
         PATH="$SW_STUBS:$STUBS:$PATH" SWAPKIN_DEMO=0 NOTIFY_LOG="$S/notify.log"
  mkdir -p "$CLAUDE_CONFIG_DIR" "$SWAPKIN_DIR"
  jq -n --arg t "$SW_TOKEN_PREFIX-live-DDDDDDDDDDDDDDDDDDDD" \
    '{claudeAiOauth:{refreshToken:$t, subscriptionType:"pro"}}' > "$CLAUDE_CONFIG_DIR/.credentials.json"
  jq -n '{theme:"dark"}' > "$CLAUDE_CONFIG_DIR/.claude.json"
  : > "$NOTIFY_LOG"
  printf '%s\n' "$1" > "$SWAPKIN_DIR/config.json"
}

# "-" leaves that window out of usage.json.
sw_account() { # name session-pct weekly-pct [session-reset]
  local dir="$SWAPKIN_DIR/$1"
  mkdir -p "$dir"
  jq -n --arg t "$SW_TOKEN_PREFIX-$1-EEEEEEEEEEEEEEEEEEEE" '{refreshToken:$t, subscriptionType:"pro"}' > "$dir/oauth.json"
  echo '{}' > "$dir/account.json"
  jq -n '{colour:"#7fa7d9"}' > "$dir/meta.json"
  jq -n --arg s "$2" --arg w "$3" --arg sr "${4-$SW_SESSION_RESET}" --arg wr "$SW_WEEKLY_RESET" '
    {limits: ([ (if $s == "-" then empty else {label:"Session (5-hour)", percent:($s|tonumber), resetsAt:$sr} end),
                (if $w == "-" then empty else {label:"Weekly (7-day)", percent:($w|tonumber), resetsAt:$wr} end) ]),
     tierLabel:"Pro"}' > "$dir/usage.json"
}

sw_check() { # runs `swapkin check`, leaves its exit code in SW_RC
  sk_rc "$SWAPKIN" check
  SW_RC=$rc
}

sw_notes() { wc -l < "$NOTIFY_LOG" | tr -d ' '; }

echo "43. by default a spent session window neither switches nor notifies"
sw_sandbox '{"autoSwitch":true,"alertAt":90}'
sw_account spent 1.0 0.2
sw_account roomy 0.1 0.1
echo spent > "$SWAPKIN_DIR/active"
sw_check
assert_eq "check exits cleanly" 0 "$SW_RC"
assert_eq "the default windows leave a spent session alone" spent "$(cat "$SWAPKIN_DIR/active")"
assert_eq "no notification for the session window by default" 0 "$(sw_notes)"

echo "44. with the session window enabled, a spent session hands over to the roomiest account"
sw_sandbox '{"autoSwitch":true,"alertAt":90,"autoSwitchWindows":["weekly","session"]}'
sw_account spent 1.0 0.2
# Weekly alone would pick 'a' (10% weekly); its session at 60% is the tighter
# window, so 'b' (30% in both) has the most room in its tightest window.
sw_account a 0.6 0.1
sw_account b 0.3 0.3
echo spent > "$SWAPKIN_DIR/active"
sw_check
assert_eq "check exits cleanly" 0 "$SW_RC"
assert_eq "switched to the account with the most room in its tightest window" b "$(cat "$SWAPKIN_DIR/active")"
notes=$(cat "$NOTIFY_LOG")
assert_contains "the notification names the new account" "$notes" "Switched to b"
assert_contains "the notification names the session window" "$notes" "spent hit its 5-hour limit"
assert_not_contains "the notification does not blame the week" "$notes" "weekly quota"

echo "45. a candidate with a spent session is skipped; with no room anywhere nothing switches"
sw_sandbox '{"autoSwitch":true,"alertAt":90,"autoSwitchWindows":["weekly","session"]}'
sw_account spent 1.0 0.2
sw_account a-nosession 1.0 0.0
sw_account z-room 0.5 0.5
echo spent > "$SWAPKIN_DIR/active"
sw_check
assert_eq "check exits cleanly" 0 "$SW_RC"
assert_eq "an account with a spent session is never the candidate" z-room "$(cat "$SWAPKIN_DIR/active")"

sw_sandbox '{"autoSwitch":true,"alertAt":90,"autoSwitchWindows":["weekly","session"]}'
sw_account spent 1.0 0.2
sw_account other1 1.0 0.1
sw_account other2 0.2 1.0
echo spent > "$SWAPKIN_DIR/active"
sw_check
assert_eq "check exits cleanly" 0 "$SW_RC"
assert_eq "no switch when every candidate has a spent window" spent "$(cat "$SWAPKIN_DIR/active")"
notes=$(cat "$NOTIFY_LOG")
assert_contains "the warning names the session window" "$notes" "spent is at 100% of its 5-hour window"
assert_contains "the warning says no account has room" "$notes" "No other account has room right now."

echo "46. autoSwitchAt 95 hands over at 95% session usage, not before"
sw_sandbox '{"autoSwitch":true,"alertAt":90,"autoSwitchAt":95,"autoSwitchWindows":["session"]}'
sw_account spent 0.94 0.2
sw_account roomy 0.1 0.1
echo spent > "$SWAPKIN_DIR/active"
sw_check
assert_eq "check exits cleanly" 0 "$SW_RC"
assert_eq "94% is below autoSwitchAt: no switch" spent "$(cat "$SWAPKIN_DIR/active")"
assert_contains "94% is above alertAt: a warning names the account with room" "$(cat "$NOTIFY_LOG")" "roomy has 90% free"
sw_account spent 0.95 0.2
sw_check
assert_eq "95% reaches autoSwitchAt: switched" roomy "$(cat "$SWAPKIN_DIR/active")"

echo "47. the session warning fires once per session reset"
sw_sandbox '{"autoSwitch":false,"alertAt":90,"autoSwitchWindows":["weekly","session"]}'
sw_account spent 0.92 0.2 "2026-09-28T14:59:59.912345+00:00"
sw_account roomy 0.1 0.1
echo spent > "$SWAPKIN_DIR/active"
sw_check
assert_eq "check exits cleanly" 0 "$SW_RC"
assert_eq "one session warning" 1 "$(sw_notes)"
assert_contains "the warning names the session window" "$(cat "$NOTIFY_LOG")" "spent is at 92% of its 5-hour window"
sw_check
assert_eq "no second warning on the next check" 1 "$(sw_notes)"
# The endpoint restamps the reset with sub-second jitter; the same window must
# not count as a new one when that jitter crosses the hour.
sw_account spent 0.93 0.2 "2026-09-28T15:00:00.104567+00:00"
sw_check
assert_eq "reset jitter across the hour is the same window" 1 "$(sw_notes)"
# The next session window, later the same day.
sw_account spent 0.92 0.2 "2026-09-28T20:00:00.301234+00:00"
sw_check
assert_eq "a new session reset warns again" 2 "$(sw_notes)"
assert_eq "the weekly window stayed quiet throughout" 0 "$(grep -c 'of its week' "$NOTIFY_LOG")"

echo "48. an old-format watch.json keeps working without re-notifying"
sw_sandbox '{"autoSwitch":true,"alertAt":90}'
sw_account spent 0.5 0.93
sw_account roomy 0.1 0.1
echo spent > "$SWAPKIN_DIR/active"
# The format before per-window state: account -> weekly reset date -> stage.
jq -n --arg d "${SW_WEEKLY_RESET:0:10}" '{spent: {($d): 1}}' > "$SWAPKIN_DIR/watch.json"
sw_check
assert_eq "check exits cleanly on the old state" 0 "$SW_RC"
assert_eq "the weekly warning already sent is not sent again" 0 "$(sw_notes)"
sw_account spent 0.5 1.0
sw_check
assert_eq "a spent week still hands over from the old state" roomy "$(cat "$SWAPKIN_DIR/active")"
assert_contains "the weekly switch text is unchanged" "$(cat "$NOTIFY_LOG")" "spent ran out of weekly quota. Open sessions follow on their next message."

sw_sandbox '{"autoSwitch":false,"alertAt":90,"autoSwitchWindows":["weekly","session"]}'
sw_account spent 0.95 0.93
sw_account roomy 0.1 0.1
echo spent > "$SWAPKIN_DIR/active"
jq -n --arg d "${SW_WEEKLY_RESET:0:10}" '{spent: {($d): 1}}' > "$SWAPKIN_DIR/watch.json"
sw_check
assert_eq "check exits cleanly with the session window on the old state" 0 "$SW_RC"
assert_eq "only the new session warning is sent" 1 "$(sw_notes)"
assert_contains "and it names the session window" "$(cat "$NOTIFY_LOG")" "5-hour window"
echo '[1,2,3]' > "$SWAPKIN_DIR/watch.json"
sw_check
assert_eq "a malformed watch.json does not break check" 0 "$SW_RC"

echo "49. invalid autoSwitchWindows / autoSwitchAt fall back to the defaults"
for windows in '"session"' '[]' '["bogus"]' '{"session":true}'; do
  sw_sandbox '{"autoSwitch":true,"alertAt":90,"autoSwitchWindows":'"$windows"'}'
  sw_account spent 1.0 0.2
  sw_account roomy 0.1 0.1
  echo spent > "$SWAPKIN_DIR/active"
  sw_check
  assert_eq "autoSwitchWindows $windows exits cleanly" 0 "$SW_RC"
  assert_eq "autoSwitchWindows $windows means the weekly window alone" spent "$(cat "$SWAPKIN_DIR/active")"
done
for at in '"abc"' '150'; do
  sw_sandbox '{"autoSwitch":true,"alertAt":90,"autoSwitchAt":'"$at"',"autoSwitchWindows":["session"]}'
  sw_account spent 0.99 0.2
  sw_account roomy 0.1 0.1
  echo spent > "$SWAPKIN_DIR/active"
  sw_check
  assert_eq "autoSwitchAt $at exits cleanly" 0 "$SW_RC"
  assert_eq "autoSwitchAt $at acts as 100: 99% does not switch" spent "$(cat "$SWAPKIN_DIR/active")"
  sw_account spent 1.0 0.2
  sw_check
  assert_eq "autoSwitchAt $at acts as 100: 100% switches" roomy "$(cat "$SWAPKIN_DIR/active")"
done

echo "50. session resets are keyed to the minute, and an empty reset is a placeholder"
sw_sandbox '{"autoSwitch":false,"alertAt":90,"autoSwitchWindows":["session"]}'
sw_account roomy 0.1 0.1
echo spent > "$SWAPKIN_DIR/active"
# Real resets land on whole minutes with sub-second jitter either side.
sw_account spent 0.92 0.2 "2026-09-28T07:39:59.912345+00:00"
sw_check
assert_eq "one session warning" 1 "$(sw_notes)"
sw_account spent 0.93 0.2 "2026-09-28T07:40:00.434170+00:00"
sw_check
assert_eq "jitter across the minute keeps one window" 1 "$(sw_notes)"
sw_account spent 0.92 0.2 "2026-09-28T14:29:59.912345+00:00"
sw_check
assert_eq "a different reset is a new window" 2 "$(sw_notes)"
sw_account spent 0.93 0.2 "2026-09-28T14:30:00.104567+00:00"
sw_check
assert_eq "jitter across the half hour keeps one window" 2 "$(sw_notes)"
assert_eq "the session key is the reset rounded to the minute" '["2026-09-28T14:30"]' \
  "$(jq -c '.spent.session | keys' "$SWAPKIN_DIR/watch.json" 2>/dev/null)"

sw_sandbox '{"autoSwitch":false,"alertAt":90,"autoSwitchWindows":["session"]}'
sw_account roomy 0.1 0.1
echo spent > "$SWAPKIN_DIR/active"
sw_account spent 0.92 0.2 ""
sw_check
assert_eq "check exits cleanly with an empty reset" 0 "$SW_RC"
assert_eq "a spent window with no reset still warns" 1 "$(sw_notes)"
assert_eq "an empty reset is kept under a placeholder key" '["none"]' \
  "$(jq -c '.spent.session | keys' "$SWAPKIN_DIR/watch.json" 2>/dev/null)"
sw_check
assert_eq "no second warning while the reset stays empty" 1 "$(sw_notes)"
sw_account spent 0.92 0.2 "2026-09-28T09:20:00.366550+00:00"
sw_check
assert_eq "a real reset after the placeholder warns again" 2 "$(sw_notes)"
assert_eq "the real reset replaces the placeholder" '["2026-09-28T09:20"]' \
  "$(jq -c '.spent.session | keys' "$SWAPKIN_DIR/watch.json" 2>/dev/null)"

echo "51. while spent, every check retries the hand-over; the no-room warning is sent once"
sw_sandbox '{"autoSwitch":true,"alertAt":90,"autoSwitchWindows":["weekly","session"]}'
sw_account spent 1.0 0.2
sw_account other 1.0 0.1
echo spent > "$SWAPKIN_DIR/active"
sw_check
assert_eq "no candidate with room: no switch" spent "$(cat "$SWAPKIN_DIR/active")"
assert_eq "one no-room warning" 1 "$(grep -c 'No other account has room right now.' "$NOTIFY_LOG")"
sw_account other 0.1 0.1
sw_check
assert_eq "check exits cleanly" 0 "$SW_RC"
assert_eq "the next check hands over once a candidate has room" other "$(cat "$SWAPKIN_DIR/active")"
assert_contains "and says so" "$(cat "$NOTIFY_LOG")" "Switched to other"
assert_eq "the no-room warning is not repeated" 1 "$(grep -c 'No other account has room right now.' "$NOTIFY_LOG")"
assert_eq "nothing else was sent" 2 "$(sw_notes)"

echo "52. a blocked or failed switch sends no 'Switched' notice but still warns once"
sw_sandbox '{"autoSwitch":true,"alertAt":90}'
sw_account spent 0.2 1.0
sw_account roomy 0.1 0.1
echo spent > "$SWAPKIN_DIR/active"
# The holder keeps the switch lock for both checks and signals once it has it.
touch "$S/hold"
( exec 9>"$SWAPKIN_DIR/.lock"; flock 9; touch "$S/held"; while [[ -e $S/hold ]]; do sleep 0.1; done ) &
HOLD_PID=$!
for _ in $(seq 1 100); do [[ -e $S/held ]] && break; sleep 0.05; done
assert_true [ -e "$S/held" ]
SWAPKIN_LOCK_WAIT=1 sw_check
rc1=$SW_RC
SWAPKIN_LOCK_WAIT=1 sw_check
rm -f "$S/hold"; wait "$HOLD_PID" 2>/dev/null
assert_eq "a busy lock is not an error for the watchdog" "0 0" "$rc1 $SW_RC"
assert_eq "no switch while the lock is held" spent "$(cat "$SWAPKIN_DIR/active")"
assert_eq "no notice of a switch that did not happen" 0 "$(grep -c 'Switched to' "$NOTIFY_LOG")"
assert_eq "the spent warning is still sent, once over both checks" 1 "$(grep -c 'spent is at 100% of its week' "$NOTIFY_LOG")"
assert_eq "the new stage is saved" 2 "$(jq -r --arg d "${SW_WEEKLY_RESET:0:10}" '.spent.weekly[$d]' "$SWAPKIN_DIR/watch.json" 2>/dev/null)"
sw_check
assert_eq "the next free check retries and switches" roomy "$(cat "$SWAPKIN_DIR/active")"
assert_eq "one 'Switched' notice, for the real switch" 1 "$(grep -c 'Switched to roomy' "$NOTIFY_LOG")"

sw_sandbox '{"autoSwitch":true,"alertAt":90}'
sw_account spent 0.2 1.0
sw_account roomy 0.1 0.1
echo spent > "$SWAPKIN_DIR/active"
# A live login that cannot be read makes p_use fail on its save-back, even
# for root, before anything is switched.
rm "$CLAUDE_CONFIG_DIR/.credentials.json"
mkdir "$CLAUDE_CONFIG_DIR/.credentials.json"
sw_check
rc1=$SW_RC
sw_check
assert_true [ "$rc1" -ne 0 ]
assert_true [ "$SW_RC" -ne 0 ]
assert_eq "a failed switch leaves the active account" spent "$(cat "$SWAPKIN_DIR/active")"
assert_eq "a failed switch sends no 'Switched' notice" 0 "$(grep -c 'Switched to' "$NOTIFY_LOG")"
assert_eq "the spent warning is sent once" 1 "$(grep -c 'spent is at 100% of its week' "$NOTIFY_LOG")"
assert_eq "the failed switch is reported once, naming the target" 1 "$(grep -c 'Could not switch to roomy' "$NOTIFY_LOG")"
rmdir "$CLAUDE_CONFIG_DIR/.credentials.json"
jq -n --arg t "$SW_TOKEN_PREFIX-live-DDDDDDDDDDDDDDDDDDDD" \
  '{claudeAiOauth:{refreshToken:$t, subscriptionType:"pro"}}' > "$CLAUDE_CONFIG_DIR/.credentials.json"
sw_check
assert_eq "the next check retries and switches" roomy "$(cat "$SWAPKIN_DIR/active")"
assert_eq "one 'Switched' notice, for the real switch" 1 "$(grep -c 'Switched to roomy' "$NOTIFY_LOG")"

# ========== 53-59. opt-in Codex auto-switch (autoSwitchProviders) ==
# Codex figures come from rollouts, as in real use: every account below writes
# its rate limits into a rollout in the live ~/.codex/sessions, stamped with
# its creator ids, and `check` refreshes usage.json from them through p_probe.
# A rollout's mtime is when its figures were taken. Every refresh token starts
# with CX_SW_PREFIX, so the summary's leak check covers all of them.
CX_SW_PREFIX="codex-switch-fixture-token"

cx_sandbox() { # config-json
  sw_sandbox "$1"
  unset CODEX_HOME
  CX="$SWAPKIN_DIR/providers/codex"
  LIVE_AUTH="$HOME/.codex/auth.json"
  mkdir -p "$CX" "$HOME/.codex/sessions"
}

# A saved Codex account with its own stored login and a legacy home.
cx_account() { # name user account-id
  fake_codex_auth "$CX/$1/auth.json" "$2" "$3" plus "$CX_SW_PREFIX-$1-PPPPPPPPPPPPPPPPPPPP"
  jq -n --arg h "$CX/$1/home" '{home:$h}' > "$CX/$1/codex.json"
  jq -n '{colour:"#7fa7d9"}' > "$CX/$1/meta.json"
}

# That account's login is the live one, and it is the active account.
cx_live() { # name
  cp "$CX/$1/auth.json" "$LIVE_AUTH"
  chmod 600 "$LIVE_AUTH"
  echo "$1" > "$CX/active"
}

# One rollout with both windows; resets are offsets from now, in seconds.
cx_rollout() { # user account-id 5h-percent 5h-reset-offset weekly-percent weekly-reset-offset age-seconds
  local now f; now=$(date +%s)
  f="$HOME/.codex/sessions/rollout-$1-$2-$RANDOM$RANDOM.jsonl"
  jq -cn --arg u "$1" --arg a "$2" '{type:"session_meta", payload:{id:"s", creator_user_id:$u, creator_account_id:$a}}' > "$f"
  jq -cn --argjson p5 "$3" --argjson r5 "$((now + $4))" --argjson pw "$5" --argjson rw "$((now + $6))" \
    '{type:"event_msg", payload:{rate_limits:{plan_type:"plus",
       primary:{used_percent:$p5, window_minutes:300, resets_at:$r5},
       secondary:{used_percent:$pw, window_minutes:10080, resets_at:$rw}}}}' >> "$f"
  touch -d "@$((now - $7))" "$f"
}

cx_check() { sk_rc "$SWAPKIN" check; SW_RC=$rc; }

CX_BOTH='"autoSwitch":true,"alertAt":90,"autoSwitchWindows":["weekly","session"]'
DAY=86400

echo "53. by default the watchdog leaves a spent Codex account alone"
cx_sandbox "{$CX_BOTH}"
cx_account work user-A acct-A
cx_account codex02 user-B acct-B
cx_live work
cx_rollout user-A acct-A 100 3600 20 $((3 * DAY)) 60
cx_rollout user-B acct-B 10 3600 10 $((3 * DAY)) 60
cx_check
assert_eq "check exits cleanly" 0 "$SW_RC"
assert_eq "the active Codex account is unchanged" work "$(cat "$CX/active")"
assert_eq "the live Codex login is unchanged" user-A "$(codex_user_of "$LIVE_AUTH")"
assert_eq "no notification" 0 "$(sw_notes)"
assert_true test ! -e "$CX/watch.json"
for providers in '"codex"' '[]' '["bogus"]' '{"codex":true}'; do
  cx_sandbox "{$CX_BOTH,\"autoSwitchProviders\":$providers}"
  cx_account work user-A acct-A
  cx_account codex02 user-B acct-B
  cx_live work
  cx_rollout user-A acct-A 100 3600 20 $((3 * DAY)) 60
  cx_rollout user-B acct-B 10 3600 10 $((3 * DAY)) 60
  cx_check
  assert_eq "autoSwitchProviders $providers exits cleanly" 0 "$SW_RC"
  assert_eq "autoSwitchProviders $providers means Claude alone" work "$(cat "$CX/active")"
done

echo "54. with Codex enabled, a spent 5-hour window hands over to a roomy Codex account"
cx_sandbox "{$CX_BOTH,\"autoSwitchProviders\":[\"claude\",\"codex\"]}"
cx_account work user-A acct-A
cx_account codex02 user-B acct-B
cx_account codex03 user-C acct-C
cx_live work
# codex03 has the least weekly usage but its 5-hour window is the tighter one.
cx_rollout user-A acct-A 100 3600 20 $((3 * DAY)) 60
cx_rollout user-B acct-B 30 3600 30 $((3 * DAY)) 120
cx_rollout user-C acct-C 60 3600 5 $((3 * DAY)) 120
cx_check
assert_eq "check exits cleanly" 0 "$SW_RC"
assert_eq "the active Codex account is the roomiest one" codex02 "$(cat "$CX/active")"
assert_eq "the live ~/.codex/auth.json now holds codex02's login" user-B "$(codex_user_of "$LIVE_AUTH")"
assert_eq "the live login is still mode 600" 600 "$(stat -c %a "$LIVE_AUTH")"
assert_eq "work's store keeps work's login" user-A "$(codex_user_of "$CX/work/auth.json")"
notes=$(cat "$NOTIFY_LOG")
assert_eq "one notification" 1 "$(sw_notes)"
assert_contains "the notice names Codex and the new account" "$notes" "Codex: switched to codex02"
assert_contains "the notice names the spent window" "$notes" "work hit its 5-hour limit"
assert_contains "the notice says running sessions keep the old account" "$notes" "Running Codex sessions keep work until they are restarted"
assert_not_contains "the notice does not claim open sessions follow" "$notes" "follow on their next message"
assert_eq "Codex keeps its own watch state" 2 \
  "$(jq -r '.work.session | to_entries[0].value' "$CX/watch.json" 2>/dev/null)"
assert_true test ! -e "$SWAPKIN_DIR/watch.json"
cx_check
assert_eq "the next check does nothing more" 1 "$(sw_notes)"

echo "55. Codex candidates: an old figure is an upper bound; a reset window has room"
cx_sandbox '{"autoSwitch":true,"alertAt":90,"autoSwitchWindows":["session"],"autoSwitchProviders":["codex"]}'
cx_account work user-A acct-A
cx_account old-past user-B acct-B
cx_live work
cx_rollout user-A acct-A 100 3600 20 $((3 * DAY)) 60
# Spent three days ago, but that 5-hour window reset long since.
cx_rollout user-B acct-B 100 -$((3 * DAY - 18000)) 20 $((4 * DAY)) $((3 * DAY))
cx_check
assert_eq "check exits cleanly" 0 "$SW_RC"
assert_eq "a stale candidate whose window has reset is taken" old-past "$(cat "$CX/active")"
assert_eq "and the live login follows" user-B "$(codex_user_of "$LIVE_AUTH")"

# Idle for three hours, with both windows still running: nobody used these
# accounts since, so their usage can only have gone down. An old figure below
# autoSwitchAt means room; one at it still means spent.
cx_sandbox "{$CX_BOTH,\"autoSwitchProviders\":[\"codex\"]}"
cx_account work user-A acct-A
cx_account old-full user-B acct-B
cx_account old-part user-C acct-C
cx_live work
cx_rollout user-A acct-A 100 3600 20 $((3 * DAY)) 60
cx_rollout user-B acct-B 100 3600 20 $((4 * DAY)) 10800
cx_rollout user-C acct-C 30 3600 40 $((4 * DAY)) 10800
cx_check
assert_eq "check exits cleanly" 0 "$SW_RC"
assert_eq "an idle candidate under the threshold in every window is taken" old-part "$(cat "$CX/active")"
assert_eq "and the live login follows" user-C "$(codex_user_of "$LIVE_AUTH")"

cx_sandbox "{$CX_BOTH,\"autoSwitchProviders\":[\"codex\"]}"
cx_account work user-A acct-A
cx_account old-full user-B acct-B
cx_account old-week user-C acct-C
cx_live work
cx_rollout user-A acct-A 100 3600 20 $((3 * DAY)) 60
cx_rollout user-B acct-B 100 3600 20 $((4 * DAY)) 10800
# Its session reset long since, but its week is spent and still running.
cx_rollout user-C acct-C 100 -$((DAY)) 100 $((4 * DAY)) $((2 * DAY))
cx_check
assert_eq "check exits cleanly" 0 "$SW_RC"
assert_eq "an idle candidate still spent in a running window is skipped" work "$(cat "$CX/active")"
assert_eq "the live login is untouched" user-A "$(codex_user_of "$LIVE_AUTH")"
assert_contains "the warning says no account has room" "$(cat "$NOTIFY_LOG")" "No other account has room right now."
assert_contains "the warning names Codex" "$(cat "$NOTIFY_LOG")" "Codex: work is at 100% of its 5-hour window"

# The active account's own window reset since its last session: not spent.
cx_sandbox '{"autoSwitch":true,"alertAt":90,"autoSwitchWindows":["session"],"autoSwitchProviders":["codex"]}'
cx_account work user-A acct-A
cx_account codex02 user-B acct-B
cx_live work
cx_rollout user-A acct-A 100 -3600 20 $((3 * DAY)) 21600
cx_rollout user-B acct-B 10 3600 10 $((3 * DAY)) 60
cx_check
assert_eq "check exits cleanly" 0 "$SW_RC"
assert_eq "a window that reset since is not spent" work "$(cat "$CX/active")"
assert_eq "and nothing is notified" 0 "$(sw_notes)"

echo "56. a Codex refusal is a failed switch: reported once, retried on every check"
cx_sandbox "{$CX_BOTH,\"autoSwitchProviders\":[\"codex\"]}"
cx_account work user-A acct-A
cx_account codex02 user-B acct-B
cx_live work
# The live login belongs to no saved account, so use refuses to overwrite it.
fake_codex_auth "$LIVE_AUTH" user-Q acct-Q plus "$CX_SW_PREFIX-unknown-QQQQQQQQQQQQQQQQQQQQ"
cx_rollout user-A acct-A 100 3600 20 $((3 * DAY)) 60
cx_rollout user-B acct-B 10 3600 10 $((3 * DAY)) 60
cx_check
rc1=$SW_RC
cx_check
assert_true [ "$rc1" -ne 0 ]
assert_true [ "$SW_RC" -ne 0 ]
assert_eq "the active account is unchanged" work "$(cat "$CX/active")"
assert_eq "the unknown live login is never overwritten" user-Q "$(codex_user_of "$LIVE_AUTH")"
assert_eq "no 'switched' notice" 0 "$(grep -ci 'switched to' "$NOTIFY_LOG")"
assert_eq "the failed switch is reported once, naming Codex and the target" 1 "$(grep -c 'Codex: could not switch to codex02' "$NOTIFY_LOG")"
cp "$CX/work/auth.json" "$LIVE_AUTH"
cx_check
assert_eq "check exits cleanly once the switch works" 0 "$SW_RC"
assert_eq "the next check retries and switches" codex02 "$(cat "$CX/active")"
assert_eq "the live login follows" user-B "$(codex_user_of "$LIVE_AUTH")"

echo "57. a Codex switch that cannot go in place still switches, and says how to start sessions"
cx_sandbox "{$CX_BOTH,\"autoSwitchProviders\":[\"codex\"]}"
cx_account work user-A acct-A
cx_account codex02 user-B acct-B
cx_live work
# Its legacy home still holds a login, which the pointer-only switch needs.
mkdir -p "$CX/codex02/home"
cp "$CX/codex02/auth.json" "$CX/codex02/home/auth.json"
cx_rollout user-A acct-A 100 3600 20 $((3 * DAY)) 60
cx_rollout user-B acct-B 10 3600 10 $((3 * DAY)) 60
# Signed out (or a keyring login): there is no live auth.json to switch in place.
rm "$LIVE_AUTH"
cx_check
assert_eq "check exits cleanly" 0 "$SW_RC"
assert_eq "the pointer moved" codex02 "$(cat "$CX/active")"
assert_true test ! -e "$LIVE_AUTH"
notes=$(cat "$NOTIFY_LOG")
assert_contains "it counts as a switch" "$notes" "Codex: switched to codex02"
assert_contains "and says new sessions need swapkin run codex" "$notes" "swapkin run codex"

echo "58. Claude and Codex spent in the same check are handled independently"
cx_sandbox "{$CX_BOTH,\"autoSwitchProviders\":[\"claude\",\"codex\"]}"
sw_account work 1.0 0.2
sw_account other 0.1 0.1
echo work > "$SWAPKIN_DIR/active"
cx_account work user-A acct-A
cx_account codex02 user-B acct-B
cx_live work
cx_rollout user-A acct-A 100 7200 20 $((3 * DAY)) 60
cx_rollout user-B acct-B 10 3600 10 $((3 * DAY)) 60
cx_check
assert_eq "check exits cleanly" 0 "$SW_RC"
assert_eq "Claude handed over" other "$(cat "$SWAPKIN_DIR/active")"
assert_eq "Codex handed over" codex02 "$(cat "$CX/active")"
assert_eq "the live Codex login follows" user-B "$(codex_user_of "$LIVE_AUTH")"
notes=$(cat "$NOTIFY_LOG")
assert_contains "the Claude notice is unchanged" "$notes" "Switched to other | work hit its 5-hour limit. Open sessions follow on their next message."
assert_contains "the Codex notice names Codex" "$notes" "Codex: switched to codex02"
assert_eq "two notices" 2 "$(sw_notes)"
assert_eq "Claude's state holds Claude's session reset alone" '["2026-09-28T15:00"]' \
  "$(jq -c '.work.session | keys' "$SWAPKIN_DIR/watch.json" 2>/dev/null)"
cx_reset=$(date -u -d "$(jq -r '.limits[0].resetsAt' "$CX/work/usage.json" 2>/dev/null)" +%s 2>/dev/null || echo 0)
cx_key=$(date -u -d "@$(( (cx_reset + 30) / 60 * 60 ))" +%Y-%m-%dT%H:%M)
assert_eq "Codex's state holds Codex's session reset alone" "[\"$cx_key\"]" \
  "$(jq -c '.work.session | keys' "$CX/watch.json" 2>/dev/null)"

echo "59. autoSwitchProviders [\"codex\"] alone leaves a spent Claude account to the user"
cx_sandbox "{$CX_BOTH,\"autoSwitchProviders\":[\"codex\"]}"
sw_account work 1.0 0.2
sw_account other 0.1 0.1
echo work > "$SWAPKIN_DIR/active"
cx_account work user-A acct-A
cx_account codex02 user-B acct-B
cx_live work
cx_rollout user-A acct-A 100 3600 20 $((3 * DAY)) 60
cx_rollout user-B acct-B 10 3600 10 $((3 * DAY)) 60
cx_check
assert_eq "check exits cleanly" 0 "$SW_RC"
assert_eq "Claude is not watched" work "$(cat "$SWAPKIN_DIR/active")"
assert_eq "Codex is" codex02 "$(cat "$CX/active")"

sw_sandbox "{$CX_BOTH,\"autoSwitchProviders\":[\"claude\",\"codex\"]}"
unset CODEX_HOME
sw_account work 1.0 0.2
sw_account other 0.1 0.1
echo work > "$SWAPKIN_DIR/active"
sw_check
assert_eq "with no Codex accounts at all, check exits cleanly" 0 "$SW_RC"
assert_eq "and Claude is still handled" other "$(cat "$SWAPKIN_DIR/active")"
assert_true test ! -e "$SWAPKIN_DIR/providers/codex"

echo "60. Claude: an untrusted roomiest account does not hide a usable one"
sw_sandbox '{"autoSwitch":true,"alertAt":90}'
sw_account spent 0.2 1.0
sw_account a-stale 0.05 0.05
sw_account b-fresh 0.1 0.1
# a-stale has the most room, but its figures are three hours old.
touch -d '3 hours ago' "$SWAPKIN_DIR/a-stale/usage.json"
echo spent > "$SWAPKIN_DIR/active"
sw_check
assert_eq "check exits cleanly" 0 "$SW_RC"
assert_eq "hands over to the roomiest account that can be trusted" b-fresh "$(cat "$SWAPKIN_DIR/active")"
assert_contains "and says so" "$(cat "$NOTIFY_LOG")" "Switched to b-fresh"
assert_not_contains "without claiming no account has room" "$(cat "$NOTIFY_LOG")" "No other account has room"

echo "61. Codex: a roomiest candidate with a corrupt login does not hide a usable one"
cx_sandbox "{$CX_BOTH,\"autoSwitchProviders\":[\"codex\"]}"
cx_account work user-A acct-A
cx_account a-broken user-B acct-B
cx_account codex02 user-C acct-C
cx_live work
printf '{"tokens":' > "$CX/a-broken/auth.json"
# A corrupt login has no identity, so the probe leaves these figures alone.
jq -n --arg u "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{limits:[{label:"5h window",percent:0.01,resetsAt:"2099-01-01T00:00:00Z"},{label:"Weekly",percent:0.01,resetsAt:"2099-01-01T00:00:00Z"}], updatedAt:$u}' \
  > "$CX/a-broken/usage.json"
cx_rollout user-A acct-A 100 3600 20 $((3 * DAY)) 60
cx_rollout user-C acct-C 30 3600 30 $((3 * DAY)) 60
cx_check
assert_eq "check exits cleanly" 0 "$SW_RC"
assert_eq "hands over to the next usable account" codex02 "$(cat "$CX/active")"
assert_eq "the live login follows" user-C "$(codex_user_of "$LIVE_AUTH")"
assert_contains "and says so" "$(cat "$NOTIFY_LOG")" "Codex: switched to codex02"

# ================================================================== summary ==
echo
echo "19. no captured test output contains a fixture token string"
if grep -qF "$LIVE_TOKEN" "$ALL_OUTPUT_LOG" 2>/dev/null \
   || grep -qF "$STALE_TOKEN" "$ALL_OUTPUT_LOG" 2>/dev/null \
   || grep -qF "$PERSONAL_TOKEN" "$ALL_OUTPUT_LOG" 2>/dev/null \
   || grep -qF "$GH_SECRET_TOKEN" "$ALL_OUTPUT_LOG" 2>/dev/null \
   || grep -qF "$SENTINEL_TOKEN" "$ALL_OUTPUT_LOG" 2>/dev/null \
   || grep -qF "$CODEX_A_OLD" "$ALL_OUTPUT_LOG" 2>/dev/null \
   || grep -qF "$CODEX_A_ROTATED" "$ALL_OUTPUT_LOG" 2>/dev/null \
   || grep -qF "$CODEX_B_TOKEN" "$ALL_OUTPUT_LOG" 2>/dev/null \
   || grep -qF "$CODEX_B_ROTATED" "$ALL_OUTPUT_LOG" 2>/dev/null \
   || grep -qF "$CODEX_C_TOKEN" "$ALL_OUTPUT_LOG" 2>/dev/null \
   || grep -qF "$CODEX_Z_TOKEN" "$ALL_OUTPUT_LOG" 2>/dev/null \
   || grep -qF "$CODEX_WS1_TOKEN" "$ALL_OUTPUT_LOG" 2>/dev/null \
   || grep -qF "$CODEX_WS2_TOKEN" "$ALL_OUTPUT_LOG" 2>/dev/null \
   || grep -qF "$CODEX_WS2_ROTATED" "$ALL_OUTPUT_LOG" 2>/dev/null \
   || grep -qF "$CODEX_WS2_RACE" "$ALL_OUTPUT_LOG" 2>/dev/null \
   || grep -qF "$CODEX_Q_TOKEN" "$ALL_OUTPUT_LOG" 2>/dev/null \
   || grep -qF "$CODEX_API_KEY" "$ALL_OUTPUT_LOG" 2>/dev/null \
   || grep -qF "$SW_TOKEN_PREFIX" "$ALL_OUTPUT_LOG" 2>/dev/null \
   || grep -qF "$CX_SW_PREFIX" "$ALL_OUTPUT_LOG" 2>/dev/null; then
  bad "no captured test output contains any fixture token string"
else
  ok "no captured test output contains any fixture token string"
fi

echo "shipped demo data"
shipped=$(SWAPKIN_DEMO=1 SWAPKIN_DEMO_FILE= "$ROOT/bin/swapkin" providers --json 2>&1 || true)
assert_true jq -e '.demo and (.providers | length >= 3) and all(.providers[].accounts[].limits[]; (.resetsAt // "") | test("^[0-9]{4}-") or . == "")' <<<"$shipped"

echo
echo "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
