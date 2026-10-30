#!/usr/bin/env bash

# Shared helpers. The entrypoint enables strict mode after loading defaults.

: "${ACME_MANAGER_NAME:=ACME Manager}"
: "${ACME_MANAGER_VERSION:=1.0.0}"

UI_RESET=''
UI_BOLD=''
UI_DIM=''
UI_PRIMARY=''
UI_ACCENT=''
UI_SUCCESS=''
UI_WARNING=''
UI_ERROR=''
UI_MUTED=''
UI_LINE=''

ui_init() {
  if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    UI_RESET=$'\033[0m'
    UI_BOLD=$'\033[1m'
    UI_DIM=$'\033[2m'
    UI_PRIMARY=$'\033[38;5;39m'
    UI_ACCENT=$'\033[38;5;214m'
    UI_SUCCESS=$'\033[38;5;42m'
    UI_WARNING=$'\033[38;5;220m'
    UI_ERROR=$'\033[38;5;203m'
    UI_MUTED=$'\033[38;5;245m'
    UI_LINE=$'\033[38;5;60m'
  fi
}

ui_width() {
  local width
  width=$(tput cols 2>/dev/null || true)
  [[ "$width" =~ ^[0-9]+$ && "$width" -ge 60 ]] || width=80
  printf '%s\n' "$width"
}

ui_rule() {
  local width="${1:-$(ui_width)}" char="${2:--}"
  printf '%s%s%s\n' "$UI_LINE" "$(printf '%*s' "$width" '' | tr ' ' "$char")" "$UI_RESET"
}

ui_clear() {
  is_tty && clear 2>/dev/null || true
}

ui_title() {
  local title="$1" subtitle="${2:-}"
  printf '\n%s%s%s %s%s%s\n' "$UI_PRIMARY" "$UI_BOLD" "$title" "$UI_RESET" "$UI_MUTED" "$subtitle"
  ui_rule "$(ui_width)" '-'
}

ui_section() {
  printf '\n%s%s%s\n' "$UI_ACCENT" "$1" "$UI_RESET"
}

ui_menu_item() {
  local number="$1" title="$2" description="${3:-}"
  printf '  %s%s%2s%s  %s%s%s' "$UI_PRIMARY" "$UI_BOLD" "$number" "$UI_RESET" "$UI_BOLD" "$title" "$UI_RESET"
  [[ -n "$description" ]] && printf ' %s%s%s' "$UI_MUTED" "$description" "$UI_RESET"
  printf '\n'
}

ui_footer() {
  printf '\n%s%s%s\n' "$UI_MUTED" "${1:-0 返回 · Ctrl+C 退出}" "$UI_RESET"
}

ui_status_strip() {
  printf '%s[%sCA%s] %s%s%s  %s[%sDNS%s] %s%s%s  %s[%sKEY%s] %s%s%s\n' \
    "$UI_PRIMARY" "$UI_RESET" "$UI_PRIMARY" "$UI_BOLD" "$1" "$UI_RESET" \
    "$UI_PRIMARY" "$UI_RESET" "$UI_PRIMARY" "$UI_BOLD" "$2" "$UI_RESET" \
    "$UI_PRIMARY" "$UI_RESET" "$UI_PRIMARY" "$UI_BOLD" "$3" "$UI_RESET"
}

ui_hint() {
  printf '%s%s%s\n' "$UI_DIM" "$1" "$UI_RESET"
}

_now() { date '+%Y-%m-%d %H:%M:%S'; }

_log_file() {
  if [[ -n "${LOG_DIR:-}" ]]; then
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    printf '%s/acme-manager.log\n' "$LOG_DIR"
  else
    printf '%s\n' "/tmp/acme-manager.log"
  fi
}

log_line() {
  local level="$1"; shift
  local message="$*"
  local file
  file=$(_log_file)
  printf '[%s] [%s] %s\n' "$(_now)" "$level" "$message" >>"$file" 2>/dev/null || true
}

info() {
  printf '%s[INFO]%s %s\n' "$UI_PRIMARY" "$UI_RESET" "$*"
  log_line INFO "$*"
}
warn() {
  printf '%s[WARN]%s %s\n' "$UI_WARNING" "$UI_RESET" "$*" >&2
  log_line WARN "$*"
}
error() {
  printf '%s[ERROR]%s %s\n' "$UI_ERROR" "$UI_RESET" "$*" >&2
  log_line ERROR "$*"
}
success() {
  printf '%s[OK]%s %s\n' "$UI_SUCCESS" "$UI_RESET" "$*"
  log_line OK "$*"
}

is_tty() { [[ -t 0 && -t 1 ]]; }

pause_screen() {
  if is_tty; then
    printf '\n%s%sEnter%s 返回上一层  ·  %sCtrl+C%s 退出\n' "$UI_MUTED" "$UI_BOLD" "$UI_RESET" "$UI_BOLD" "$UI_RESET"
    read -r _ || true
  fi
}

prompt_value() {
  local label="$1" default="${2:-}" value
  if [[ -n "$default" ]]; then
    read -r -p "$(printf '%s%s%s [%s%s%s]: ' "$UI_ACCENT" "$label" "$UI_RESET" "$UI_MUTED" "$default" "$UI_RESET")" value || return 1
    printf '%s\n' "${value:-$default}"
  else
    read -r -p "$(printf '%s%s%s: ' "$UI_ACCENT" "$label" "$UI_RESET")" value || return 1
    printf '%s\n' "$value"
  fi
}

