#!/usr/bin/env bash
set -euo pipefail

have_cmd(){ command -v "$1" >/dev/null 2>&1; }

if ! have_cmd whiptail; then
  echo "whiptail is required for the demo." >&2
  exit 1
fi

# Demo-only: does NOT modify the system.

ui_menu() {
  whiptail --title "OpenZiti Super Installer (DEMO)" --menu "Выбери режим установки" 16 90 6 \
    "1" "Быстрый (рекомендуется)" \
    "2" "Расширенный (все поля)" \
    "3" "Выход" 3>&1 1>&2 2>&3
}

ui_input() {
  local title="$1" prompt="$2" def="$3"
  whiptail --title "$title" --inputbox "$prompt" 11 90 "$def" 3>&1 1>&2 2>&3
}

ui_pass() {
  local title="$1" prompt="$2"
  whiptail --title "$title" --passwordbox "$prompt" 11 90 3>&1 1>&2 2>&3
}

progress() {
  local label="$1"
  {
    echo 5
    echo "# ${label}: проверка зависимостей"
    sleep 0.4
    echo 25
    echo "# ${label}: подготовка директорий"
    sleep 0.4
    echo 55
    echo "# ${label}: генерация конфигов (.env / bot/.env)"
    sleep 0.5
    echo 80
    echo "# ${label}: готово, можно запускать stable-up.sh"
    sleep 0.4
    echo 100
    sleep 0.2
  } | whiptail --title "DEMO" --gauge "Пожалуйста, подожди..." 10 90 0
}

main(){
  local mode
  mode="$(ui_menu || true)"
  [[ -z "${mode}" || "${mode}" == "3" ]] && exit 0

  local REPO_URL INSTALL_DIR
  REPO_URL="$(ui_input "OpenZiti Setup" "Git repository URL" "https://github.com/kepan1n/OpenzitiADsyncTelegram.git")"
  INSTALL_DIR="$(ui_input "OpenZiti Setup" "Install directory" "/opt/openziti-ad-telegram")"

  local CTRL_HOST ROUTER_HOST PUBLIC_IP ADMIN_USER ADMIN_PASS
  CTRL_HOST="$(ui_input "Network" "Controller FQDN" "ziti.example.com")"
  ROUTER_HOST="$(ui_input "Network" "Router FQDN" "router.example.com")"
  PUBLIC_IP="$(ui_input "Network" "Public IP" "203.0.113.10")"
  ADMIN_USER="$(ui_input "Admin" "OpenZiti admin username" "admin")"
  ADMIN_PASS="$(ui_pass "Admin" "OpenZiti admin password")"

  local VPN_CIDR VPN_PORT_LOW VPN_PORT_HIGH VPN_SERVICE_NAME
  VPN_CIDR="$(ui_input "VPN" "VPN network CIDR (e.g. 10.0.0.0/16)" "10.0.0.0/16")"
  VPN_PORT_LOW="$(ui_input "VPN" "VPN port range start" "1")"
  VPN_PORT_HIGH="$(ui_input "VPN" "VPN port range end" "65535")"
  VPN_SERVICE_NAME="$(ui_input "VPN" "VPN service name" "vpn-${VPN_CIDR//\//-}")"

  local LDAP_SERVER LDAP_BIND_DN LDAP_BIND_PASSWORD LDAP_BASE_DN LDAP_GROUP_DN
  LDAP_SERVER="$(ui_input "LDAP" "LDAP server URL" "ldaps://ad.example.local:636")"
  LDAP_BIND_DN="$(ui_input "LDAP" "LDAP bind DN" "CN=svc-ziti,OU=ServiceAccounts,DC=example,DC=local")"
  LDAP_BIND_PASSWORD="$(ui_pass "LDAP" "LDAP bind password")"
  LDAP_BASE_DN="$(ui_input "LDAP" "LDAP base DN" "DC=example,DC=local")"
  LDAP_GROUP_DN="$(ui_input "LDAP" "LDAP group DN" "CN=VPN Users,OU=Groups,DC=example,DC=local")"

  # Optional extras (shown in mode 2 only)
  local TG_TOKEN SMTP_HOST SMTP_USER SMTP_PASS SMTP_FROM
  TG_TOKEN=""; SMTP_HOST=""; SMTP_USER=""; SMTP_PASS=""; SMTP_FROM=""
  if [[ "$mode" == "2" ]]; then
    TG_TOKEN="$(ui_input "Telegram (optional)" "Bot token" "")"
    SMTP_HOST="$(ui_input "SMTP (optional)" "SMTP host" "smtp.example.com")"
    SMTP_USER="$(ui_input "SMTP (optional)" "SMTP user" "bot")"
    SMTP_PASS="$(ui_pass "SMTP (optional)" "SMTP password")"
    SMTP_FROM="$(ui_input "SMTP (optional)" "SMTP from" "bot@example.com")"
  fi

  local summary
  summary="DEMO MODE (no changes will be applied)\n\nRepo: ${REPO_URL}\nDir: ${INSTALL_DIR}\nController: ${CTRL_HOST}\nRouter: ${ROUTER_HOST}\nPublic IP: ${PUBLIC_IP}\nAdmin user: ${ADMIN_USER}\n\nVPN CIDR: ${VPN_CIDR}\nVPN Ports: ${VPN_PORT_LOW}-${VPN_PORT_HIGH}\nVPN Service: ${VPN_SERVICE_NAME}\n\nLDAP server: ${LDAP_SERVER}\nLDAP base: ${LDAP_BASE_DN}\nLDAP group: ${LDAP_GROUP_DN}\n\nJWT/файлы будут уходить на почту (SMTP), в Telegram — только статус."

  whiptail --title "Проверь настройки" --yesno "$summary" 24 100 || exit 0

  progress "Install"

  whiptail --title "Готово (DEMO)" --msgbox "Демо завершено.\n\nВ реальной установке дальше обычно выполняется:\n- git clone/pull\n- заполнение .env и bot/.env\n- scripts/stable-up.sh\n- (опц.) scripts/auto-update-certs.sh\n\nФайлы в Telegram НЕ отправляются — только статус." 16 90
}

main "$@"
