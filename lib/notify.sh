#!/usr/bin/env bash

notify_configure() {
  SMTP_HOST=$(prompt_value 'SMTP 主机' "${SMTP_HOST:-}")
  SMTP_PORT=$(prompt_value 'SMTP 端口' "${SMTP_PORT:-587}")
  SMTP_SECURE=$(prompt_value '加密方式 (none/tls/ssl)' "${SMTP_SECURE:-tls}")
  SMTP_FROM=$(prompt_value '发件人邮箱' "${SMTP_FROM:-}")
  SMTP_TO=$(prompt_value '收件人邮箱（多个用逗号）' "${SMTP_TO:-}")
  SMTP_USERNAME=$(prompt_value 'SMTP 用户名（可选）' "${SMTP_USERNAME:-}")
  local password
  password=$(prompt_secret 'SMTP 密码（留空表示不修改）') || return 1
  [[ -n "$SMTP_HOST" && -n "$SMTP_FROM" && -n "$SMTP_TO" ]] || { error 'SMTP 主机、发件人和收件人不能为空'; return 1; }
  valid_choice "$SMTP_SECURE" none tls ssl || { error '加密方式无效'; return 1; }
  [[ "$SMTP_PORT" =~ ^[0-9]+$ ]] || { error '端口必须是数字'; return 1; }
  account_set_var SMTP_HOST "$SMTP_HOST"
  account_set_var SMTP_PORT "$SMTP_PORT"
  account_set_var SMTP_SECURE "$SMTP_SECURE"
  account_set_var SMTP_FROM "$SMTP_FROM"
  account_set_var SMTP_TO "$SMTP_TO"
  [[ -n "$SMTP_USERNAME" ]] && account_set_var SMTP_USERNAME "$SMTP_USERNAME"
  [[ -n "$password" ]] && account_set_var SMTP_PASSWORD "$password"
  account_set_var SMTP_TIMEOUT '30'
  config_write >/dev/null
  run_acme_logged notify-config --set-notify --notify-level "$NOTIFY_LEVEL" --notify-mode 0 --notify-hook smtp || { error 'SMTP 配置/测试失败'; return 1; }
  success 'SMTP 通知已配置；acme.sh 已执行 SMTP 测试'
}

notify_status() {
  local key value
  printf '管理器通知: enabled=%s level=%s\n' "$NOTIFY_ENABLED" "$NOTIFY_LEVEL"
  for key in SMTP_HOST SMTP_PORT SMTP_SECURE SMTP_FROM SMTP_TO SMTP_USERNAME; do
    if value=$(account_get_var "$key" 2>/dev/null); then
      [[ "$key" == SMTP_PASSWORD ]] || printf '  %-15s %s\n' "$key" "$value"
    else
      printf '  %-15s 未配置\n' "$key"
    fi
  done
  if account_get_var SMTP_PASSWORD >/dev/null 2>&1; then printf '  SMTP_PASSWORD   已配置\n'; else printf '  SMTP_PASSWORD   未配置\n'; fi
}

