#!/usr/bin/env bash

notify_configure() {
  SMTP_HOST=$(prompt_value 'SMTP host' "${SMTP_HOST:-}")
  SMTP_PORT=$(prompt_value 'SMTP port' "${SMTP_PORT:-587}")
  SMTP_SECURE=$(prompt_select 'SMTP encryption' "${SMTP_SECURE:-tls}" \
    none 'None' \
    tls 'STARTTLS' \
    ssl 'SSL/TLS')
  SMTP_FROM=$(prompt_value 'From address' "${SMTP_FROM:-}")
  SMTP_TO=$(prompt_value 'To addresses (comma-separated)' "${SMTP_TO:-}")
  SMTP_USERNAME=$(prompt_value 'SMTP username (optional)' "${SMTP_USERNAME:-}")
  local password
  password=$(prompt_secret 'SMTP password (empty keeps the current password)') || return 1
  [[ -n "$SMTP_HOST" && -n "$SMTP_FROM" && -n "$SMTP_TO" ]] || { error 'SMTP host, from address and recipients are required'; return 1; }
  valid_choice "$SMTP_SECURE" none tls ssl || { error 'Invalid encryption mode'; return 1; }
  [[ "$SMTP_PORT" =~ ^[0-9]+$ ]] || { error 'Port must be numeric'; return 1; }
  account_set_var SMTP_HOST "$SMTP_HOST"
  account_set_var SMTP_PORT "$SMTP_PORT"
  account_set_var SMTP_SECURE "$SMTP_SECURE"
  account_set_var SMTP_FROM "$SMTP_FROM"
  account_set_var SMTP_TO "$SMTP_TO"
  [[ -n "$SMTP_USERNAME" ]] && account_set_var SMTP_USERNAME "$SMTP_USERNAME"
  [[ -n "$password" ]] && account_set_var SMTP_PASSWORD "$password"
  account_set_var SMTP_TIMEOUT '30'
  config_write >/dev/null
  run_acme_logged notify-config --set-notify --notify-level "$NOTIFY_LEVEL" --notify-mode 0 --notify-hook smtp || { error 'SMTP configuration or test failed'; return 1; }
  success 'SMTP notifications configured; acme.sh completed the SMTP test'
}

notify_status() {
  local key value
  printf 'Manager notifications: enabled=%s level=%s\n' "$NOTIFY_ENABLED" "$NOTIFY_LEVEL"
  for key in SMTP_HOST SMTP_PORT SMTP_SECURE SMTP_FROM SMTP_TO SMTP_USERNAME; do
    if value=$(account_get_var "$key" 2>/dev/null); then
      [[ "$key" == SMTP_PASSWORD ]] || printf '  %-15s %s\n' "$key" "$value"
    else
      printf '  %-15s not configured\n' "$key"
    fi
  done
  if account_get_var SMTP_PASSWORD >/dev/null 2>&1; then printf '  SMTP_PASSWORD   configured\n'; else printf '  SMTP_PASSWORD   not configured\n'; fi
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
  command_exists curl || { warn 'curl is not installed; supplemental email notifications are unavailable'; return 1; }
  [[ -n "$port" ]] || port=587
  case "$secure" in
    ssl) url="smtps://$host:$port";;
    tls) url="smtp://$host:$port";;
    none) url="smtp://$host:$port";;
    *) warn "Unknown SMTP encryption mode: $secure"; return 1;;
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
    warn "Email notification failed: $event"
    return 1
  }
}

notify_test() {
  ensure_acme || return 1
  [[ -n "$(account_get_var SMTP_HOST 2>/dev/null || true)" ]] || { error 'Configure SMTP first'; return 1; }
  run_acme_logged notify-test --set-notify --notify-level "$NOTIFY_LEVEL" --notify-mode 0 --notify-hook smtp || { error 'SMTP test failed'; return 1; }
  success 'SMTP test command completed'
}

notify_menu() {
  while true; do
    menu_header 'Email Notifications' 'SMTP configuration, testing and event notifications'
    menu_home_status
    ui_section 'Status & Configuration'
    ui_menu_item 1 'View SMTP status' 'Host, port, sender and credential status'
    ui_menu_item 2 'Configure SMTP' 'acme.sh sends a test after saving'
    ui_menu_item 3 'Send test email' 'Validate the current SMTP settings'
    ui_menu_item 4 'Enable and notification level' 'Control supplemental notifications'
    ui_menu_item 0 'Back'
    ui_footer
    menu_choice 'Choose an action [0-4]:' || return 0
    local level enabled
    case "$MENU_CHOICE" in
      1) notify_status; pause_screen;;
      2) notify_configure || true; pause_screen;;
      3) notify_test || true; pause_screen;;
      4)
        enabled=$(prompt_select 'Enable notifications' "$NOTIFY_ENABLED" \
          true 'Enabled' \
          false 'Disabled')
        level=$(prompt_select 'Notification level' "$NOTIFY_LEVEL" \
          0 'Disabled' \
          1 'Errors only' \
          2 'Warnings and errors' \
          3 'All events')
        valid_bool "$enabled" && [[ "$level" =~ ^[0-3]$ ]] || { error 'Invalid input'; pause_screen; continue; }
        NOTIFY_ENABLED="$enabled"
        NOTIFY_LEVEL="$level"
        config_write || true
        pause_screen
        ;;
      0) return 0;; *) warn 'Invalid choice';;
    esac
  done
}
