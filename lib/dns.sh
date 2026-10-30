#!/usr/bin/env bash

dns_hook() { case "$1" in cloudflare) printf 'dns_cf\n' ;; dnspod) printf 'dns_tencent\n' ;; aliyun) printf 'dns_ali\n' ;; *) return 1 ;; esac; }
dns_label() { case "$1" in cloudflare) printf 'Cloudflare\n' ;; dnspod) printf '腾讯云 DNSPod\n' ;; aliyun) printf '阿里云 AliDNS\n' ;; *) printf '%s\n' "$1" ;; esac; }
dns_keys() { case "$1" in cloudflare) printf 'CF_Token\nCF_Account_ID\n' ;; dnspod) printf 'Tencent_SecretId\nTencent_SecretKey\nTencent_SessionToken\nTencent_Region\n' ;; aliyun) printf 'Ali_Key\nAli_Secret\nAli_SecurityToken\n' ;; *) return 1 ;; esac; }

dns_status() {
  local provider="${1:-$DEFAULT_DNS}" key value configured=0
  valid_choice "$provider" cloudflare dnspod aliyun || { error '未知 DNS provider'; return 1; }
  printf '%s (%s)\n' "$(dns_label "$provider")" "$(dns_hook "$provider")"
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    if value=$(account_get_var "$key" 2>/dev/null) && [[ -n "$value" ]]; then
      printf '  %-20s 已配置\n' "$key"
      configured=1
    else
      printf '  %-20s 未配置\n' "$key"
    fi
  done < <(dns_keys "$provider")
  (( configured )) || warn '未发现完整凭据，请先配置或更新'
  return 0
}

dns_configure() {
  local provider="${1:-$DEFAULT_DNS}" value key
  valid_choice "$provider" cloudflare dnspod aliyun || { error '未知 DNS provider'; return 1; }
  case "$provider" in
    cloudflare)
      value=$(prompt_secret 'Cloudflare API Token（留空取消）') || return 1
      [[ -n "$value" ]] || { warn '已取消'; return 1; }
      account_set_var CF_Token "$value"
      local account_id
      account_id=$(prompt_value 'Cloudflare Account ID（可选，直接回车跳过）' '')
      if [[ -n "$account_id" ]]; then account_set_var CF_Account_ID "$account_id"; fi
      ;;
    dnspod)
      value=$(prompt_value 'DNSPod SecretId') || return 1
      [[ -n "$value" ]] || { warn '已取消'; return 1; }
      account_set_var Tencent_SecretId "$value"
      value=$(prompt_secret 'DNSPod SecretKey') || return 1
      [[ -n "$value" ]] || { error 'SecretKey 不能为空'; return 1; }
      account_set_var Tencent_SecretKey "$value"
      value=$(prompt_secret 'DNSPod SessionToken（可选，直接回车跳过）') || return 1
      if [[ -n "$value" ]]; then account_set_var Tencent_SessionToken "$value"; else account_unset_var Tencent_SessionToken; fi
      value=$(prompt_value 'DNSPod Region（可选，直接回车跳过）' '') || return 1
      if [[ -n "$value" ]]; then account_set_var Tencent_Region "$value"; else account_unset_var Tencent_Region; fi
      ;;
    aliyun)
      value=$(prompt_value 'AliDNS AccessKey ID') || return 1
      [[ -n "$value" ]] || { warn '已取消'; return 1; }
      account_set_var Ali_Key "$value"
      value=$(prompt_secret 'AliDNS AccessKey Secret') || return 1
      [[ -n "$value" ]] || { error 'AccessKey Secret 不能为空'; return 1; }
      account_set_var Ali_Secret "$value"
      value=$(prompt_secret 'AliDNS SecurityToken（可选，直接回车跳过）') || return 1
      if [[ -n "$value" ]]; then account_set_var Ali_SecurityToken "$value"; else account_unset_var Ali_SecurityToken; fi
      ;;
  esac
  chmod 600 "$(account_conf_path)"
  success "$(dns_label "$provider") 凭据已保存到 acme.sh 原生账户配置"
  dns_status "$provider" >/dev/null || true
}

dns_remove() {
  local provider="${1:-$DEFAULT_DNS}" key
  confirm "确认删除 $(dns_label "$provider") 凭据？" || { warn '已取消'; return 1; }
  while IFS= read -r key; do [[ -n "$key" ]] && account_unset_var "$key"; done < <(dns_keys "$provider")
  success 'DNS 凭据已删除'
}

dns_menu() {
  while true; do
    menu_header 'DNS API 账户' '凭据写入 acme.sh 原生 account.conf'
    menu_home_status
    ui_section '操作'
    ui_menu_item 1 '查看凭据状态' '只显示已配置 / 未配置，不显示密钥'
    ui_menu_item 2 '配置 / 更新凭据' 'Cloudflare / DNSPod / AliDNS'
    ui_menu_item 3 '删除凭据' '危险操作，需要二次确认'
    ui_menu_item 0 '返回上一级'
    ui_footer
    menu_choice '请选择操作 [0-3]:' || return 0
    local provider
    case "$MENU_CHOICE" in
      1) provider=$(prompt_value 'Provider (cloudflare/dnspod/aliyun)' "$DEFAULT_DNS"); dns_status "$provider" || true; pause_screen;;
      2) provider=$(prompt_value 'Provider (cloudflare/dnspod/aliyun)' "$DEFAULT_DNS"); dns_configure "$provider" || true; pause_screen;;
      3) provider=$(prompt_value 'Provider (cloudflare/dnspod/aliyun)' "$DEFAULT_DNS"); dns_remove "$provider" || true; pause_screen;;
      0) return 0;; *) warn '无效选择';;
    esac
  done
}
