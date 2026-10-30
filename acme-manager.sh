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
# shellcheck source=lib/webdav.sh
source "$SCRIPT_DIR/lib/webdav.sh"
# shellcheck source=lib/meta.sh
source "$SCRIPT_DIR/lib/meta.sh"
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
  error "Command failed (exit code $rc, line $line); see $(_log_file)"
  return "$rc"
}
trap 'on_error $LINENO' ERR

usage() {
  cat <<'EOF_USAGE'
Usage: acme-manager [global options] <command> [arguments]

Interactive:
  menu                              Open the numbered menu (default)

Certificates:
  issue --domain example.com [--domain '*.example.com'] [--no-wildcard] [--force] [--dns cloudflare]
        [--ca letsencrypt|zerossl] [--key-type ec-256|rsa-2048|rsa-3072|rsa-4096]
        [--email ops@example.com] [--staging]
  list                              List acme.sh certificates
  info --domain example.com         Show certificate details
  renew --domain example.com [--force] [--key-type ...]
  renew --all [--force]
  deploy --domain example.com [--target-dir /var/cert/example.com]
         [--key-file ...] [--fullchain-file ...] [--ca-file ...] [--cert-file ...]
         [--reloadcmd 'nginx -t && systemctl reload nginx']
  revoke --domain example.com       Revoke and remove (confirmation required)
  remove --domain example.com       Remove local record (confirmation required)
  expiry [days]                     Check deployed certificate expiry

Accounts and system:
  dns status|configure|remove [provider]
  ca default|register|show [ca] [email]
  notify status|configure|test
  cron status|install|remove
  doctor                            Check dependencies, config, account and Cron
  config show|write
  logs                              View manager logs
  webdav status|configure|test|sync
                                  Manage WebDAV certificate synchronization
  meta sync                        Regenerate certificate metadata and sync it
  update                            Update manager code from GitHub
  version

Environment:
  ACME_MANAGER_CONFIG               Config file path
  ACME_HOME                         Native acme.sh home
  ACME_SH_BIN                       acme.sh executable path
EOF_USAGE
}

require_arg() { [[ $# -ge 2 && -n "${2:-}" ]] || { error "$1 requires an argument"; return 2; }; }

command_dispatch() {
  local command="${1:-menu}"
  [[ $# -gt 0 ]] && shift || true
  case "$command" in
    menu|interactive) main_menu;;
    issue) cert_issue "$@";;
    list) cert_list;;
    info) [[ "${1:-}" == --domain ]] && require_arg info "$@" && cert_info "$2" || { error 'Usage: info --domain example.com'; return 2; };;
    renew) cert_renew "$@";;
    deploy) deploy_noninteractive "$@";;
    revoke) [[ "${1:-}" == --domain ]] && require_arg revoke "$@" && cert_remove "$2" true || { error 'Usage: revoke --domain example.com'; return 2; };;
    remove) [[ "${1:-}" == --domain ]] && require_arg remove "$@" && cert_remove "$2" false || { error 'Usage: remove --domain example.com'; return 2; };;
    expiry) cert_expiry_check "${1:-$EXPIRY_DAYS}";;
    dns)
      local sub="${1:-status}"; [[ $# -gt 0 ]] && shift || true
      case "$sub" in status) dns_status "${1:-$DEFAULT_DNS}";; configure) dns_configure "${1:-$DEFAULT_DNS}";; remove) dns_remove "${1:-$DEFAULT_DNS}";; *) error 'Usage: dns status|configure|remove'; return 2;; esac;;
    ca)
      local sub="${1:-show}"; [[ $# -gt 0 ]] && shift || true
      case "$sub" in default) ca_set_default "${1:-$DEFAULT_CA}";; register) ca_register "${1:-$DEFAULT_CA}" "${2:-}";; show) ca_show;; *) error 'Usage: ca default|register|show'; return 2;; esac;;
    notify)
      local sub="${1:-status}"; case "$sub" in status) notify_status;; configure) notify_configure;; test) notify_test;; *) error 'Usage: notify status|configure|test'; return 2;; esac;;
    cron)
      local sub="${1:-status}"; case "$sub" in status) menu_cron_status;; install) menu_cron_install;; remove) menu_cron_remove;; *) error 'Usage: cron status|install|remove'; return 2;; esac;;
    doctor) menu_doctor;;
    config)
      case "${1:-show}" in show) config_show;; write) config_write;; *) error 'Usage: config show|write'; return 2;; esac;;
    logs) menu_logs;;
    webdav)
      local sub="${1:-status}"; case "$sub" in status) webdav_status;; configure) webdav_configure;; test) webdav_test;; sync) meta_sync;; *) error 'Usage: webdav status|configure|test|sync'; return 2;; esac;;
    meta)
      case "${1:-sync}" in sync) meta_sync;; *) error 'Usage: meta sync'; return 2;; esac;;
    update) "$SCRIPT_DIR/install.sh" --update "$@";;
    version) printf '%s %s\n' "$ACME_MANAGER_NAME" "$ACME_MANAGER_VERSION";;
    help|-h|--help) usage;;
    *) error "Unknown command: $command"; usage; return 2;;
  esac
}

main() {
  ui_init
  config_load
  config_ensure_dirs
  command_dispatch "$@"
}

main "$@"
