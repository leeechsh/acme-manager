#!/usr/bin/env bash
# ACME Manager: a thin interactive/CLI layer over acme.sh.

SOURCE_FILE="${BASH_SOURCE[0]}"
while [[ -h "$SOURCE_FILE" ]]; do
  SOURCE_DIR=$(CDPATH= cd -- "$(dirname -- "$SOURCE_FILE")" && pwd)
  SOURCE_FILE=$(readlink "$SOURCE_FILE")
  [[ "$SOURCE_FILE" == /* ]] || SOURCE_FILE="$SOURCE_DIR/$SOURCE_FILE"
done
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$SOURCE_FILE")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=lib/ca.sh
source "$SCRIPT_DIR/lib/ca.sh"
# shellcheck source=lib/dns.sh
source "$SCRIPT_DIR/lib/dns.sh"
# shellcheck source=lib/deploy.sh
source "$SCRIPT_DIR/lib/deploy.sh"
# shellcheck source=lib/notify.sh
source "$SCRIPT_DIR/lib/notify.sh"
# shellcheck source=lib/cert.sh
source "$SCRIPT_DIR/lib/cert.sh"
# shellcheck source=lib/menu.sh
source "$SCRIPT_DIR/lib/menu.sh"

set -Eeuo pipefail
umask 077

on_error() {
  local rc=$? line=$1
  error "命令失败（退出码 $rc，行 $line），详见 $(_log_file)"
  return "$rc"
}
trap 'on_error $LINENO' ERR

usage() {
  cat <<'EOF_USAGE'
用法: acme-manager [全局选项] <命令> [参数]

交互:
  menu                              打开数字菜单（默认）

证书:
  issue --domain example.com [--domain '*.example.com'] [--dns cloudflare]
        [--ca letsencrypt|zerossl] [--key-type ec-256|rsa-2048|rsa-3072|rsa-4096]
        [--email ops@example.com] [--staging]
  list                              列出 acme.sh 证书
  info --domain example.com         查看证书详情
  renew --domain example.com [--force] [--key-type ...]
  renew --all [--force]
  deploy --domain example.com [--target-dir /etc/ssl/acme/example.com]
         [--key-file ...] [--fullchain-file ...] [--ca-file ...] [--cert-file ...]
         [--reloadcmd 'nginx -t && systemctl reload nginx']
  revoke --domain example.com       撤销并删除（危险操作，仍会二次确认）
  remove --domain example.com       删除本地管理记录（危险操作，仍会二次确认）
  expiry [天数]                     检查部署目录中的证书有效期

账户与系统:
  dns status [cloudflare|dnspod|aliyun]
  dns configure [cloudflare|dnspod|aliyun]
  dns remove [cloudflare|dnspod|aliyun]
  ca default [letsencrypt|zerossl]
  ca register [letsencrypt|zerossl] [email]
  notify status|configure|test
  cron status|install|remove
  doctor                            检查依赖、配置、账户和 Cron
  config show|write
  logs                              查看管理器日志
  update                            从 GitHub 更新管理器代码
  version

环境变量:
  ACME_MANAGER_CONFIG               配置文件路径
  ACME_HOME                         acme.sh 原生目录
  ACME_SH_BIN                       acme.sh 可执行文件路径
EOF_USAGE
}

require_arg() { [[ $# -ge 2 && -n "${2:-}" ]] || { error "$1 需要参数"; return 2; }; }

command_dispatch() {
  local command="${1:-menu}"
  [[ $# -gt 0 ]] && shift || true
  case "$command" in
    menu|interactive) main_menu;;
    issue) cert_issue "$@";;
    list) cert_list;;
    info) [[ "${1:-}" == --domain ]] && require_arg info "$@" && cert_info "$2" || { error 'info 用法: info --domain example.com'; return 2; };;
    renew) cert_renew "$@";;
    deploy) deploy_noninteractive "$@";;
    revoke) [[ "${1:-}" == --domain ]] && require_arg revoke "$@" && cert_remove "$2" true || { error 'revoke 用法: revoke --domain example.com'; return 2; };;
    remove) [[ "${1:-}" == --domain ]] && require_arg remove "$@" && cert_remove "$2" false || { error 'remove 用法: remove --domain example.com'; return 2; };;
    expiry) cert_expiry_check "${1:-$EXPIRY_DAYS}";;
    dns)
      local sub="${1:-status}"; [[ $# -gt 0 ]] && shift || true
      case "$sub" in status) dns_status "${1:-$DEFAULT_DNS}";; configure) dns_configure "${1:-$DEFAULT_DNS}";; remove) dns_remove "${1:-$DEFAULT_DNS}";; *) error 'dns 用法: status|configure|remove'; return 2;; esac;;
    ca)
      local sub="${1:-show}"; [[ $# -gt 0 ]] && shift || true
      case "$sub" in default) ca_set_default "${1:-$DEFAULT_CA}";; register) ca_register "${1:-$DEFAULT_CA}" "${2:-}";; show) ca_show;; *) error 'ca 用法: default|register|show'; return 2;; esac;;
    notify)
      local sub="${1:-status}"; case "$sub" in status) notify_status;; configure) notify_configure;; test) notify_test;; *) error 'notify 用法: status|configure|test'; return 2;; esac;;
    cron)
      local sub="${1:-status}"; case "$sub" in status) menu_cron_status;; install) menu_cron_install;; remove) menu_cron_remove;; *) error 'cron 用法: status|install|remove'; return 2;; esac;;
    doctor) menu_doctor;;
    config)
      case "${1:-show}" in show) config_show;; write) config_write;; *) error 'config 用法: show|write'; return 2;; esac;;
    logs) menu_logs;;
    update) "$SCRIPT_DIR/install.sh" --update "$@";;
    version) printf '%s %s\n' "$ACME_MANAGER_NAME" "$ACME_MANAGER_VERSION";;
    help|-h|--help) usage;;
    *) error "未知命令: $command"; usage; return 2;;
  esac
}

main() {
  ui_init
  config_load
  config_ensure_dirs
  command_dispatch "$@"
}

main "$@"
