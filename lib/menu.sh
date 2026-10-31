#!/usr/bin/env bash

menu_choice() {
  local label="${1:-Choose}" value
  read -r -p "$(printf '%s%s%s ' "$UI_ACCENT" "$label" "$UI_RESET")" value || return 1
  MENU_CHOICE="$value"
}

menu_header() {
  local title="$1" subtitle="${2:-}"
  ui_clear
  ui_title "$title" "$subtitle"
}

menu_home_status() {
  ui_status_strip "$(ca_name "$DEFAULT_CA")" "$(dns_label "$DEFAULT_DNS")" "$DEFAULT_KEY_TYPE"
}

menu_doctor() {
  local rc=0 version
  menu_header 'Diagnostics' 'Check dependencies, permissions, account state and renewal'
  menu_home_status
  printf '\n'
  if ensure_acme; then
    version=$(run_acme --version 2>&1 | head -1 || true)
    printf '  %sacme.sh%s       %s\n' "$UI_MUTED" "$UI_RESET" "${version:-available}"
  else
    rc=1
  fi
  config_doctor || rc=1
  [[ -f "$(account_conf_path)" ]] || { warn "Account config is missing: $(account_conf_path)"; rc=1; }
  command_exists openssl || { warn 'openssl is not installed'; rc=1; }
  command_exists curl || command_exists python3 || command_exists python || { warn 'curl or Python is required by some DNS/SMTP operations'; rc=1; }
  if crontab -l 2>/dev/null | grep -Fq 'acme.sh'; then
    printf '  %sCron%s         %sinstalled%s\n' "$UI_MUTED" "$UI_RESET" "$UI_SUCCESS" "$UI_RESET"
  else
    printf '  %sCron%s         %snot detected%s\n' "$UI_MUTED" "$UI_RESET" "$UI_WARNING" "$UI_RESET"
  fi
  printf '\n'
  (( rc == 0 )) && success 'Doctor checks passed' || warn 'Doctor found issues; review the messages above'
  return "$rc"
}

menu_cron_status() {
  menu_header 'Auto Renewal' 'Use acme.sh native Cron; no second scheduler is created'
  menu_home_status
  printf '\n'
  if crontab -l 2>/dev/null | grep -Fq 'acme.sh'; then
    printf '%sStatus%s  %sinstalled%s\n\n' "$UI_MUTED" "$UI_RESET" "$UI_SUCCESS" "$UI_RESET"
    crontab -l 2>/dev/null | grep -F 'acme.sh' || true
  else
    printf '%sStatus%s  %sacme.sh Cron not detected%s\n' "$UI_MUTED" "$UI_RESET" "$UI_WARNING" "$UI_RESET"
  fi
}

menu_cron_install() {
  run_acme_logged cron-install --install-cronjob && success 'acme.sh Cron installed' || return 1
}

menu_cron_remove() {
  confirm 'Remove the acme.sh Cron job?' || return 1
  run_acme_logged cron-remove --uninstall-cronjob && success 'acme.sh Cron removed'
}

menu_logs() {
  menu_header 'Runtime Logs' 'The latest 80 ACME Manager records'
  printf '%sLog file%s  %s\n\n' "$UI_MUTED" "$UI_RESET" "$(_log_file)"
  if [[ -f "$(_log_file)" ]]; then
    tail -80 "$(_log_file)"
  else
    ui_hint 'No manager log yet. Run an issue, renew or doctor operation first.'
  fi
}

menu_global() {
  while true; do
    menu_header 'Settings / Update' 'Manage defaults and the acme.sh version'
    menu_home_status
    ui_section 'Configuration'
    ui_menu_item 1 'View current config' 'Paths, notifications and defaults'
    ui_menu_item 2 'Edit default values' 'CA, DNS, key type and notifications'
    ui_section 'Maintenance'
    ui_menu_item 3 'Run doctor' 'Check dependencies, permissions and Cron'
    ui_menu_item 4 'Upgrade acme.sh' 'Use the native acme.sh upgrade command'
    ui_menu_item 0 'Back'
    ui_footer 'Enter a number to choose  ·  Ctrl+C to exit'
    menu_choice 'Choose an action [0-4]:' || return 0
    case "$MENU_CHOICE" in
      1) config_show; pause_screen;;
      2)
        DEFAULT_CA=$(prompt_select 'Default certificate authority' "$DEFAULT_CA" \
          letsencrypt "Let's Encrypt" \
          zerossl 'ZeroSSL')
        DEFAULT_DNS=$(prompt_select 'Default DNS provider' "$DEFAULT_DNS" \
          cloudflare 'Cloudflare' \
          dnspod 'Tencent DNSPod' \
          aliyun 'Alibaba Cloud DNS')
        DEFAULT_KEY_TYPE=$(prompt_select 'Default key type' "$DEFAULT_KEY_TYPE" \
          ec-256 'ECDSA P-256' \
          rsa-2048 'RSA 2048' \
          rsa-3072 'RSA 3072' \
          rsa-4096 'RSA 4096')
        CERT_DIR=$(prompt_value 'Certificate directory' "$CERT_DIR")
        AUTO_RENEW=$(prompt_select 'Auto renewal' "$AUTO_RENEW" \
          true 'Enabled' \
          false 'Disabled')
        NOTIFY_ENABLED=$(prompt_select 'Notifications' "$NOTIFY_ENABLED" \
          true 'Enabled' \
          false 'Disabled')
        NOTIFY_LEVEL=$(prompt_select 'Notification level' "$NOTIFY_LEVEL" \
          0 'Disabled' \
          1 'Errors only' \
          2 'Warnings and errors' \
          3 'All events')
        config_write || true
        pause_screen
        ;;
      3) menu_doctor || true; pause_screen;;
      4) ensure_acme && run_acme_logged upgrade --upgrade && success 'acme.sh upgraded' || warn 'acme.sh upgrade failed'; pause_screen;;
      0) return 0;;
      *) warn 'Invalid choice; enter 0-4';;
    esac
  done
}

