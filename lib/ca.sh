#!/usr/bin/env bash

ca_name() { case "$1" in letsencrypt) printf "Let's Encrypt\n" ;; zerossl) printf 'ZeroSSL\n' ;; *) printf '%s\n' "$1" ;; esac; }
ca_set_default() {
  local ca="${1:-$DEFAULT_CA}"
  valid_choice "$ca" letsencrypt zerossl || { error 'Only letsencrypt and zerossl are supported'; return 1; }
  run_acme_logged ca-set-default --set-default-ca --server "$ca" || { error "Failed to switch CA: $ca"; return 1; }
  DEFAULT_CA="$ca"; config_write >/dev/null
  success "Default CA: $(ca_name "$ca")"
}
ca_register() {
  local ca="${1:-$DEFAULT_CA}" email="${2:-}"
  [[ -n "$email" ]] || email=$(prompt_value 'Account email')
  [[ "$email" == *@*.* ]] || { error 'The email format looks invalid'; return 1; }
  run_acme_logged ca-register --register-account -m "$email" --server "$ca" || { error 'ACME account registration failed'; return 1; }
  success 'ACME account registered or confirmed'
}
ca_show() {
  ensure_acme || return 1
  printf 'Default CA: %s (%s)\n' "$DEFAULT_CA" "$(ca_name "$DEFAULT_CA")"
  printf 'acme.sh default CA status:\n'
  run_acme --set-default-ca --server "$DEFAULT_CA" --debug 1 2>&1 | tail -20 || true
}
ca_menu() {
  while true; do
    menu_header 'Certificate Authorities' 'Choose the issuer and manage the ACME account'
    menu_home_status
    ui_section 'Actions'
    ui_menu_item 1 'View current CA' 'Default issuer and account status'
    ui_menu_item 2 'Switch default CA' "Let's Encrypt / ZeroSSL"
    ui_menu_item 3 'Register / update account' 'Register an ACME account with an email'
    ui_menu_item 0 'Back'
    ui_footer
    menu_choice 'Choose an action [0-3]:' || return 0
    case "$MENU_CHOICE" in
      1) ca_show || true; pause_screen;;
      2)
        local ca_choice
        ca_choice=$(prompt_value 'CA (letsencrypt/zerossl)' "$DEFAULT_CA")
        ca_set_default "$ca_choice" || true
        pause_screen
        ;;
      3) ca_register "$DEFAULT_CA" || true; pause_screen;;
      0) return 0;; *) warn 'Invalid choice';;
    esac
  done
}
