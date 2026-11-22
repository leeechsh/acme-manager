#!/bin/sh

# Keep the provider hook's credential assignments and account writes isolated.
_am_dns_run() (
  _am_dns_hook=$1
  _am_dns_file=$2
  _am_dns_keys=$3
  _am_dns_action=$4
  shift 4

  if ! [ -r "$LE_WORKING_DIR/$_am_dns_file" ]; then
    _err "Missing DNS credential profile: $_am_dns_file"
    return 1
  fi
  if [ "$_am_dns_hook" = dns_cf ]; then
    unset CF_Zone_ID CF_Key CF_Email
    CF_Zone_ID=
    CF_Key=
    CF_Email=
  fi
  for _am_dns_key in $_am_dns_keys; do
    unset "$_am_dns_key"
    if ! IFS= read -r "$_am_dns_key"; then
      _err "Incomplete DNS credential profile: $_am_dns_file"
      return 1
    fi
  done <"$LE_WORKING_DIR/$_am_dns_file"

  _am_dns_native=$(_findHook "" dnsapi "$_am_dns_hook")
  if [ -z "$_am_dns_native" ] || ! . "$_am_dns_native"; then
    _err "Cannot load the native DNS hook: $_am_dns_hook"
    return 1
  fi
  _readaccountconf_mutable() { :; }
  _saveaccountconf_mutable() { :; }
  _clearaccountconf_mutable() { :; }
  _clearaccountconf() { :; }
  "${_am_dns_hook}_$_am_dns_action" "$@"
)
