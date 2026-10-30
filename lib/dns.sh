#!/usr/bin/env bash

dns_hook() { case "$1" in cloudflare) printf 'dns_cf\n' ;; dnspod) printf 'dns_tencent\n' ;; aliyun) printf 'dns_ali\n' ;; *) return 1 ;; esac; }
dns_label() { case "$1" in cloudflare) printf 'Cloudflare\n' ;; dnspod) printf 'Tencent DNSPod\n' ;; aliyun) printf 'Alibaba Cloud DNS\n' ;; *) printf '%s\n' "$1" ;; esac; }
dns_keys() { case "$1" in cloudflare) printf 'CF_Token\nCF_Account_ID\n' ;; dnspod) printf 'Tencent_SecretId\nTencent_SecretKey\nTencent_SessionToken\nTencent_Region\n' ;; aliyun) printf 'Ali_Key\nAli_Secret\nAli_SecurityToken\n' ;; *) return 1 ;; esac; }

dns_status() {
  local provider="${1:-$DEFAULT_DNS}" key value configured=0
  valid_choice "$provider" cloudflare dnspod aliyun || { error 'Unknown DNS provider'; return 1; }
  printf '%s (%s)\n' "$(dns_label "$provider")" "$(dns_hook "$provider")"
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    if value=$(account_get_var "$key" 2>/dev/null) && [[ -n "$value" ]]; then
      printf '  %-24s %sconfigured%s\n' "$key" "$UI_SUCCESS" "$UI_RESET"
      configured=1
    else
      printf '  %-24s %snot configured%s\n' "$key" "$UI_MUTED" "$UI_RESET"
    fi
  done < <(dns_keys "$provider")
  (( configured )) || warn 'No credentials found; configure this provider first'
  return 0
}

dns_configure() {
  local provider="${1:-$DEFAULT_DNS}" value key
  valid_choice "$provider" cloudflare dnspod aliyun || { error 'Unknown DNS provider'; return 1; }
  case "$provider" in
    cloudflare)
      value=$(prompt_value 'Cloudflare API token (empty cancels)') || return 1
      [[ -n "$value" ]] || { warn 'Cancelled'; return 1; }
      account_set_var CF_Token "$value"
      local account_id
      account_id=$(prompt_value 'Cloudflare account ID (optional)' '')
      if [[ -n "$account_id" ]]; then account_set_var CF_Account_ID "$account_id"; else account_unset_var CF_Account_ID; fi
      ;;
    dnspod)
      value=$(prompt_value 'DNSPod SecretId') || return 1
      [[ -n "$value" ]] || { warn 'Cancelled'; return 1; }
      account_set_var Tencent_SecretId "$value"
      value=$(prompt_secret 'DNSPod SecretKey') || return 1
      [[ -n "$value" ]] || { error 'SecretKey cannot be empty'; return 1; }
      account_set_var Tencent_SecretKey "$value"
      value=$(prompt_secret 'DNSPod session token (optional)') || return 1
      if [[ -n "$value" ]]; then account_set_var Tencent_SessionToken "$value"; else account_unset_var Tencent_SessionToken; fi
      value=$(prompt_value 'DNSPod region (optional)' '') || return 1
      if [[ -n "$value" ]]; then account_set_var Tencent_Region "$value"; else account_unset_var Tencent_Region; fi
      ;;
    aliyun)
      value=$(prompt_value 'Alibaba Cloud AccessKey ID') || return 1
      [[ -n "$value" ]] || { warn 'Cancelled'; return 1; }
      account_set_var Ali_Key "$value"
      value=$(prompt_secret 'Alibaba Cloud AccessKey Secret') || return 1
      [[ -n "$value" ]] || { error 'AccessKey Secret cannot be empty'; return 1; }
      account_set_var Ali_Secret "$value"
      value=$(prompt_secret 'Alibaba Cloud security token (optional)') || return 1
      if [[ -n "$value" ]]; then account_set_var Ali_SecurityToken "$value"; else account_unset_var Ali_SecurityToken; fi
      ;;
  esac
  chmod 600 "$(account_conf_path)"
  success "$(dns_label "$provider") credentials saved to the native acme.sh account config"
  dns_status "$provider" >/dev/null || true
}

dns_remove() {
  local provider="${1:-$DEFAULT_DNS}" key
  confirm "Remove $(dns_label "$provider") credentials?" || { warn 'Cancelled'; return 1; }
  while IFS= read -r key; do [[ -n "$key" ]] && account_unset_var "$key"; done < <(dns_keys "$provider")
  success 'DNS credentials removed'
}

dns_menu() {
  while true; do
    menu_header 'DNS API Accounts' 'Credentials are stored in the native acme.sh account.conf'
    menu_home_status
    ui_section 'Actions'
    ui_menu_item 1 'View credential status' 'Only configured / missing is shown'
    ui_menu_item 2 'Configure / update' 'Cloudflare / DNSPod / Alibaba Cloud DNS'
    ui_menu_item 3 'Remove credentials' 'Destructive action; confirmation required'
    ui_menu_item 0 'Back'
    ui_footer
    menu_choice 'Choose an action [0-3]:' || return 0
    local provider
    case "$MENU_CHOICE" in
      1) provider=$(prompt_value 'Provider (cloudflare/dnspod/aliyun)' "$DEFAULT_DNS"); dns_status "$provider" || true; pause_screen;;
      2) provider=$(prompt_value 'Provider (cloudflare/dnspod/aliyun)' "$DEFAULT_DNS"); dns_configure "$provider" || true; pause_screen;;
      3) provider=$(prompt_value 'Provider (cloudflare/dnspod/aliyun)' "$DEFAULT_DNS"); dns_remove "$provider" || true; pause_screen;;
      0) return 0;; *) warn 'Invalid choice';;
    esac
  done
}
