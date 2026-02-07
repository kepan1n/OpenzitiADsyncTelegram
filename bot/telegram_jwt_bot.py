import asyncio
import json
import logging
import mimetypes
import os
import re
import subprocess
from email.message import EmailMessage
from pathlib import Path
from smtplib import SMTP, SMTP_SSL
from typing import Any

from dotenv import load_dotenv
from ldap3 import Connection, Server, SUBTREE
from telegram import Update
from telegram.ext import ApplicationBuilder, ContextTypes, MessageHandler, filters


BASE_DIR = Path(__file__).resolve().parent
REPO_ROOT = BASE_DIR.parent

load_dotenv(BASE_DIR / ".env")
load_dotenv(REPO_ROOT / ".env")

TELEGRAM_BOT_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN", "").strip()
ALLOWED_CHAT_IDS_RAW = os.getenv("TELEGRAM_ALLOWED_CHAT_IDS", "").strip()

SMTP_HOST = os.getenv("SMTP_HOST", "").strip()
SMTP_PORT = int(os.getenv("SMTP_PORT", "587").strip())
SMTP_USER = os.getenv("SMTP_USER", "").strip()
SMTP_PASS = os.getenv("SMTP_PASS", "").strip()
SMTP_FROM = os.getenv("SMTP_FROM", "").strip()
SMTP_TLS = os.getenv("SMTP_TLS", "true").strip().lower() == "true"
SMTP_SSL = os.getenv("SMTP_SSL", "false").strip().lower() == "true"
SMTP_TIMEOUT = int(os.getenv("SMTP_TIMEOUT", "30").strip())

USER_EMAIL_DOMAIN = os.getenv("USER_EMAIL_DOMAIN", "example.com").strip()
CLIENT_DIR = Path(os.getenv("CLIENT_DIR", "/opt/openziti-ad-telegram/clients"))

USERNAME_RE = re.compile(r"^[a-z0-9._-]+$")
JWT_RE = re.compile(r"eyJ[0-9A-Za-z_-]+\.[0-9A-Za-z_-]+\.[0-9A-Za-z_-]+")

LDAP_SERVER = os.getenv("LDAP_SERVER", "").strip()
LDAP_BIND_DN = os.getenv("LDAP_BIND_DN", "").strip()
LDAP_BIND_PASSWORD = os.getenv("LDAP_BIND_PASSWORD", "").strip()
LDAP_BASE_DN = os.getenv("LDAP_BASE_DN", "").strip()
LDAP_GROUP_DN = os.getenv("LDAP_GROUP_DN", "").strip()

# Active Directory OID for nested group membership (LDAP_MATCHING_RULE_IN_CHAIN)
AD_MATCHING_RULE_IN_CHAIN = "1.2.840.113556.1.4.1941"

LDAP_NESTED_GROUPS = os.getenv("LDAP_NESTED_GROUPS", "true").strip().lower() == "true"

BOT_RATE_LIMIT_WINDOW_SECONDS = int(os.getenv("BOT_RATE_LIMIT_WINDOW_SECONDS", "300").strip())
BOT_RATE_LIMIT_MAX = int(os.getenv("BOT_RATE_LIMIT_MAX", "3").strip())

BOT_GLOBAL_RATE_LIMIT_WINDOW_SECONDS = int(os.getenv("BOT_GLOBAL_RATE_LIMIT_WINDOW_SECONDS", "3600").strip())
BOT_GLOBAL_RATE_LIMIT_MAX = int(os.getenv("BOT_GLOBAL_RATE_LIMIT_MAX", "3").strip())

STATE_FILE = Path(
    os.getenv(
        "BOT_STATE_FILE",
        str(REPO_ROOT / "data" / "bot-state.json"),
    )
)

INVALID_ACCESS_WARNING = (
    "Доступ запрещён: пользователь отсутствует в разрешённой LDAP/AD группе VPN "
    "или отключён в AD (disabled)."
)
BANNED_MESSAGE = "Доступ к выдаче JWT для этого Telegram-аккаунта заблокирован"


