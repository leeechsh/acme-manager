#!/usr/bin/env bash

dns_valid_profile() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9_]{0,47}$ && "$1" != legacy ]]
}

dns_profile_dir() { printf '%s/.acme-manager-%s\n' "$ACME_HOME" "$1"; }

dns_profile_prefix() {
  case "$1" in
    cloudflare) printf 'dns_amcf_\n';;
    dnspod) printf 'dns_amdp_\n';;
    aliyun) printf 'dns_amali_\n';;
    *) return 1;;
  esac
}

dns_profiles() {
  local directory file name
  directory=$(dns_profile_dir "$1")
  for file in "$directory"/*; do
    [[ -f "$file" ]] || continue
    name=${file##*/}
    if dns_valid_profile "$name"; then printf '%s\n' "$name"; fi
  done
}

dns_profile_binding() {
  local hook="$1" provider prefix profile
  for provider in cloudflare dnspod aliyun; do
    if [[ "$hook" == "$(dns_hook "$provider")" ]]; then
      printf '%s\tlegacy\n' "$provider"
      return 0
    fi
    prefix=$(dns_profile_prefix "$provider") || return 1
    if [[ "$hook" == "$prefix"* ]]; then
      profile=${hook#"$prefix"}
      dns_valid_profile "$profile" || return 1
      printf '%s\t%s\n' "$provider" "$profile"
      return 0
    fi
  done
  return 1
}

dns_install_profile_hook() {
  local provider="$1" profile="$2" hook native template fields='' key required label
  native=$(dns_hook "$provider") || return 1
  hook=$(dns_profile_prefix "$provider") || return 1
  hook+="$profile"
  template=$(cat "$SCRIPT_DIR/lib/dns-profile-hook.sh") || return 1
  while IFS='|' read -r key required label; do
    fields+="${fields:+ }$key"
  done < <(dns_credential_fields "$provider")
  {
    printf '%s\n' "$template"
    printf "\n%s_add() { _am_dns_run %s .acme-manager-%s/%s '%s' add \"\$@\"; }\n" "$hook" "$native" "$provider" "$profile" "$fields"
    printf "%s_rm() { _am_dns_run %s .acme-manager-%s/%s '%s' rm \"\$@\"; }\n" "$hook" "$native" "$provider" "$profile" "$fields"
  } | atomic_write "$ACME_HOME/dnsapi/$hook.sh" 600
}

dns_require_profile_name() {
  dns_valid_profile "$1" || {
    error 'Use 1-48 lowercase letters, digits or underscores, starting with a letter or digit. The name legacy is reserved.'
    return 1
  }
}

dns_write_profile() {
  local provider="$1" profile="$2" source="$3"
  local -a credentials=()
  dns_require_profile_name "$profile" || return 1
  dns_collect_credentials "$provider" "$source" credentials || return 1
  if [[ "$provider" == cloudflare && ! "${credentials[0]}" =~ ^[A-Za-z0-9_-]+$ ]]; then
    error 'Invalid Cloudflare API token'
    return 1
  fi
  dns_install_profile_hook "$provider" "$profile" || return 1
  printf '%s\n' "${credentials[@]}" |
    atomic_write "$(dns_profile_dir "$provider")/$profile" 600 || return 1
  success "$(dns_label "$provider") profile saved: $profile"
}

dns_configure_profile() {
  dns_write_profile "$1" "$2" prompt
}

dns_prompt_new_profile() {
  local provider="$1" profile
  profile=$(prompt_value 'New profile name') || return 1
  dns_require_profile_name "$profile" || return 1
  if [[ -e "$(dns_profile_dir "$provider")/$profile" ]]; then
    error "DNS profile already exists: $profile"
    return 1
  fi
  printf '%s\n' "$profile"
}

dns_add_profile() {
  local provider="$1" profile
  profile=$(dns_prompt_new_profile "$provider") || return 1
  dns_configure_profile "$provider" "$profile" >&2 || return 1
  printf '%s\n' "$profile"
}

dns_import_profile() {
  local provider="$1" profile
  dns_has_legacy_credentials "$provider" || { error 'Legacy DNS credentials are missing or incomplete'; return 1; }
  profile=$(dns_prompt_new_profile "$provider") || return 1
  dns_write_profile "$provider" "$profile" legacy
}

dns_select_profile() {
  local provider="$1" current="$2" profile selected
  local -a options=()
  while IFS= read -r profile; do
    options+=("$profile" "$profile")
  done < <(dns_profiles "$provider")
  if [[ -z "$current" ]]; then
    if dns_has_legacy_credentials "$provider"; then
      current=legacy
    elif (( ${#options[@]} > 2 )); then
      current=__cancel
    else
      current=${options[0]:-__new}
    fi
  elif [[ "$current" != legacy && ! -s "$(dns_profile_dir "$provider")/$current" ]]; then
    current=__cancel
  fi
  options+=(legacy 'Legacy acme.sh credentials' __new 'Add profile' __cancel 'Cancel')
  selected=$(prompt_select "Select a $(dns_label "$provider") profile" "$current" "${options[@]}") || return 1
  case "$selected" in
    __cancel) return 1;;
    __new) dns_add_profile "$provider";;
    *) printf '%s\n' "$selected";;
  esac
}

dns_profile_hook() {
  local provider="$1" profile="$2" prefix
  if [[ "$profile" == legacy ]]; then
    dns_hook "$provider"
    return
  fi
  if ! dns_valid_profile "$profile" || [[ ! -s "$(dns_profile_dir "$provider")/$profile" ]]; then
    error "$(dns_label "$provider") profile not found: $profile"
    return 1
  fi
  prefix=$(dns_profile_prefix "$provider") || return 1
  dns_install_profile_hook "$provider" "$profile" || return 1
  printf '%s%s\n' "$prefix" "$profile"
}

dns_prompt_existing_profile() {
  local provider="$1" action="$2" profile selected
  local -a options=(__cancel 'Cancel')
  while IFS= read -r profile; do
    options+=("$profile" "$profile")
  done < <(dns_profiles "$provider")
  if (( ${#options[@]} == 2 )); then
    warn 'No named DNS profiles. Choose Add profile or Import legacy credentials.'
    return 1
  fi
  selected=$(prompt_select "Select a profile to $action" __cancel "${options[@]}") || return 1
  [[ "$selected" != __cancel ]] || return 1
  printf '%s\n' "$selected"
}

dns_profile_bindings() {
  local hook="$1" cert_home conf webroot
  cert_home=$(account_get_var CERT_HOME || true)
  cert_home="${cert_home:-${CERT_HOME:-${LE_CONFIG_HOME:-$ACME_HOME}}}"
  for conf in "$cert_home"/*/*.conf; do
    [[ -f "$conf" ]] || continue
    webroot=$(meta_conf_value "$conf" Le_Webroot) || return 1
    if [[ ",$webroot," == *",$hook,"* ]]; then
      printf '%s\n' "${conf#"${cert_home%/}/"}"
    fi
  done
}

dns_remove_profile() {
  local provider="$1" profile="$2" file prefix hook bindings
  dns_require_profile_name "$profile" || return 1
  file="$(dns_profile_dir "$provider")/$profile"
  [[ -f "$file" ]] || { error "$(dns_label "$provider") profile not found: $profile"; return 1; }
  prefix=$(dns_profile_prefix "$provider") || return 1
  hook="$prefix$profile"
  bindings=$(dns_profile_bindings "$hook") || return 1
  if [[ -n "$bindings" ]]; then
    error "DNS profile is used by a certificate: $profile"
    printf '%s\n' "$bindings" >&2
    printf 'Choose another profile for these certificates in Renew certificate first.\n' >&2
    return 1
  fi
  confirm "Remove $(dns_label "$provider") profile $profile?" || return 1
  rm -f -- "$file" "$ACME_HOME/dnsapi/$hook.sh" || return 1
  success "$(dns_label "$provider") profile removed: $profile"
}

dns_profile_menu() {
  local provider="$1" profile
  while true; do
    menu_header "$(dns_label "$provider")" 'Manage DNS credentials'
    ui_section 'Actions'
    ui_menu_item 1 'List profiles' 'Names and legacy credential status'
    ui_menu_item 2 'Add profile'
    ui_menu_item 3 'Update profile'
    ui_menu_item 4 'Remove profile' 'Available for profiles without certificate bindings'
    ui_menu_item 5 'Configure legacy credentials'
    ui_menu_item 6 'Import legacy credentials' 'Save existing credentials under a new name'
    ui_menu_item 7 'Remove legacy credentials' 'Confirmation required'
    ui_menu_item 0 'Back'
    ui_footer
    menu_choice 'Choose an action [0-7]:' || return 0
    case "$MENU_CHOICE" in
      1) dns_status "$provider";;
      2) dns_add_profile "$provider" >/dev/null || true;;
      3) if profile=$(dns_prompt_existing_profile "$provider" update); then dns_configure_profile "$provider" "$profile" || true; fi;;
      4) if profile=$(dns_prompt_existing_profile "$provider" remove); then dns_remove_profile "$provider" "$profile" || true; fi;;
      5) dns_configure "$provider" || true;;
      6) dns_import_profile "$provider" || true;;
      7) dns_remove "$provider" || true;;
      0) return 0;;
      *) warn 'Invalid choice';;
    esac
    pause_screen
  done
}
