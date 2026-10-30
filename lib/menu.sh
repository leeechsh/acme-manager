#!/usr/bin/env bash

menu_choice() {
  local label="${1:-请选择}" value
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
  menu_header '日志与故障诊断' '检查运行环境、账户权限与自动续期状态'
  menu_home_status
  printf '\n'
  if ensure_acme; then
    version=$(run_acme --version 2>&1 | head -1 || true)
    printf '  %sacme.sh%s       %s\n' "$UI_MUTED" "$UI_RESET" "${version:-可执行}"
  else
    rc=1
  fi
  config_doctor || rc=1
  [[ -f "$(account_conf_path)" ]] || { warn "账户配置不存在: $(account_conf_path)"; rc=1; }
  command_exists openssl || { warn '缺少 openssl'; rc=1; }
  command_exists curl || command_exists python3 || command_exists python || { warn 'SMTP/DNS 操作可能缺少 curl 或 Python'; rc=1; }
  if crontab -l 2>/dev/null | grep -Fq 'acme.sh'; then
    printf '  %sCron%s         %s已安装%s\n' "$UI_MUTED" "$UI_RESET" "$UI_SUCCESS" "$UI_RESET"
  else
    printf '  %sCron%s         %s未检测到%s\n' "$UI_MUTED" "$UI_RESET" "$UI_WARNING" "$UI_RESET"
  fi
  printf '\n'
  (( rc == 0 )) && success 'doctor 检查通过' || warn 'doctor 发现问题，请按提示处理'
  return "$rc"
}

menu_cron_status() {
  menu_header '自动续期管理' '复用 acme.sh 原生 Cron，不创建第二套调度器'
  menu_home_status
  printf '\n'
  if crontab -l 2>/dev/null | grep -Fq 'acme.sh'; then
    printf '%s状态%s  %s已安装%s\n\n' "$UI_MUTED" "$UI_RESET" "$UI_SUCCESS" "$UI_RESET"
    crontab -l 2>/dev/null | grep -F 'acme.sh' || true
  else
    printf '%s状态%s  %s未检测到 acme.sh Cron%s\n' "$UI_MUTED" "$UI_RESET" "$UI_WARNING" "$UI_RESET"
  fi
}

menu_cron_install() {
  run_acme_logged cron-install --install-cronjob && success 'acme.sh Cron 已安装' || return 1
}

menu_cron_remove() {
  confirm '确认移除 acme.sh Cron？' || return 1
  run_acme_logged cron-remove --uninstall-cronjob && success 'acme.sh Cron 已移除'
}

menu_logs() {
  menu_header '运行日志' '最近 80 条 ACME Manager 操作记录'
  printf '%s日志文件%s  %s\n\n' "$UI_MUTED" "$UI_RESET" "$(_log_file)"
  if [[ -f "$(_log_file)" ]]; then
    tail -80 "$(_log_file)"
  else
    ui_hint '暂无管理器日志。执行一次签发、续期或 doctor 后会生成日志。'
  fi
}

menu_global() {
  while true; do
    menu_header '全局设置 / 更新' '管理默认参数和 acme.sh 版本'
    menu_home_status
    ui_section '配置'
    ui_menu_item 1 '查看当前配置' '显示路径、通知和默认值'
    ui_menu_item 2 '修改默认参数' 'CA、DNS、密钥类型和通知偏好'
    ui_section '维护'
    ui_menu_item 3 '运行 doctor' '检查依赖、权限、账户和 Cron'
    ui_menu_item 4 '升级 acme.sh' '使用 acme.sh 原生升级命令'
    ui_menu_item 0 '返回上一级'
    ui_footer '输入编号选择 · 直接按 Ctrl+C 可退出'
    menu_choice '选择操作 [0-4]:' || return 0
    case "$MENU_CHOICE" in
      1) config_show; pause_screen;;
      2)
        DEFAULT_CA=$(prompt_value '默认 CA' "$DEFAULT_CA")
        DEFAULT_DNS=$(prompt_value '默认 DNS' "$DEFAULT_DNS")
        DEFAULT_KEY_TYPE=$(prompt_value '默认密钥' "$DEFAULT_KEY_TYPE")
        CERT_DIR=$(prompt_value '证书目录' "$CERT_DIR")
        AUTO_RENEW=$(prompt_value '自动续期 true/false' "$AUTO_RENEW")
        NOTIFY_ENABLED=$(prompt_value '通知 true/false' "$NOTIFY_ENABLED")
        NOTIFY_LEVEL=$(prompt_value '通知级别 0-3' "$NOTIFY_LEVEL")
        config_write || true
        pause_screen
        ;;
      3) menu_doctor || true; pause_screen;;
      4) ensure_acme && run_acme_logged upgrade --upgrade && success 'acme.sh 已升级' || warn 'acme.sh 升级失败'; pause_screen;;
      0) return 0;;
      *) warn '无效选择，请输入 0-4';;
    esac
  done
}

