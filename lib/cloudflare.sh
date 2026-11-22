#!/usr/bin/env bash

cf_valid_profile() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9_]{0,47}$ && "$1" != legacy ]]
}

cf_profile_dir() { printf '%s/.acme-manager-cloudflare\n' "$ACME_HOME"; }

cf_profiles() {
  local file name
  for file in "$(cf_profile_dir)"/*; do
    [[ -f "$file" ]] || continue
    name=${file##*/}
    if cf_valid_profile "$name"; then printf '%s\n' "$name"; fi
  done
}

cf_has_legacy_token() {
  local value
  [[ -n "${CF_Token:-}" ]] && return 0
  value=$(account_get_var CF_Token || account_get_var SAVED_CF_Token) || return 1
  [[ -n "$value" ]]
}

cf_install_hook() {
  local profile="$1" hook="dns_amcf_$1" template
  template=$(cat "$SCRIPT_DIR/lib/cloudflare-hook.sh") || return 1
  {
    printf '%s\n' "$template"
    printf '\n%s_add() { _amcf_run %s add "$@"; }\n' "$hook" "$profile"
    printf '%s_rm() { _amcf_run %s rm "$@"; }\n' "$hook" "$profile"
  } | atomic_write "$ACME_HOME/dnsapi/$hook.sh" 600
}

cf_configure_profile() {
  local profile="$1" token account_id
  cf_valid_profile "$profile" || {
    error 'Use 1-48 lowercase letters, digits or underscores, starting with a letter or digit; legacy is reserved'
    return 1
  }
  token=$(prompt_value 'Cloudflare API token (empty cancels)') || return 1
  [[ "$token" =~ ^[A-Za-z0-9_-]+$ ]] || { error 'Invalid or empty Cloudflare API token'; return 1; }
  account_id=$(prompt_value 'Cloudflare account ID (optional)') || return 1
  [[ "$account_id" =~ ^[A-Za-z0-9_-]*$ ]] || { error 'Invalid Cloudflare account ID'; return 1; }

  cf_install_hook "$profile" || return 1
  printf '%s\n%s\n' "$token" "$account_id" |
    atomic_write "$(cf_profile_dir)/$profile" 600 || return 1
  success "Cloudflare Token saved: $profile"
}

cf_add_profile() {
  local profile
  profile=$(prompt_value 'New Token name') || return 1
  if cf_valid_profile "$profile" && [[ -e "$(cf_profile_dir)/$profile" ]]; then
    error "Cloudflare Token already exists: $profile"
    return 1
  fi
  cf_configure_profile "$profile" >&2 || return 1
  printf '%s\n' "$profile"
}

cf_select_profile() {
  local current="$1" profile selected
  local -a options=()
  while IFS= read -r profile; do
    options+=("$profile" "$profile")
  done < <(cf_profiles)
  if [[ -z "$current" ]]; then
    if cf_has_legacy_token; then
      current=legacy
    elif (( ${#options[@]} > 2 )); then
      current=__cancel
    else
      current=${options[0]:-__new}
    fi
  elif [[ "$current" != legacy && ! -s "$(cf_profile_dir)/$current" ]]; then
    current=__cancel
  fi
  options+=(legacy 'Legacy acme.sh credentials' __new 'Add a Cloudflare Token' __cancel 'Cancel')
  selected=$(prompt_select 'Select a Cloudflare Token' "$current" "${options[@]}") || return 1
  case "$selected" in
    __cancel) return 1;;
    __new) cf_add_profile;;
    *) printf '%s\n' "$selected";;
  esac
}

cf_profile_hook() {
  local profile="$1"
  if [[ "$profile" == legacy ]]; then
    printf 'dns_cf\n'
    return 0
  fi
  if ! cf_valid_profile "$profile" || [[ ! -s "$(cf_profile_dir)/$profile" ]]; then
    error "Cloudflare Token profile not found: $profile"
    return 1
  fi
  cf_install_hook "$profile" || return 1
  printf 'dns_amcf_%s\n' "$profile"
}

cf_prompt_existing_profile() {
  local action="$1" profile selected
  local -a options=(__cancel 'Cancel')
  while IFS= read -r profile; do
    options+=("$profile" "$profile")
  done < <(cf_profiles)
  if (( ${#options[@]} == 2 )); then
    warn 'No named Cloudflare Tokens configured'
    return 1
  fi
  selected=$(prompt_select "Select a Cloudflare Token to $action" __cancel "${options[@]}") || return 1
  [[ "$selected" != __cancel ]] || return 1
  printf '%s\n' "$selected"
}

cf_profile_bindings() {
  local profile="$1" cert_home conf webroot
  cert_home=$(account_get_var CERT_HOME || true)
  cert_home="${cert_home:-${CERT_HOME:-${LE_CONFIG_HOME:-$ACME_HOME}}}"
  for conf in "$cert_home"/*/*.conf; do
    [[ -f "$conf" ]] || continue
    webroot=$(meta_conf_value "$conf" Le_Webroot) || return 1
    if [[ ",$webroot," == *",dns_amcf_$profile,"* ]]; then
      printf '%s\n' "${conf#"${cert_home%/}/"}"
    fi
  done
}

cf_remove_profile() {
  local profile="$1" file bindings
  cf_valid_profile "$profile" || { error 'Invalid Cloudflare Token name'; return 1; }
  file="$(cf_profile_dir)/$profile"
  [[ -f "$file" ]] || { error "Cloudflare Token profile not found: $profile"; return 1; }
  bindings=$(cf_profile_bindings "$profile") || return 1
  if [[ -n "$bindings" ]]; then
    error "Cloudflare Token is used by a certificate: $profile"
    printf '%s\n' "$bindings" >&2
    printf 'Choose another Token for these certificates in Renew certificate first.\n' >&2
    return 1
  fi
  confirm "Remove Cloudflare Token $profile?" || return 1
  rm -f -- "$file" "$ACME_HOME/dnsapi/dns_amcf_$profile.sh" || return 1
  success "Cloudflare Token removed: $profile"
}

cf_menu() {
  local profile
  while true; do
    menu_header 'Cloudflare Tokens' 'Manage named DNS credentials'
    ui_section 'Actions'
    ui_menu_item 1 'List Token profiles' 'Names and legacy credential status'
    ui_menu_item 2 'Add Token'
    ui_menu_item 3 'Update Token'
    ui_menu_item 4 'Remove Token' 'Available for profiles without certificate bindings'
    ui_menu_item 5 'Configure legacy credentials'
    ui_menu_item 0 'Back'
    ui_footer
    menu_choice 'Choose an action [0-5]:' || return 0
    case "$MENU_CHOICE" in
      1) dns_status cloudflare;;
      2) cf_add_profile >/dev/null || true;;
      3) if profile=$(cf_prompt_existing_profile update); then cf_configure_profile "$profile" || true; fi;;
      4) if profile=$(cf_prompt_existing_profile remove); then cf_remove_profile "$profile" || true; fi;;
      5) dns_configure cloudflare || true;;
      0) return 0;;
      *) warn 'Invalid choice';;
    esac
    pause_screen
  done
}
