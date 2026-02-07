# DEPLOYMENT

Этот документ — практичная шпаргалка по развёртыванию стека на «чистом» сервере.

> Важно: Telegram-бот **не отправляет JWT/файлы в Telegram**. Он отправляет их **на почту (SMTP) как вложения**, а в Telegram пишет только статус.

---

## 1) Подготовка сервера

- Ubuntu/Debian
- Доступ в интернет (docker pull)
- DNS записи на controller/router
- Открыты/проброшены порты OpenZiti (по вашему дизайну)

Минимально чаще всего нужны:

- Controller Edge API: `1280/tcp`
- Router Edge: `3022/tcp`
- ZAC: `8443/tcp`

---

## 2) Развёртывание из git

```bash
git clone <your-repo-url> /opt/openziti-ad-telegram
cd /opt/openziti-ad-telegram

cp .env.example .env
cp bot/.env.example bot/.env
```

Заполнить:

- `.env`: OpenZiti, DNS/IP, AD/LDAP, admin credentials
- `bot/.env`: Telegram token, SMTP, whitelist chat IDs

---

## 3) Сертификаты

Положить сертификаты в `/opt/openziti-ad-telegram/certs/`:

- `fullchain.cer`
- `cert.key`
- `chain.cer`

Проверка/применение:

```bash
cd /opt/openziti-ad-telegram
./scripts/auto-update-certs.sh
```

---

## 4) Автоустановка

```bash
sudo ./install.sh
```

Опции:

```bash
sudo SETUP_BOT=false ./install.sh
sudo SETUP_LDAP_TIMER=false ./install.sh
sudo INSTALL_DIR=/srv/openziti ./install.sh
```

---

## 5) Запуск стека

```bash
cd /opt/openziti-ad-telegram
sudo ./startup.sh
```

Проверка:

```bash
docker compose ps
docker compose logs -f
curl -k https://<controller-host>:1280/version
```

---

## 6) LDAP sync (вручную)

```bash
cd /opt/openziti-ad-telegram
docker compose exec -T ziti-controller bash /scripts/sync-ldap-users.sh
```

---

## 7) Проверка systemd (если ставили `install.sh`)

```bash
systemctl status ziti-telegram-bot.service
systemctl status ziti-ldap-sync.timer
journalctl -u ziti-telegram-bot.service -f
```

---

## 8) Git hygiene

Перед push:

```bash
git status
```

Не должно быть в индексе:

- `.env`, `bot/.env`
- `certs/*`
- `data/*`, `logs/*`
