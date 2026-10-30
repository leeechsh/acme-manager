#!/usr/bin/env bash

config_defaults() {
  local state_root
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    state_root='/var'
    CERT_DIR="${ACME_MANAGER_CERT_DIR:-/var/cert}"
    LOG_DIR="${ACME_MANAGER_LOG_DIR:-/var/log/acme-manager}"
  else
    state_root="${XDG_STATE_HOME:-$HOME/.local/state}/acme-manager"
    CERT_DIR="${ACME_MANAGER_CERT_DIR:-$state_root/certs}"
    LOG_DIR="${ACME_MANAGER_LOG_DIR:-$state_root/log}"
  fi
  DEFAULT_CA='letsencrypt'
  DEFAULT_DNS='cloudflare'
  DEFAULT_KEY_TYPE='ec-256'
  AUTO_RENEW='true'
  NOTIFY_ENABLED='true'
  NOTIFY_LEVEL='2'
  EXPIRY_DAYS='30'
  ACME_HOME="${ACME_HOME:-${HOME}/.acme.sh}"
  SMTP_HOST=''
  SMTP_PORT=''
  SMTP_SECURE='tls'
  SMTP_FROM=''
  SMTP_TO=''
  SMTP_USERNAME=''
}

config_path_default() {
  if [[ -n "${ACME_MANAGER_CONFIG:-}" ]]; then
    printf '%s\n' "$ACME_MANAGER_CONFIG"
  elif [[ -w /etc || ${EUID:-$(id -u)} -eq 0 ]]; then
    printf '%s\n' '/etc/acme-manager/config.conf'
  else
    printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/acme-manager/config.conf"
  fi
}

config_load() {
  local env_acme_home="${ACME_HOME:-}"
  local env_cert_dir="${ACME_MANAGER_CERT_DIR:-}"
  local env_log_dir="${ACME_MANAGER_LOG_DIR:-}"
  local migrated_legacy_cert_dir=0
  config_defaults
  CONFIG_FILE="${ACME_MANAGER_CONFIG:-$(config_path_default)}"
  export CONFIG_FILE
  [[ -f "$CONFIG_FILE" ]] || return 0
  local line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    if [[ "$line" =~ ^[[:space:]]*([A-Z_][A-Z0-9_]*)[[:space:]]*=[[:space:]]*(.*)[[:space:]]*$ ]]; then
      key="${BASH_REMATCH[1]}"
      value="${BASH_REMATCH[2]}"
      value="${value#\"}"; value="${value%\"}"
      value="${value#\'}"; value="${value%\'}"
      case "$key" in
        DEFAULT_CA|DEFAULT_DNS|DEFAULT_KEY_TYPE|AUTO_RENEW|NOTIFY_ENABLED|NOTIFY_LEVEL|LOG_DIR|EXPIRY_DAYS|ACME_HOME|SMTP_HOST|SMTP_PORT|SMTP_SECURE|SMTP_FROM|SMTP_TO|SMTP_USERNAME)
          printf -v "$key" '%s' "$value" ;;
        CERT_DIR)
          if [[ "$value" == '/etc/ssl/acme' && -z "$env_cert_dir" && ${EUID:-$(id -u)} -eq 0 ]]; then
            CERT_DIR='/var/cert'
            migrated_legacy_cert_dir=1
          else
            CERT_DIR="$value"
          fi
          ;;
        *) warn "Ignoring unknown config key: $key" ;;
      esac
    else
      warn "Ignoring malformed config line: $line"
    fi
  done <"$CONFIG_FILE"
  [[ -n "$env_acme_home" ]] && ACME_HOME="$env_acme_home"
  [[ -n "$env_cert_dir" ]] && CERT_DIR="$env_cert_dir"
  [[ -n "$env_log_dir" ]] && LOG_DIR="$env_log_dir"
  config_validate || return 1
  if (( migrated_legacy_cert_dir )); then
    config_write >/dev/null 2>&1 || true
  fi
}