def _parse_allowed_chat_ids(raw_value: str) -> set[int]:
    if not raw_value:
        return set()
    ids = set()
    for item in raw_value.split(","):
        item = item.strip()
        if not item:
            continue
        try:
            ids.add(int(item))
        except ValueError:
            logging.warning("Invalid chat id in TELEGRAM_ALLOWED_CHAT_IDS: %s", item)
    return ids


ALLOWED_CHAT_IDS = _parse_allowed_chat_ids(ALLOWED_CHAT_IDS_RAW)
ADMIN_CHAT_IDS = _parse_allowed_chat_ids(os.getenv("TELEGRAM_ADMIN_CHAT_IDS", ""))
BANNED_CHAT_IDS: set[int] = set()
INVALID_IDENTITY_ATTEMPTS: dict[int, int] = {}
USERNAME_REQUESTS: dict[str, list[int]] = {}
GLOBAL_REQUESTS: list[int] = []


def _load_state() -> None:
    global BANNED_CHAT_IDS, INVALID_IDENTITY_ATTEMPTS, USERNAME_REQUESTS, GLOBAL_REQUESTS
    try:
        if not STATE_FILE.exists():
            return
        payload = json.loads(STATE_FILE.read_text(encoding="utf-8"))
        if not isinstance(payload, dict):
            return
        banned = payload.get("banned_chat_ids", [])
        attempts = payload.get("invalid_identity_attempts", {})
        if isinstance(banned, list):
            BANNED_CHAT_IDS = {int(x) for x in banned if str(x).lstrip("-").isdigit()}
        if isinstance(attempts, dict):
            parsed: dict[int, int] = {}
            for k, v in attempts.items():
                try:
                    chat_id = int(k)
                    parsed[chat_id] = int(v)
                except (TypeError, ValueError):
                    continue
            INVALID_IDENTITY_ATTEMPTS = parsed

        req = payload.get("username_requests", {})
        if isinstance(req, dict):
            parsed_req: dict[str, list[int]] = {}
            for k, v in req.items():
                if not isinstance(k, str) or not isinstance(v, list):
                    continue
                ts_list: list[int] = []
                for item in v:
                    try:
                        ts = int(item)
                    except (TypeError, ValueError):
                        continue
                    ts_list.append(ts)
                if ts_list:
                    parsed_req[k] = ts_list
            USERNAME_REQUESTS = parsed_req

        gr = payload.get("global_requests", [])
        if isinstance(gr, list):
            parsed_gr: list[int] = []
            for item in gr:
                try:
                    ts = int(item)
                except (TypeError, ValueError):
                    continue
                parsed_gr.append(ts)
            GLOBAL_REQUESTS = parsed_gr
    except Exception:
        logging.exception("Failed to load state file: %s", STATE_FILE)


def _save_state() -> None:
    try:
        STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
        payload: dict[str, Any] = {
            "banned_chat_ids": sorted(BANNED_CHAT_IDS),
            "invalid_identity_attempts": {str(k): v for k, v in INVALID_IDENTITY_ATTEMPTS.items()},
            "username_requests": USERNAME_REQUESTS,
            "global_requests": GLOBAL_REQUESTS,
        }
        tmp = STATE_FILE.with_suffix(STATE_FILE.suffix + ".tmp")
        tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        tmp.replace(STATE_FILE)
    except Exception:
        logging.exception("Failed to save state file: %s", STATE_FILE)


def _ban_chat(chat_id: int) -> None:
    BANNED_CHAT_IDS.add(chat_id)
    INVALID_IDENTITY_ATTEMPTS.pop(chat_id, None)
    _save_state()


def _record_invalid_attempt(chat_id: int) -> int:
    attempts = INVALID_IDENTITY_ATTEMPTS.get(chat_id, 0) + 1
    INVALID_IDENTITY_ATTEMPTS[chat_id] = attempts
    _save_state()
    return attempts