prompt_secret() {
  local label="$1" value
  read -r -s -p "$(printf '%s%s%s: ' "$UI_ACCENT" "$label" "$UI_RESET")" value || return 1
  printf '\n' >&2
  printf '%s\n' "$value"
}

confirm() {
  local question="$1" answer
  read -r -p "$(printf '%s%s%s [y/N]: ' "$UI_WARNING" "$question" "$UI_RESET")" answer || return 1
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

valid_bool() { [[ "$1" == true || "$1" == false ]]; }
valid_choice() { local value="$1"; shift; local item; for item in "$@"; do [[ "$value" == "$item" ]] && return 0; done; return 1; }
valid_abs_path() { [[ "$1" == /* && "$1" != *$'\n'* && "$1" != *$'\r'* ]]; }
valid_domain() {
  local value="$1"
  [[ -n "$value" && ${#value} -le 253 && "$value" != *[[:space:]]* && "$value" != *'/'* && "$value" != *'"'* && "$value" != *"'"* ]]
  [[ "$value" =~ ^(\*\.)?([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

shell_quote() { printf '%q' "$1"; }

ensure_parent() { mkdir -p "$(dirname "$1")"; }

atomic_write() {
  local destination="$1" mode="${2:-600}" tmp
  ensure_parent "$destination"
  tmp=$(mktemp "${destination}.tmp.XXXXXX") || return 1
  cat >"$tmp"
  chmod "$mode" "$tmp"
  mv -f "$tmp" "$destination"
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

acme_command() {
  if [[ -n "${ACME_SH_BIN:-}" ]]; then
    printf '%s\n' "$ACME_SH_BIN"
  elif [[ -x "${ACME_HOME:-$HOME/.acme.sh}/acme.sh" ]]; then
    printf '%s\n' "${ACME_HOME:-$HOME/.acme.sh}/acme.sh"
  elif command_exists acme.sh; then
    command -v acme.sh
  else
    return 1
  fi
}

ensure_acme() {
  local candidate
  if candidate=$(acme_command); then
    ACME_SH_BIN="$candidate"
    export ACME_SH_BIN
    return 0
  fi
  error '未找到 acme.sh。请先安装 acme.sh，或设置 ACME_SH_BIN。'
  return 1
}

run_acme() {
  ensure_acme || return 1
  local args=("$@")
  if [[ -n "${ACME_HOME:-}" ]]; then
    args+=(--home "$ACME_HOME")
  fi
  log_line CMD "$(shell_quote "$ACME_SH_BIN") $(printf '%q ' "${args[@]}")"
  "$ACME_SH_BIN" "${args[@]}"
}

run_acme_logged() {
  local operation="$1"; shift
  ensure_acme || return 1
  local capture rc
  capture=$(mktemp "${TMPDIR:-/tmp}/acme-manager.${operation}.XXXXXX") || return 1
  if run_acme "$@" > >(tee -a "$capture") 2>&1; then
    rc=0
  else
    rc=$?
  fi
  cat "$capture" >>"$(_log_file)" 2>/dev/null || true
  rm -f "$capture"
  return "$rc"
}

account_conf_path() { printf '%s/account.conf\n' "${ACME_HOME:-$HOME/.acme.sh}"; }

ensure_account_conf() {
  local file
  file=$(account_conf_path)
  mkdir -p "$(dirname "$file")"
  [[ -e "$file" ]] || : >"$file"
  chmod 600 "$file"
}

account_get_var() {
  local key="$1" file line value
  [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  file=$(account_conf_path)
  [[ -f "$file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?${key}= ]]; then
      value="${line#*=}"
      if [[ "$value" == "'"*"'" ]]; then value="${value:1:${#value}-2}"; fi
      if [[ "$value" == '"'*'"' ]]; then value="${value:1:${#value}-2}"; fi
      printf '%s\n' "$value"
      return 0
    fi
  done <"$file"
  return 1
}

account_set_var() {
  local key="$1" value="$2" file tmp line found=0 quoted
  [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { error "非法配置键: $key"; return 1; }
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || { error '配置值不能包含换行'; return 1; }
  ensure_account_conf
  file=$(account_conf_path)
  tmp=$(mktemp "${file}.tmp.XXXXXX") || return 1
  quoted=${value//\\/\\\\}
  quoted=${quoted//\'/\'\\\'\'}
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?${key}= ]]; then
      printf "export %s='%s'\n" "$key" "$quoted" >>"$tmp"
      found=1
    else
      printf '%s\n' "$line" >>"$tmp"
    fi
  done <"$file"
  if (( ! found )); then printf "export %s='%s'\n" "$key" "$quoted" >>"$tmp"; fi
  chmod 600 "$tmp"
  mv -f "$tmp" "$file"
}

account_unset_var() {
  local key="$1" file tmp line
  [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  ensure_account_conf
  file=$(account_conf_path)
  tmp=$(mktemp "${file}.tmp.XXXXXX") || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?${key}= ]] || printf '%s\n' "$line" >>"$tmp"
  done <"$file"
  chmod 600 "$tmp"
  mv -f "$tmp" "$file"
}

redact_line() {
  local line="$*" key
  for key in CF_Token CF_Key DP_Key Ali_Secret SMTP_PASSWORD; do
    if [[ "$line" == *"$key="* ]]; then
      line=$(sed -E "s#(${key}=)[^ ]*#\\1***#g" <<<"$line")
    fi
  done
  printf '%s\n' "$line"
}
