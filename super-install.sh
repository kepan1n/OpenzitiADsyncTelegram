#!/usr/bin/env bash
set -euo pipefail

REPO_DEFAULT="https://github.com/kepan1n/OpenzitiADsyncTelegram.git"
INSTALL_DIR_DEFAULT="/opt/openziti-ad-telegram"

have_cmd(){ command -v "$1" >/dev/null 2>&1; }

ui_input() {
  local title="$1" prompt="$2" def="$3" out
  if have_cmd whiptail; then
    out=$(whiptail --title "$title" --inputbox "$prompt" 11 90 "$def" 3>&1 1>&2 2>&3) || return 1
  else
    read -r -p "$prompt [$def]: " out
    out="${out:-$def}"
  fi
  printf '%s' "$out"
}

ui_pass() {
  local title="$1" prompt="$2" out
  if have_cmd whiptail; then
    out=$(whiptail --title "$title" --passwordbox "$prompt" 11 90 3>&1 1>&2 2>&3) || return 1
  else
    read -r -s -p "$prompt: " out; echo
  fi
  printf '%s' "$out"
}

ui_yesno() {
  local title="$1" prompt="$2"
  if have_cmd whiptail; then
    whiptail --title "$title" --yesno "$prompt" 12 90
  else
    read -r -p "$prompt [y/N]: " a
    [[ "${a:-n}" =~ ^[Yy]$ ]]
  fi
}

ui_menu() {
  if have_cmd whiptail; then
    whiptail --title "OpenZiti Super Installer" --menu "Выбери режим установки" 16 90 6 \
      "1" "Быстрый (рекомендуется)" \
      "2" "Расширенный (все поля)" \
      "3" "Выход" 3>&1 1>&2 2>&3
  else
    echo "1) Быстрый (рекомендуется)"
    echo "2) Расширенный (все поля)"
    echo "3) Выход"
    read -r -p "Выбор: " m
    echo "$m"
  fi
}