def _is_chat_allowed(chat_id: int) -> bool:
    if not ALLOWED_CHAT_IDS:
        return True
    return chat_id in ALLOWED_CHAT_IDS


def _validate_username(raw_text: str) -> str | None:
    username = raw_text.strip().lower()
    if not username:
        return None
    if not USERNAME_RE.match(username):
        return None
    return username


def _rate_limit_ok(username: str) -> bool:
    """Simple per-username rate limit to prevent abuse."""
    import time

    if BOT_RATE_LIMIT_MAX <= 0 or BOT_RATE_LIMIT_WINDOW_SECONDS <= 0:
        return True

    now = int(time.time())
    window_start = now - BOT_RATE_LIMIT_WINDOW_SECONDS

    timestamps = USERNAME_REQUESTS.get(username, [])
    timestamps = [t for t in timestamps if isinstance(t, int) and t >= window_start]

    if len(timestamps) >= BOT_RATE_LIMIT_MAX:
        USERNAME_REQUESTS[username] = timestamps
        _save_state()
        return False

    timestamps.append(now)
    USERNAME_REQUESTS[username] = timestamps
    _save_state()
    return True



def _global_rate_limit_ok() -> bool:
    """Global rate limit (across all chat IDs)."""
    import time

    if BOT_GLOBAL_RATE_LIMIT_MAX <= 0 or BOT_GLOBAL_RATE_LIMIT_WINDOW_SECONDS <= 0:
        return True

    now = int(time.time())
    window_start = now - BOT_GLOBAL_RATE_LIMIT_WINDOW_SECONDS

    timestamps = [t for t in GLOBAL_REQUESTS if isinstance(t, int) and t >= window_start]
    if len(timestamps) >= BOT_GLOBAL_RATE_LIMIT_MAX:
        GLOBAL_REQUESTS[:] = timestamps
        _save_state()
        return False

    timestamps.append(now)
    GLOBAL_REQUESTS[:] = timestamps
    _save_state()
    return True



def _run_compose_command(args: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["docker", "compose", *args],
        cwd=str(REPO_ROOT),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )


def _is_user_enabled_and_in_group(username: str) -> tuple[bool, bool]:
    """Return (enabled, in_group).

    - enabled: based on userAccountControl (disabled flag)
    - in_group: checks LDAP_GROUP_DN membership.

    For Active Directory we try nested membership via matching rule in chain:
      (memberOf:1.2.840.113556.1.4.1941:=<GROUP_DN>)

    If the server does not support it, we fall back to direct memberOf match.
    """
    server = Server(LDAP_SERVER)
    conn = Connection(
        server,
        user=LDAP_BIND_DN,
        password=LDAP_BIND_PASSWORD,
        auto_bind=True,
    )
    try:
        # 1) Load user and check enabled
        conn.search(
            search_base=LDAP_BASE_DN,
            search_filter=f"(&(objectClass=user)(sAMAccountName={username}))",
            search_scope=SUBTREE,
            attributes=["userAccountControl", "memberOf"],
        )
        if not conn.entries:
            return (False, False)
        entry = conn.entries[0]

        uac_value = getattr(entry, "userAccountControl", None)
        uac_value = uac_value.value if uac_value is not None else None
        enabled = False
        if uac_value is not None:
            try:
                value = int(uac_value)
                enabled = (value & 2) == 0
            except (TypeError, ValueError):
                enabled = False

        if not enabled:
            return (False, False)

        # 2) Group check
        if not LDAP_GROUP_DN:
            return (True, True)

        group_dn = LDAP_GROUP_DN.strip()
        # Try nested membership (AD only). If disabled or unsupported, fall back.
        if LDAP_NESTED_GROUPS:
            try:
                nested_filter = (
                    f"(&(objectClass=user)(sAMAccountName={username})"
                    f"(memberOf:{AD_MATCHING_RULE_IN_CHAIN}:={group_dn}))"
                )
                conn.search(
                    search_base=LDAP_BASE_DN,
                    search_filter=nested_filter,
                    search_scope=SUBTREE,
                    attributes=["dn"],
                )
                if conn.entries:
                    return (True, True)
                # If query worked but returned 0 entries -> not in group.
                return (True, False)
            except Exception:
                logging.exception("Nested group membership check failed; falling back to direct memberOf")

        # Fallback: direct memberOf match
        target = group_dn.lower()
        member_of = entry.memberOf.values if hasattr(entry, "memberOf") else []
        in_group = any(isinstance(x, str) and x.strip().lower() == target for x in member_of)
        return (True, in_group)
    finally:
        conn.unbind()