main_menu() {
  while true; do
    menu_header 'ACME Manager' '轻量级 SSL/TLS 证书管理工具'
    printf '%s版本%s  %s  %s配置%s  %s\n' "$UI_MUTED" "$UI_RESET" "$ACME_MANAGER_VERSION" "$UI_MUTED" "$UI_RESET" "$CONFIG_FILE"
    menu_home_status

    ui_section '证书生命周期'
    ui_menu_item 1 '申请 SSL 证书' '单域名 / 泛域名 / 多 SAN'
    ui_menu_item 2 '查看证书列表' '有效期、CA 和部署路径'
    ui_menu_item 3 '手动续期证书' '单张证书或全部证书'
    ui_menu_item 4 '部署证书' '路径、权限和 Reload Hook'
    ui_menu_item 5 '删除 / 撤销证书' '危险操作，需要二次确认'

    ui_section '账户与通知'
    ui_menu_item 6 'DNS API 账户' 'Cloudflare / DNSPod / AliDNS'
    ui_menu_item 7 'CA 签发机构' "Let's Encrypt / ZeroSSL"
    ui_menu_item 8 '自动续期管理' '查看、安装或移除 Cron'
    ui_menu_item 9 '邮件通知设置' 'SMTP 配置与测试邮件'

    ui_section '维护'
    ui_menu_item 10 '日志与故障诊断' '查看日志并运行 doctor'
    ui_menu_item 11 '全局设置 / 更新' '默认参数和 acme.sh 维护'
    ui_menu_item 0 '退出' '返回 Shell'
    ui_footer '输入编号选择 · 配置与密钥不会显示在日志中'

    menu_choice '请选择操作 [0-11]:' || break
    case "$MENU_CHOICE" in
      1) cert_issue || true; pause_screen;;
      2) cert_list || true; pause_screen;;
      3)
        local domain
        domain=$(prompt_value '域名（留空续期全部）' '')
        if [[ -n "$domain" ]]; then cert_renew --domain "$domain" || true; else cert_renew --all || true; fi
        pause_screen
        ;;
      4)
        local domain
        domain=$(prompt_value '域名')
        deploy_cert "$domain" "$DEFAULT_KEY_TYPE" || true
        pause_screen
        ;;
      5)
        local domain revoke_choice
        domain=$(prompt_value '域名')
        revoke_choice=$(prompt_value '同时撤销证书 (true/false)' 'false')
        cert_remove "$domain" "$revoke_choice" || true
        pause_screen
        ;;
      6) dns_menu || true;;
      7) ca_menu || true;;
      8)
        menu_cron_status
        ui_section '操作'
        ui_menu_item 1 '安装 / 修复 Cron' '交给 acme.sh 管理'
        ui_menu_item 2 '移除 Cron' '不会删除证书或账户'
        ui_menu_item 0 '返回'
        ui_footer
        menu_choice '选择操作 [0-2]:' || true
        case "$MENU_CHOICE" in 1) menu_cron_install || true;; 2) menu_cron_remove || true;; esac
        pause_screen
        ;;
      9) notify_menu || true;;
      10) menu_logs; menu_doctor || true; pause_screen;;
      11) menu_global || true;;
      0) break;;
      *) warn '无效选择，请输入 0-11';;
    esac
  done
}
