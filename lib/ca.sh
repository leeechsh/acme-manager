#!/usr/bin/env bash

ca_name() { case "$1" in letsencrypt) printf "Let's Encrypt\n" ;; zerossl) printf 'ZeroSSL\n' ;; *) printf '%s\n' "$1" ;; esac; }
ca_set_default() {
  local ca="${1:-$DEFAULT_CA}"
  valid_choice "$ca" letsencrypt zerossl || { error '仅支持 letsencrypt 或 zerossl'; return 1; }
  run_acme_logged ca-set-default --set-default-ca --server "$ca" || { error "切换 CA 失败: $ca"; return 1; }
  DEFAULT_CA="$ca"; config_write >/dev/null
  success "默认 CA 已切换为 $(ca_name "$ca")"
}
ca_register() {
  local ca="${1:-$DEFAULT_CA}" email="${2:-}"
  [[ -n "$email" ]] || email=$(prompt_value '账户邮箱')
  [[ "$email" == *@*.* ]] || { error '邮箱格式看起来不正确'; return 1; }
  run_acme_logged ca-register --register-account -m "$email" --server "$ca" || { error 'ACME 账户注册失败'; return 1; }
  success "ACME 账户已注册/确认"
}
ca_show() {
  ensure_acme || return 1
  printf '默认 CA: %s (%s)\n' "$DEFAULT_CA" "$(ca_name "$DEFAULT_CA")"
  printf 'acme.sh 默认 CA 状态:\n'
  run_acme --set-default-ca --server "$DEFAULT_CA" --debug 1 2>&1 | tail -20 || true
}
ca_menu() {
  while true; do
    menu_header 'CA 签发机构' '选择签发机构并管理 ACME 账户'
    menu_home_status
    ui_section '操作'
    ui_menu_item 1 '查看当前 CA' '当前默认签发机构和账户状态'
    ui_menu_item 2 '切换默认 CA' "Let's Encrypt / ZeroSSL"
    ui_menu_item 3 '注册 / 更新账户' '使用邮箱注册 ACME 账户'
    ui_menu_item 0 '返回上一级'
    ui_footer
    menu_choice '请选择操作 [0-3]:' || return 0
    case "$MENU_CHOICE" in
      1) ca_show || true; pause_screen;;
      2)
        local ca_choice
        ca_choice=$(prompt_value 'CA (letsencrypt/zerossl)' "$DEFAULT_CA")
        ca_set_default "$ca_choice" || true
        pause_screen
        ;;
      3) ca_register "$DEFAULT_CA" || true; pause_screen;;
      0) return 0;; *) warn '无效选择';;
    esac
  done
}
