#!/usr/bin/env bash

config_defaults() {
  local state_root
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    state_root='/var'
    CERT_DIR="${ACME_MANAGER_CERT_DIR:-/etc/ssl/acme}"
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
        DEFAULT_CA|DEFAULT_DNS|DEFAULT_KEY_TYPE|CERT_DIR|AUTO_RENEW|NOTIFY_ENABLED|NOTIFY_LEVEL|LOG_DIR|EXPIRY_DAYS|ACME_HOME|SMTP_HOST|SMTP_PORT|SMTP_SECURE|SMTP_FROM|SMTP_TO|SMTP_USERNAME)
          printf -v "$key" '%s' "$value" ;;
        *) warn "忽略未允许的配置项: $key" ;;
      esac
    else
      warn "忽略无法解析的配置行: $line"
    fi
  done <"$CONFIG_FILE"
  [[ -n "$env_acme_home" ]] && ACME_HOME="$env_acme_home"
  [[ -n "$env_cert_dir" ]] && CERT_DIR="$env_cert_dir"
  [[ -n "$env_log_dir" ]] && LOG_DIR="$env_log_dir"
  config_validate || return 1
}

config_validate() {
  valid_choice "$DEFAULT_CA" letsencrypt zerossl || { error 'DEFAULT_CA 必须是 letsencrypt 或 zerossl'; return 1; }
  valid_choice "$DEFAULT_DNS" cloudflare dnspod aliyun || { error 'DEFAULT_DNS 必须是 cloudflare、dnspod 或 aliyun'; return 1; }
  valid_choice "$DEFAULT_KEY_TYPE" ec-256 rsa-2048 rsa-3072 rsa-4096 || { error 'DEFAULT_KEY_TYPE 无效'; return 1; }
  valid_bool "$AUTO_RENEW" || { error 'AUTO_RENEW 必须是 true 或 false'; return 1; }
  valid_bool "$NOTIFY_ENABLED" || { error 'NOTIFY_ENABLED 必须是 true 或 false'; return 1; }
  [[ "$NOTIFY_LEVEL" =~ ^[0-3]$ ]] || { error 'NOTIFY_LEVEL 必须是 0-3'; return 1; }
  [[ "$EXPIRY_DAYS" =~ ^[0-9]+$ ]] || { error 'EXPIRY_DAYS 必须是非负整数'; return 1; }
  valid_choice "$SMTP_SECURE" none tls ssl || { error 'SMTP_SECURE 必须是 none、tls 或 ssl'; return 1; }
  valid_abs_path "$CERT_DIR" || { error 'CERT_DIR 必须是绝对路径'; return 1; }
  valid_abs_path "$LOG_DIR" || { error 'LOG_DIR 必须是绝对路径'; return 1; }
  valid_abs_path "$ACME_HOME" || { error 'ACME_HOME 必须是绝对路径'; return 1; }
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
  success "配置已写入 $file"
}

config_ensure_dirs() {
  mkdir -p "$LOG_DIR" "$CERT_DIR" "$ACME_HOME"
  chmod 700 "$ACME_HOME"
  chmod 750 "$LOG_DIR" 2>/dev/null || true
  chmod 750 "$CERT_DIR" 2>/dev/null || true
  [[ -f "$CONFIG_FILE" ]] || config_write >/dev/null
}

config_show() {
  printf '配置文件: %s\n' "$CONFIG_FILE"
  printf 'ACME_HOME: %s\n证书目录: %s\n日志目录: %s\n' "$ACME_HOME" "$CERT_DIR" "$LOG_DIR"
  printf '默认 CA: %s\n默认 DNS: %s\n默认密钥: %s\n' "$DEFAULT_CA" "$DEFAULT_DNS" "$DEFAULT_KEY_TYPE"
  printf '自动续期: %s\n通知: %s (级别 %s)\n过期提醒: %s 天\n' "$AUTO_RENEW" "$NOTIFY_ENABLED" "$NOTIFY_LEVEL" "$EXPIRY_DAYS"
  printf 'SMTP: %s:%s (%s), from=%s, to=%s\n' "${SMTP_HOST:-未配置}" "${SMTP_PORT:-默认}" "$SMTP_SECURE" "${SMTP_FROM:-未配置}" "${SMTP_TO:-未配置}"
}

config_doctor() {
  local rc=0
  config_validate || rc=1
  [[ -r "$CONFIG_FILE" && "$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null || stat -f '%Lp' "$CONFIG_FILE" 2>/dev/null)" =~ ^(600|640|644)$ ]] || { warn "配置文件不可读或权限异常: $CONFIG_FILE"; rc=1; }
  [[ -d "$ACME_HOME" ]] || { warn "ACME_HOME 不存在: $ACME_HOME"; rc=1; }
  [[ -d "$CERT_DIR" ]] || { warn "证书目录不存在: $CERT_DIR"; rc=1; }
  return "$rc"
}
