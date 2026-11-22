#!/usr/bin/env bash

dns_hook() {
  case "$1" in
    cloudflare) printf 'dns_cf\n';;
    dnspod) printf 'dns_tencent\n';;
    aliyun) printf 'dns_ali\n';;
    *) return 1;;
  esac
}

dns_label() {
  case "$1" in
    cloudflare) printf 'Cloudflare\n';;
    dnspod) printf 'Tencent DNSPod\n';;
    aliyun) printf 'Alibaba Cloud DNS\n';;
    *) printf '%s\n' "$1";;
  esac
}

dns_select_provider() {
  prompt_select 'Select a DNS provider' "$1" \
    cloudflare 'Cloudflare' dnspod 'Tencent DNSPod' aliyun 'Alibaba Cloud DNS'
}

# Fields are stored in this order. Keep the existing Cloudflare profile format.
dns_credential_fields() {
  case "$1" in
    cloudflare)
      printf '%s\n' 'CF_Token|required|Cloudflare API token' 'CF_Account_ID|optional|Cloudflare account ID';;
    dnspod)
      printf '%s\n' 'Tencent_SecretId|required|DNSPod SecretId' 'Tencent_SecretKey|required|DNSPod SecretKey' \
        'Tencent_SessionToken|optional|DNSPod session token' 'Tencent_Region|optional|DNSPod region';;
    aliyun)
      printf '%s\n' 'Ali_Key|required|Alibaba Cloud AccessKey ID' 'Ali_Secret|required|Alibaba Cloud AccessKey Secret' \
        'Ali_SecurityToken|optional|Alibaba Cloud security token';;
    *) return 1;;
  esac
}

dns_legacy_value() {
  local key="$1" value
  value="${!key:-}"
  [[ -n "$value" ]] || value=$(account_get_var "$key" || true)
  [[ -n "$value" ]] || value=$(account_get_var "SAVED_$key" || true)
  [[ -n "$value" ]] || return 1
  printf '%s\n' "$value"
}

dns_has_legacy_credentials() {
  local key required label
  while IFS='|' read -r key required label; do
    if [[ "$required" == required ]]; then dns_legacy_value "$key" >/dev/null || return 1; fi
  done < <(dns_credential_fields "$1")
}

dns_collect_credentials() {
  local provider="$1" source="$2" key required label value
  local -n collected="$3"
  while IFS='|' read -r -u 3 key required label; do
    if [[ "$source" == legacy ]]; then
      value=$(dns_legacy_value "$key") || value=''
    else
      if [[ "$required" == optional ]]; then label+=' (optional)'; fi
      value=$(prompt_value "$label") || return 1
    fi
    if [[ "$required" == required && -z "$value" ]]; then
      error "$label is required"
      return 1
    fi
    [[ "$value" != *$'\r'* && "$value" != *$'\n'* ]] || { error "Invalid value for $label"; return 1; }
    collected+=("$value")
  done 3< <(dns_credential_fields "$provider")
}

dns_status() {
  local provider="${1:-$DEFAULT_DNS}" key required label profile named=0
  valid_choice "$provider" cloudflare dnspod aliyun || { error 'Unknown DNS provider'; return 1; }
  printf '%s (%s)\n  Legacy acme.sh credentials\n' "$(dns_label "$provider")" "$(dns_hook "$provider")"
  while IFS='|' read -r key required label; do
    if dns_legacy_value "$key" >/dev/null; then
      printf '  %-24s %sconfigured%s\n' "$key" "$UI_SUCCESS" "$UI_RESET"
    else
      printf '  %-24s %snot configured%s\n' "$key" "$UI_MUTED" "$UI_RESET"
    fi
  done < <(dns_credential_fields "$provider")
  printf '  Named DNS profiles\n'
  while IFS= read -r profile; do
    printf '  Profile: %s\n' "$profile"
    named=1
  done < <(dns_profiles "$provider")
  (( named )) || ui_hint '  None. Choose Add profile or Import legacy credentials.'
}

dns_configure() {
  local provider="${1:-$DEFAULT_DNS}" profile="${2:-}" key required label index=0
  local -a credentials=()
  valid_choice "$provider" cloudflare dnspod aliyun || { error 'Unknown DNS provider'; return 1; }
  if [[ -n "$profile" ]]; then
    dns_configure_profile "$provider" "$profile"
    return
  fi
  dns_collect_credentials "$provider" prompt credentials || return 1
  while IFS='|' read -r key required label; do
    if [[ -n "${credentials[index]}" ]]; then
      account_set_var "$key" "${credentials[index]}" || return 1
    else
      account_unset_var "$key" || return 1
      account_unset_var "SAVED_$key" || return 1
    fi
    index=$((index + 1))
  done < <(dns_credential_fields "$provider")
  success "$(dns_label "$provider") credentials saved to the native acme.sh account config"
}

dns_remove() {
  local provider="${1:-$DEFAULT_DNS}" profile="${2:-}" key required label
  valid_choice "$provider" cloudflare dnspod aliyun || { error 'Unknown DNS provider'; return 1; }
  if [[ -n "$profile" ]]; then
    dns_remove_profile "$provider" "$profile"
    return
  fi
  confirm "Remove legacy $(dns_label "$provider") credentials?" || return 1
  while IFS='|' read -r key required label; do
    account_unset_var "$key" || return 1
    account_unset_var "SAVED_$key" || return 1
  done < <(dns_credential_fields "$provider")
  success 'Legacy DNS credentials removed'
}

dns_menu() {
  while true; do
    menu_header 'DNS API Accounts' 'Manage DNS credential profiles by provider'
    ui_section 'DNS providers'
    ui_menu_item 1 'Cloudflare'
    ui_menu_item 2 'Tencent DNSPod'
    ui_menu_item 3 'Alibaba Cloud DNS'
    ui_menu_item 0 'Back'
    ui_footer
    menu_choice 'Choose a provider [0-3]:' || return 0
    case "$MENU_CHOICE" in
      1) dns_profile_menu cloudflare;;
      2) dns_profile_menu dnspod;;
      3) dns_profile_menu aliyun;;
      0) return 0;;
      *) warn 'Invalid choice';;
    esac
  done
}
