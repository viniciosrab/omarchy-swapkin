# shellcheck shell=bash
# The language of Swapkin's desktop notifications: Portuguese (Brazil) when the
# messages locale is Portuguese, English otherwise. Only notifications are
# translated; CLI output and diagnostics stay in English.

# "pt" or "en". SWAPKIN_LANG overrides the locale. Otherwise the usual order,
# LC_ALL > LC_MESSAGES > LANG; a service started with none of them set falls
# back to the system's /etc/locale.conf (SWAPKIN_LOCALE_CONF, for tests), where
# LC_MESSAGES wins over LANG too.
ui_lang() {
  local l=${SWAPKIN_LANG:-${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}}
  if [[ -z $l ]]; then
    local conf=${SWAPKIN_LOCALE_CONF:-/etc/locale.conf} key val lang="" messages=""
    if [[ -r $conf ]]; then
      while IFS='=' read -r key val; do
        val=${val//\"/}; val=${val//\'/}
        case $key in
          LANG) lang=$val ;;
          LC_MESSAGES) messages=$val ;;
        esac
      done < "$conf"
    fi
    l=${messages:-$lang}
  fi
  if [[ $l == pt* ]]; then echo pt; else echo en; fi
}

# A notification string by id, printf-style: msg <id> [args...]. Account names
# and numbers come in as arguments and are never translated.
msg() { # id args...
  local id=$1 en pt; shift
  case $id in
    switched)         en='Switched to %s'
                      pt='Trocado para %s' ;;
    switched_body)    en='%s %s. Open sessions follow on their next message.'
                      pt='%s %s. Sessões abertas passam a usar a nova conta na próxima mensagem.' ;;
    spent_weekly)     en='ran out of weekly quota'
                      pt='esgotou a cota semanal' ;;
    spent_session)    en='hit its 5-hour limit'
                      pt='atingiu o limite de 5 horas' ;;
    and)              en=' and '
                      pt=' e ' ;;
    warn_weekly)      en='%s is at %s%% of its week'
                      pt='%s está em %s%% da semana' ;;
    warn_session)     en='%s is at %s%% of its 5-hour window'
                      pt='%s está em %s%% da janela de 5 horas' ;;
    warn_room)        en='%s has %s%% free. Switch from the bar, or press a in the panel.'
                      pt='%s tem %s%% livre. Troque pela barra ou aperte a no painel.' ;;
    warn_no_room)     en='No other account has room right now.'
                      pt='Nenhuma outra conta tem espaço agora.' ;;
    failed)           en='Could not switch to %s'
                      pt='Não foi possível trocar para %s' ;;
    failed_body)      en='%s is still active; the next check tries again. Switch from the bar, or press a in the panel.'
                      pt='%s continua ativa; a próxima verificação tenta de novo. Troque pela barra ou aperte a no painel.' ;;
    codex_switched)   en='%s %s. Running Codex sessions keep %s until they are restarted.'
                      pt='%s %s. Sessões do Codex em execução continuam com %s até serem reiniciadas.' ;;
    codex_not_in_place) en='The switch could not go in place, so start new sessions with swapkin run codex.'
                      pt='Não foi possível trocar o login em uso; inicie novas sessões com swapkin run codex.' ;;
    codex_restarted)  en='Restarted the Codex daemon; codex resume brings back what it was running.'
                      pt='O daemon do Codex foi reiniciado; codex resume traz de volta o que ele estava executando.' ;;
    codex_daemon_kept) en='The Codex daemon still has %s; run: %s.'
                      pt='O daemon do Codex ainda está com %s; execute: %s.' ;;
    *) printf '%s' "$id"; return ;;
  esac
  # shellcheck disable=SC2059 # the templates above are the format strings
  if [[ $(ui_lang) == pt ]]; then printf "$pt" "$@"; else printf "$en" "$@"; fi
}