set_env() {
  local file="$1" key="$2" value="$3" tmp
  tmp="$(mktemp)"
  awk -v k="$key" -v v="$value" '
    BEGIN { done=0 }
    $0 ~ ("^" k "=") { print k "=" v; done=1; next }
    { print }
    END { if (!done) print k "=" v }
  ' "$file" > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

unset_env() {
  local file="$1" key="$2"
  sed -i "/^${key}=/d" "$file"
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Run as root: sudo ./super-install.sh"
    exit 1
  fi
}

bootstrap_system() {
  have_cmd git || (apt-get update -y && apt-get install -y git)

  # Fix a known AppArmor corruption case (NUL bytes in tunables/home.d) that breaks Docker:
  #   "AppArmor enabled on system but the docker-default profile could not be loaded"
  if [[ -d /etc/apparmor.d/tunables/home.d ]]; then
    if grep -RIl $'\x00' /etc/apparmor.d/tunables/home.d >/dev/null 2>&1; then
      echo "[super-install] Detected NUL bytes in /etc/apparmor.d/tunables/home.d/*. Fixing AppArmor..."
      apt-get update -y
      apt-get install --reinstall -y apparmor apparmor-utils libapparmor1 python3-apparmor python3-libapparmor || true

      # Remove NUL bytes (no backups by design; corruption blocks Docker entirely)
      find /etc/apparmor.d/tunables/home.d -maxdepth 1 -type f -print0 | xargs -0 -r perl -i -pe 's/\x00//g'

      # Remove common accidental backup patterns that may get included by AppArmor
      rm -f /etc/apparmor.d/tunables/home.d/*.bak.* 2>/dev/null || true

      systemctl restart apparmor || true
      systemctl restart docker || true

      if ! systemctl is-active --quiet apparmor; then
        echo "[super-install] ERROR: apparmor.service is not active after fix. Showing logs:"
        journalctl -u apparmor.service --no-pager -n 120 || true
      fi

      if ! systemctl is-active --quiet docker; then
        echo "[super-install] WARNING: docker.service is not active after fix."
        systemctl status docker --no-pager -l || true
      fi
    fi
  fi

  if ! have_cmd docker; then
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
  fi
}

clone_or_update_repo() {
  local repo_url="$1" install_dir="$2"
  mkdir -p "$install_dir"
  if [[ ! -d "$install_dir/.git" ]]; then
    git clone "$repo_url" "$install_dir"
  else
    git -C "$install_dir" pull --ff-only
  fi
}

show_summary_and_confirm() {
  local summary="$1"
  if have_cmd whiptail; then
    whiptail --title "Проверь настройки" --yesno "$summary" 24 100
  else
    echo "$summary"
    read -r -p "Продолжить? [y/N]: " a
    [[ "${a:-n}" =~ ^[Yy]$ ]]
  fi
}

main() {
  require_root
  bootstrap_system

  local mode
  mode="$(ui_menu || true)"
  [[ "$mode" == "3" || -z "$mode" ]] && exit 0

  local REPO_URL INSTALL_DIR
  REPO_URL="$(ui_input "OpenZiti Setup" "Git repository URL" "$REPO_DEFAULT")" || exit 1
  INSTALL_DIR="$(ui_input "OpenZiti Setup" "Install directory" "$INSTALL_DIR_DEFAULT")" || exit 1

  clone_or_update_repo "$REPO_URL" "$INSTALL_DIR"
  cd "$INSTALL_DIR"

  # Select docker compose variant (pinned digests vs latest tags)
  local COMPOSE_VARIANT
  if ui_yesno "Docker images" "Использовать pinned версии контейнеров (digest, воспроизводимо)?\n\nYes = pinned (docker-compose.pinned.yml)\nNo  = latest (docker-compose.latest.yml)"; then
    COMPOSE_VARIANT="pinned"
  else
    COMPOSE_VARIANT="latest"
  fi

  if [[ "$COMPOSE_VARIANT" == "pinned" ]]; then
    cp -f docker-compose.pinned.yml docker-compose.yml
  else
    cp -f docker-compose.latest.yml docker-compose.yml
  fi

  [[ -f .env ]] || cp .env.example .env
  [[ -f bot/.env ]] || cp bot/.env.example bot/.env

  local CTRL_HOST ROUTER_HOST PUBLIC_IP ADMIN_USER ADMIN_PASS
  local VPN_CIDR VPN_PORT_LOW VPN_PORT_HIGH VPN_SERVICE_NAME
  local LDAP_SERVER LDAP_BIND_DN LDAP_BIND_PASSWORD LDAP_BASE_DN LDAP_GROUP_DN
  local TG_TOKEN SMTP_HOST SMTP_USER SMTP_PASS SMTP_FROM

  CTRL_HOST="$(ui_input "Network" "Controller FQDN" "ziti.example.com")" || exit 1
  ROUTER_HOST="$(ui_input "Network" "Router FQDN" "router.example.com")" || exit 1
  PUBLIC_IP="$(ui_input "Network" "Public IP" "203.0.113.10")" || exit 1
  ADMIN_USER="$(ui_input "Admin" "OpenZiti admin username" "admin")" || exit 1
  ADMIN_PASS="$(ui_pass "Admin" "OpenZiti admin password")" || exit 1

  VPN_CIDR="$(ui_input "VPN" "VPN network CIDR (e.g. 10.0.0.0/16)" "10.0.0.0/16")" || exit 1
  VPN_PORT_LOW="$(ui_input "VPN" "VPN port range start" "1")" || exit 1
  VPN_PORT_HIGH="$(ui_input "VPN" "VPN port range end" "65535")" || exit 1
  VPN_SERVICE_NAME="$(ui_input "VPN" "VPN service name" "vpn-${VPN_CIDR//\//-}")" || exit 1
  VPN_SERVICE_NAME="${VPN_SERVICE_NAME//./-}"

  LDAP_SERVER="$(ui_input "LDAP" "LDAP server URL" "ldaps://ad.example.local:636")" || exit 1
  LDAP_BIND_DN="$(ui_input "LDAP" "LDAP bind DN" "CN=svc-ziti,OU=ServiceAccounts,DC=example,DC=local")" || exit 1
  LDAP_BIND_PASSWORD="$(ui_pass "LDAP" "LDAP bind password")" || exit 1
  LDAP_BASE_DN="$(ui_input "LDAP" "LDAP base DN" "DC=example,DC=local")" || exit 1
  LDAP_GROUP_DN="$(ui_input "LDAP" "LDAP group DN" "CN=VPN Users,OU=Groups,DC=example,DC=local")" || exit 1

  TG_TOKEN=""
  SMTP_HOST=""
  SMTP_USER=""
  SMTP_PASS=""
  SMTP_FROM=""

  if ! [[ "$VPN_PORT_LOW" =~ ^[0-9]+$ && "$VPN_PORT_HIGH" =~ ^[0-9]+$ ]] || (( VPN_PORT_LOW < 1 || VPN_PORT_HIGH > 65535 || VPN_PORT_LOW > VPN_PORT_HIGH )); then
    echo "Invalid VPN port range: ${VPN_PORT_LOW}-${VPN_PORT_HIGH}"
    exit 1
  fi

  if [[ "$mode" == "2" ]]; then
    TG_TOKEN="$(ui_input "Telegram (optional)" "Bot token" "")" || exit 1
    SMTP_HOST="$(ui_input "SMTP (optional)" "SMTP host" "")" || exit 1
    SMTP_USER="$(ui_input "SMTP (optional)" "SMTP user" "")" || exit 1
    SMTP_PASS="$(ui_pass "SMTP (optional)" "SMTP password")" || exit 1
    SMTP_FROM="$(ui_input "SMTP (optional)" "SMTP from" "")" || exit 1
  fi

  local summary
  summary="Repo: $REPO_URL
Dir: $INSTALL_DIR
Controller: $CTRL_HOST
Router: $ROUTER_HOST
Public IP: $PUBLIC_IP
Admin user: $ADMIN_USER
VPN CIDR: $VPN_CIDR
VPN Ports: $VPN_PORT_LOW-$VPN_PORT_HIGH
VPN Service: $VPN_SERVICE_NAME
LDAP server: $LDAP_SERVER
LDAP base: $LDAP_BASE_DN
LDAP group: $LDAP_GROUP_DN

Будут обновлены .env и bot/.env.
Секреты будут сохранены локально."

  show_summary_and_confirm "$summary" || exit 0

  set_env .env ZITI_CTRL_EDGE_ADVERTISED_ADDRESS "$CTRL_HOST"
  set_env .env ZITI_CTRL_ADVERTISED_ADDRESS "$CTRL_HOST"
  set_env .env ZITI_ROUTER_ADVERTISED_ADDRESS "$ROUTER_HOST"
  set_env .env ZITI_CTRL_EDGE_IP_OVERRIDE "$PUBLIC_IP"
  set_env .env ZITI_ROUTER_IP_OVERRIDE "$PUBLIC_IP"
  set_env .env ZITI_USER "$ADMIN_USER"
  set_env .env ZITI_PWD "$ADMIN_PASS"
  set_env .env VPN_CIDR "$VPN_CIDR"
  set_env .env VPN_PORT_LOW "$VPN_PORT_LOW"
  set_env .env VPN_PORT_HIGH "$VPN_PORT_HIGH"
  set_env .env VPN_SERVICE_NAME "$VPN_SERVICE_NAME"
  set_env .env LDAP_SERVER "$LDAP_SERVER"
  set_env .env LDAP_BIND_DN "\"$LDAP_BIND_DN\""
  set_env .env LDAP_BIND_PASSWORD "$LDAP_BIND_PASSWORD"
  set_env .env LDAP_BASE_DN "$LDAP_BASE_DN"
  set_env .env LDAP_GROUP_DN "\"$LDAP_GROUP_DN\""

  # Enable cert override only when custom cert files already exist.
  # Otherwise keep defaults to avoid boot issues on first install.
  if [[ -f certs/fullchain.cer && -f certs/cert.key ]]; then
    set_env .env ZITI_PKI_EDGE_SERVER_CERT "/certs/fullchain.cer"
    set_env .env ZITI_PKI_EDGE_KEY "/certs/cert.key"
  else
    unset_env .env ZITI_PKI_EDGE_SERVER_CERT
    unset_env .env ZITI_PKI_EDGE_KEY
  fi

  if [[ -n "$TG_TOKEN" ]]; then set_env bot/.env TELEGRAM_BOT_TOKEN "$TG_TOKEN"; fi
  if [[ -n "$SMTP_HOST" ]]; then set_env bot/.env SMTP_HOST "$SMTP_HOST"; fi
  if [[ -n "$SMTP_USER" ]]; then set_env bot/.env SMTP_USER "$SMTP_USER"; fi
  if [[ -n "$SMTP_PASS" ]]; then set_env bot/.env SMTP_PASS "$SMTP_PASS"; fi
  if [[ -n "$SMTP_FROM" ]]; then set_env bot/.env SMTP_FROM "$SMTP_FROM"; fi

  mkdir -p certs
  if [[ -f certs/cert.key ]]; then chmod 644 certs/cert.key 2>/dev/null || true; fi

  if ui_yesno "Start" "Запустить сервисы сейчас через scripts/stable-up.sh?"; then
    ./scripts/stable-up.sh
    if [[ -f certs/fullchain.cer && -f certs/cert.key && -f certs/chain.cer ]]; then
      ./scripts/auto-update-certs.sh || true
    fi
  fi

  if have_cmd whiptail; then
    whiptail --title "Готово" --msgbox "Установка завершена.\n\nПроверь:\n- docker compose ps\n- openssl s_client ...:1280\n\nСертификаты должны лежать в $INSTALL_DIR/certs" 14 90
  else
    echo "Done. Check: docker compose ps"
  fi
}

main "$@"