notify_send() {
  local subject="$1" body="$2" host port secure from recipients username password
  local url message netrc recipient rc=0
  [[ "$NOTIFY_ENABLED" == true ]] || return 0
  host="${SMTP_HOST:-$(account_get_var SMTP_HOST 2>/dev/null || true)}"
  port="${SMTP_PORT:-$(account_get_var SMTP_PORT 2>/dev/null || true)}"
  secure="${SMTP_SECURE:-$(account_get_var SMTP_SECURE 2>/dev/null || true)}"
  from="${SMTP_FROM:-$(account_get_var SMTP_FROM 2>/dev/null || true)}"
  recipients="${SMTP_TO:-$(account_get_var SMTP_TO 2>/dev/null || true)}"
  username="${SMTP_USERNAME:-$(account_get_var SMTP_USERNAME 2>/dev/null || true)}"
  password="$(account_get_var SMTP_PASSWORD 2>/dev/null || true)"
  [[ -n "$host" && -n "$from" && -n "$recipients" ]] || return 0
  command_exists curl || { warn '未找到 curl，无法发送补充邮件通知'; return 1; }
  [[ -n "$port" ]] || port=587
  case "$secure" in
    ssl) url="smtps://$host:$port";;
    tls) url="smtp://$host:$port";;
    none) url="smtp://$host:$port";;
    *) warn "未知 SMTP 加密方式: $secure"; return 1;;
  esac
  message=$(mktemp "${TMPDIR:-/tmp}/acme-manager-mail.XXXXXX") || return 1
  netrc=$(mktemp "${TMPDIR:-/tmp}/acme-manager-netrc.XXXXXX") || { rm -f "$message"; return 1; }
  chmod 600 "$message" "$netrc"
  {
    printf 'From: %s\n' "$from"
    printf 'To: %s\n' "$recipients"
    printf 'Subject: %s\n' "$subject"
    printf 'Content-Type: text/plain; charset=UTF-8\n\n%s\n' "$body"
  } >"$message"
  if [[ -n "$username" ]]; then
    printf 'machine %s login %s password %s\n' "$host" "$username" "$password" >"$netrc"
  else
    : >"$netrc"
  fi
  IFS=',' read -r -a _notify_recipients <<<"$recipients"
  local args=(--silent --show-error --url "$url" --mail-from "$from" --upload-file "$message" --netrc-file "$netrc")
  for recipient in "${_notify_recipients[@]}"; do
    recipient="${recipient## }"; recipient="${recipient%% }"
    [[ -n "$recipient" ]] && args+=(--mail-rcpt "$recipient")
  done
  [[ "$secure" == tls ]] && args+=(--ssl-reqd)
  if curl "${args[@]}"; then rc=0; else rc=$?; fi
  rm -f "$message" "$netrc"
  return "$rc"
}

notify_event() {
  local event="$1" subject="$2" body="$3"
  [[ "$NOTIFY_ENABLED" == true ]] || return 0
  notify_send "[ACME Manager] $event: $subject" "$body" || {
    warn "邮件通知发送失败: $event"
    return 1
  }
}

notify_test() {
  ensure_acme || return 1
  [[ -n "$(account_get_var SMTP_HOST 2>/dev/null || true)" ]] || { error '请先配置 SMTP'; return 1; }
  run_acme_logged notify-test --set-notify --notify-level "$NOTIFY_LEVEL" --notify-mode 0 --notify-hook smtp || { error 'SMTP 测试失败'; return 1; }
  success 'SMTP 测试命令已完成'
}

notify_menu() {
  while true; do
    menu_header '邮件通知' 'SMTP 配置、测试和事件通知'
    menu_home_status
    ui_section '状态与配置'
    ui_menu_item 1 '查看 SMTP 状态' '主机、端口、发件人和凭据状态'
    ui_menu_item 2 '配置 SMTP' '保存后由 acme.sh 执行测试'
    ui_menu_item 3 '发送测试邮件' '验证当前 SMTP 配置'
    ui_menu_item 4 '开关与通知级别' '控制补充通知行为'
    ui_menu_item 0 '返回上一级'
    ui_footer
    menu_choice '请选择操作 [0-4]:' || return 0
    local level enabled
    case "$MENU_CHOICE" in
      1) notify_status; pause_screen;;
      2) notify_configure || true; pause_screen;;
      3) notify_test || true; pause_screen;;
      4) enabled=$(prompt_value '启用通知 (true/false)' "$NOTIFY_ENABLED"); level=$(prompt_value '通知级别 (0-3)' "$NOTIFY_LEVEL"); valid_bool "$enabled" && [[ "$level" =~ ^[0-3]$ ]] || { error '输入无效'; pause_screen; continue; }; NOTIFY_ENABLED="$enabled"; NOTIFY_LEVEL="$level"; config_write; pause_screen;;
      0) return 0;; *) warn '无效选择';;
    esac
  done
}