def _generate_or_reenroll_jwt(username: str) -> str:
    jwt_path = f"/persistent/enrollments/{username}.jwt"
    script = (
        "set -e;"
        " export PATH=/var/openziti/ziti-bin:$PATH;"
        " CONTROLLER_URL=\"https://${ZITI_CTRL_EDGE_ADVERTISED_ADDRESS}:${ZITI_CTRL_EDGE_ADVERTISED_PORT}\";"
        " ziti edge login \"$CONTROLLER_URL\" -u \"$ZITI_USER\" -p \"$ZITI_PWD\" -y >/dev/null;"
        f" ziti edge create identity \"{username}\" -a vpn-users -o \"{jwt_path}\" >/dev/null"
        " || ("
        f" ziti edge create enrollment ott --identity \"{username}\" -o \"{jwt_path}\" >/dev/null"
        f" || ziti edge create enrollment ott \"{username}\" -o \"{jwt_path}\" >/dev/null"
        f" || (ziti edge delete identity \"{username}\" >/dev/null && ziti edge create identity \"{username}\" -a vpn-users -o \"{jwt_path}\" >/dev/null)"
        " );"
        f" cat \"{jwt_path}\""
    )

    cmd = ["exec", "-T", "ziti-controller", "bash", "-lc", script]
    result = _run_compose_command(cmd)
    if result.returncode != 0:
        raise RuntimeError(
            "Failed to create/re-enroll identity. "
            f"stdout={result.stdout.strip()} stderr={result.stderr.strip()}"
        )

    output = result.stdout.strip()
    match = JWT_RE.search(output)
    if match:
        return match.group(0)
    return output


def _build_email(username: str, jwt_text: str) -> EmailMessage:
    jwt_text = jwt_text.strip()
    to_addr = f"{username}@{USER_EMAIL_DOMAIN}"
    msg = EmailMessage()
    msg["Subject"] = f"OpenZiti JWT for {username}"
    msg["From"] = SMTP_FROM
    msg["To"] = to_addr
    msg.set_content(
        "Hello,\n\n"
        "Your OpenZiti enrollment JWT is attached as a file.\n"
        "Please import the attachment in the Ziti Desktop app.\n\n"
        "Regards,\n"
        "OpenZiti Bot\n"
    )

    msg.add_attachment(
        jwt_text.encode("utf-8"),
        maintype="application",
        subtype="octet-stream",
        filename=f"{username}.jwt",
    )

    if CLIENT_DIR.exists() and CLIENT_DIR.is_dir():
        for path in sorted(CLIENT_DIR.iterdir()):
            if not path.is_file():
                continue
            mime_type, _ = mimetypes.guess_type(path.name)
            if mime_type:
                maintype, subtype = mime_type.split("/", 1)
            else:
                maintype, subtype = "application", "octet-stream"
            with path.open("rb") as handle:
                msg.add_attachment(
                    handle.read(),
                    maintype=maintype,
                    subtype=subtype,
                    filename=path.name,
                )
    else:
        logging.warning("Client directory not found or not a directory: %s", CLIENT_DIR)

    return msg