main_menu() {
  while true; do
    menu_header 'ACME Manager' 'Lightweight SSL/TLS certificate management'
    printf '%sVersion%s  %s  %sConfig%s  %s\n' "$UI_MUTED" "$UI_RESET" "$ACME_MANAGER_VERSION" "$UI_MUTED" "$UI_RESET" "$CONFIG_FILE"
    menu_home_status

    ui_section 'Certificate Lifecycle'
    ui_menu_item 1 'Issue certificate' 'Issue, then deploy automatically'
    ui_menu_item 2 'List certificates' 'Validity, CA and deployment paths'
    ui_menu_item 3 'Renew certificate' 'One certificate or all certificates'
    ui_menu_item 4 'Deploy certificate' 'Paths, permissions and reload hook'
    ui_menu_item 5 'Remove / revoke' 'Destructive action; confirmation required'

    ui_section 'Accounts & Notifications'
    ui_menu_item 6 'DNS API accounts' 'Cloudflare / DNSPod / AliDNS'
    ui_menu_item 7 'Certificate authorities' "Let's Encrypt / ZeroSSL"
    ui_menu_item 8 'Auto renewal' 'View, install or remove Cron'
    ui_menu_item 9 'Email notifications' 'SMTP configuration and test email'

    ui_section 'Maintenance'
    ui_menu_item 10 'WebDAV synchronization' 'Upload certificates and metadata'
    ui_menu_item 11 'Certificate Agent' 'Pull changed certificates from WebDAV'
    ui_menu_item 12 'Logs & diagnostics' 'View logs and run doctor'
    ui_menu_item 13 'Settings / update' 'Defaults and acme.sh maintenance'
    ui_menu_item 0 'Exit' 'Return to the shell'
    ui_footer 'Enter a number to choose  ·  Credentials are never printed to logs'

    menu_choice 'Choose an action [0-13]:' || break
    case "$MENU_CHOICE" in
      1) cert_issue_and_deploy || true; pause_screen;;
      2) cert_list || true; pause_screen;;
      3)
        local domain
        domain=$(prompt_value 'Domain (leave empty to renew all)' '')
        if [[ -n "$domain" ]]; then cert_renew --domain "$domain" || true; else cert_renew --all || true; fi
        pause_screen
        ;;
      4)
        local domain
        domain=$(prompt_value 'Domain')
        deploy_cert "$domain" "$DEFAULT_KEY_TYPE" || true
        pause_screen
        ;;
      5)
        local domain revoke_choice
        domain=$(prompt_value 'Domain')
        revoke_choice=$(prompt_select 'Also revoke the certificate at the CA?' false \
          false 'No' \
          true 'Yes')
        cert_remove "$domain" "$revoke_choice" || true
        pause_screen
        ;;
      6) dns_menu || true;;
      7) ca_menu || true;;
      8)
        menu_cron_status
        ui_section 'Actions'
        ui_menu_item 1 'Install / repair Cron' 'Let acme.sh manage the schedule'
        ui_menu_item 2 'Remove Cron' 'Certificates and accounts are kept'
        ui_menu_item 0 'Back'
        ui_footer
        menu_choice 'Choose an action [0-2]:' || true
        case "$MENU_CHOICE" in 1) menu_cron_install || true;; 2) menu_cron_remove || true;; esac
        pause_screen
        ;;
      9) notify_menu || true;;
      10) webdav_menu || true;;
      11) agent_menu || true;;
      12) menu_logs; menu_doctor || true; pause_screen;;
      13) menu_global || true;;
      0) break;;
      *) warn 'Invalid choice; enter 0-13';;
    esac
  done
}