config_validate() {
  valid_choice "$DEFAULT_CA" letsencrypt zerossl || { error 'DEFAULT_CA must be letsencrypt or zerossl'; return 1; }
  valid_choice "$DEFAULT_DNS" cloudflare dnspod aliyun || { error 'DEFAULT_DNS must be cloudflare, dnspod or aliyun'; return 1; }
  valid_choice "$DEFAULT_KEY_TYPE" ec-256 rsa-2048 rsa-3072 rsa-4096 || { error 'DEFAULT_KEY_TYPE is invalid'; return 1; }
  valid_bool "$AUTO_RENEW" || { error 'AUTO_RENEW must be true or false'; return 1; }
  valid_bool "$NOTIFY_ENABLED" || { error 'NOTIFY_ENABLED must be true or false'; return 1; }
  [[ "$NOTIFY_LEVEL" =~ ^[0-3]$ ]] || { error 'NOTIFY_LEVEL must be 0-3'; return 1; }
  [[ "$EXPIRY_DAYS" =~ ^[0-9]+$ ]] || { error 'EXPIRY_DAYS must be a non-negative integer'; return 1; }
  valid_choice "$SMTP_SECURE" none tls ssl || { error 'SMTP_SECURE must be none, tls or ssl'; return 1; }
  valid_abs_path "$CERT_DIR" || { error 'CERT_DIR must be an absolute path'; return 1; }
  valid_abs_path "$LOG_DIR" || { error 'LOG_DIR must be an absolute path'; return 1; }
  valid_abs_path "$ACME_HOME" || { error 'ACME_HOME must be an absolute path'; return 1; }
}

config_write() {
  config_validate || return 1
  local file="${CONFIG_FILE:-$(config_path_default)}"
  atomic_write "$file" 600 <<EOF_CONF
# ACME Manager global preferences. Secrets stay in acme.sh account.conf.
DEFAULT_CA="$DEFAULT_CA"
DEFAULT_DNS="$DEFAULT_DNS"
DEFAULT_KEY_TYPE="$DEFAULT_KEY_TYPE"
CERT_DIR="$CERT_DIR"
AUTO_RENEW="$AUTO_RENEW"
NOTIFY_ENABLED="$NOTIFY_ENABLED"
NOTIFY_LEVEL="$NOTIFY_LEVEL"
LOG_DIR="$LOG_DIR"
EXPIRY_DAYS="$EXPIRY_DAYS"
ACME_HOME="$ACME_HOME"
SMTP_HOST="$SMTP_HOST"
SMTP_PORT="$SMTP_PORT"
SMTP_SECURE="$SMTP_SECURE"
SMTP_FROM="$SMTP_FROM"
SMTP_TO="$SMTP_TO"
SMTP_USERNAME="$SMTP_USERNAME"
EOF_CONF
  chmod 600 "$file"
  success "Config written to $file"
}

config_ensure_dirs() {
  mkdir -p "$LOG_DIR" "$CERT_DIR" "$ACME_HOME"
  chmod 700 "$ACME_HOME"
  chmod 750 "$LOG_DIR" 2>/dev/null || true
  chmod 750 "$CERT_DIR" 2>/dev/null || true
  [[ -f "$CONFIG_FILE" ]] || config_write >/dev/null
}

config_show() {
  printf 'Config file: %s\n' "$CONFIG_FILE"
  printf 'ACME_HOME: %s\nCertificate directory: %s\nLog directory: %s\n' "$ACME_HOME" "$CERT_DIR" "$LOG_DIR"
  printf 'Default CA: %s\nDefault DNS: %s\nDefault key type: %s\n' "$DEFAULT_CA" "$DEFAULT_DNS" "$DEFAULT_KEY_TYPE"
  printf 'Auto renewal: %s\nNotifications: %s (level %s)\nExpiry reminder: %s days\n' "$AUTO_RENEW" "$NOTIFY_ENABLED" "$NOTIFY_LEVEL" "$EXPIRY_DAYS"
  printf 'SMTP: %s:%s (%s), from=%s, to=%s\n' "${SMTP_HOST:-not configured}" "${SMTP_PORT:-default}" "$SMTP_SECURE" "${SMTP_FROM:-not configured}" "${SMTP_TO:-not configured}"
}

config_doctor() {
  local rc=0
  config_validate || rc=1
  [[ -r "$CONFIG_FILE" && "$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null || stat -f '%Lp' "$CONFIG_FILE" 2>/dev/null)" =~ ^(600|640|644)$ ]] || { warn "Config file is unreadable or has unsafe permissions: $CONFIG_FILE"; rc=1; }
  [[ -d "$ACME_HOME" ]] || { warn "ACME_HOME does not exist: $ACME_HOME"; rc=1; }
  [[ -d "$CERT_DIR" ]] || { warn "Certificate directory does not exist: $CERT_DIR"; rc=1; }
  return "$rc"
}