def _send_email(message: EmailMessage) -> None:
    if SMTP_SSL:
        with SMTP_SSL(SMTP_HOST, SMTP_PORT, timeout=SMTP_TIMEOUT) as smtp:
            smtp.login(SMTP_USER, SMTP_PASS)
            smtp.send_message(message)
        return

    with SMTP(SMTP_HOST, SMTP_PORT, timeout=SMTP_TIMEOUT) as smtp:
        if SMTP_TLS:
            smtp.starttls()
        smtp.login(SMTP_USER, SMTP_PASS)
        smtp.send_message(message)


async def _handle_message(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if update.effective_chat is None or update.message is None:
        return
    chat_id = update.effective_chat.id
    is_admin = chat_id in ADMIN_CHAT_IDS
    if not is_admin and chat_id in BANNED_CHAT_IDS:
        await update.message.reply_text(BANNED_MESSAGE)
        return
    if not _is_chat_allowed(chat_id):
        await update.message.reply_text("Access denied.")
        return

    async def reply_invalid_access() -> None:
        if not is_admin:
            attempts = _record_invalid_attempt(chat_id)
            if attempts >= 2:
                _ban_chat(chat_id)
                await update.message.reply_text(BANNED_MESSAGE)
                return
        await update.message.reply_text(INVALID_ACCESS_WARNING)

    username = _validate_username(update.message.text or "")
    if not username:
        await reply_invalid_access()
        return

    if not is_admin and not _rate_limit_ok(username):
        await update.message.reply_text("Too many requests for this username. Try again later.")
        return

    # Global rate limit (across all chat IDs) - checked before AD to protect LDAP from spam
    if not is_admin and not _global_rate_limit_ok():
        await update.message.reply_text("Global rate limit exceeded. Try again later.")
        return

    try:
        is_enabled, in_group = await asyncio.to_thread(_is_user_enabled_and_in_group, username)
    except Exception as exc:
        logging.exception("Failed to check AD status for %s", username)
        await update.message.reply_text(f"Failed to validate username: {exc}")
        return

    if not is_enabled or not in_group:
        await reply_invalid_access()
        return

    INVALID_IDENTITY_ATTEMPTS.pop(chat_id, None)
    _save_state()

    await update.message.reply_text("Processing your request...")

    try:
        jwt_text = await asyncio.to_thread(_generate_or_reenroll_jwt, username)
        email_msg = await asyncio.to_thread(_build_email, username, jwt_text)
        await asyncio.to_thread(_send_email, email_msg)
        await update.message.reply_text(f"Sent JWT to {username}@{USER_EMAIL_DOMAIN}")
    except Exception as exc:
        logging.exception("Failed to process request for %s", username)
        await update.message.reply_text(f"Failed to send JWT: {exc}")


def _validate_config() -> None:
    missing = []
    if not TELEGRAM_BOT_TOKEN:
        missing.append("TELEGRAM_BOT_TOKEN")
    if not SMTP_HOST:
        missing.append("SMTP_HOST")
    if not SMTP_USER:
        missing.append("SMTP_USER")
    if not SMTP_PASS:
        missing.append("SMTP_PASS")
    if not SMTP_FROM:
        missing.append("SMTP_FROM")
    if not LDAP_SERVER:
        missing.append("LDAP_SERVER")
    if not LDAP_BIND_DN:
        missing.append("LDAP_BIND_DN")
    if not LDAP_BIND_PASSWORD:
        missing.append("LDAP_BIND_PASSWORD")
    if not LDAP_BASE_DN:
        missing.append("LDAP_BASE_DN")
    if not LDAP_GROUP_DN:
        missing.append("LDAP_GROUP_DN")
    if missing:
        raise RuntimeError(f"Missing required config: {', '.join(missing)}")


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )
    _load_state()
    _validate_config()

    app = ApplicationBuilder().token(TELEGRAM_BOT_TOKEN).build()
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, _handle_message))
    app.run_polling()


if __name__ == "__main__":
    main()

