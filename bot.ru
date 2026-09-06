import os
import re
import sqlite3
from datetime import datetime, timezone

from telegram import Update
from telegram.ext import (
    Application,
    CommandHandler,
    MessageHandler,
    ContextTypes,
    filters,
)

TOKEN = os.getenv("BOT_TOKEN")
DB_PATH = os.getenv("DB_PATH", "marriages.db")

if not TOKEN:
    raise RuntimeError("Переменная BOT_TOKEN не задана")


# =========================
# БАЗА ДАННЫХ
# =========================

db = sqlite3.connect(DB_PATH, check_same_thread=False)
db.row_factory = sqlite3.Row

db.execute("""
CREATE TABLE IF NOT EXISTS users (
    chat_id INTEGER NOT NULL,
    user_id INTEGER NOT NULL,
    username TEXT,
    first_name TEXT,
    PRIMARY KEY (chat_id, user_id)
)
""")

db.execute("""
CREATE TABLE IF NOT EXISTS proposals (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    chat_id INTEGER NOT NULL,
    proposer_id INTEGER NOT NULL,
    member_ids TEXT NOT NULL,
    pending_ids TEXT NOT NULL,
    created_at TEXT NOT NULL,
    active INTEGER NOT NULL DEFAULT 1
)
""")

db.execute("""
CREATE TABLE IF NOT EXISTS marriages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    chat_id INTEGER NOT NULL,
    member_ids TEXT NOT NULL,
    started_at TEXT NOT NULL,
    active INTEGER NOT NULL DEFAULT 1
)
""")

db.commit()


# =========================
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# =========================

def now():
    return datetime.now(timezone.utc).isoformat()


def ids_to_text(ids):
    return ",".join(str(x) for x in ids)


def text_to_ids(text):
    if not text:
        return []

    return [int(x) for x in text.split(",") if x]


def remember_user(chat_id, user):
    username = (user.username or "").lower()

    db.execute("""
        INSERT INTO users
        (chat_id, user_id, username, first_name)
        VALUES (?, ?, ?, ?)

        ON CONFLICT(chat_id, user_id)
        DO UPDATE SET
            username = excluded.username,
            first_name = excluded.first_name
    """, (
        chat_id,
        user.id,
        username,
        user.first_name or "Пользователь"
    ))

    db.commit()


def get_username(chat_id, user_id):
    row = db.execute("""
        SELECT username, first_name
        FROM users
        WHERE chat_id = ? AND user_id = ?
    """, (chat_id, user_id)).fetchone()

    if not row:
        return f"user{user_id}"

    if row["username"]:
        return "@" + row["username"]

    return row["first_name"] or f"user{user_id}"


def get_names(chat_id, user_ids):
    return [
        get_username(chat_id, user_id)
        for user_id in user_ids
    ]


def find_user_by_username(chat_id, username):
    username = username.lstrip("@").lower()

    row = db.execute("""
        SELECT user_id
        FROM users
        WHERE chat_id = ? AND username = ?
    """, (chat_id, username)).fetchone()

    if row:
        return row["user_id"]

    return None


def active_marriages(chat_id, user_id=None):
    rows = db.execute("""
        SELECT *
        FROM marriages
        WHERE chat_id = ? AND active = 1
    """, (chat_id,)).fetchall()

    if user_id is None:
        return rows

    return [
        row for row in rows
        if user_id in text_to_ids(row["member_ids"])
    ]


def extract_usernames(text):
    return re.findall(
        r"(?<!\w)@([A-Za-z0-9_]{5,32})",
        text or ""
    )


# =========================
# ДЛИТЕЛЬНОСТЬ БРАКА
# =========================

def full_months(started_at):
    start = datetime.fromisoformat(started_at)
    current = datetime.now(timezone.utc)

    months = (
        (current.year - start.year) * 12
        + current.month
        - start.month
    )

    if current.day < start.day:
        months -= 1

    return max(0, months)


def duration_text(started_at):
    months = full_months(started_at)

    if months == 0:
        days = (
            datetime.now(timezone.utc)
            - datetime.fromisoformat(started_at)
        ).days

        return f"{days} дн."

    if months == 1:
        return "1 месяц"

    if months < 5:
        return f"{months} месяца"

    return f"{months} месяцев"


def relationship_stage(started_at):
    months = full_months(started_at)

    if months < 2:
        return "💕 1 этап отношений"

    if months < 3:
        return "❤️ 2 этап отношений"

    if months < 4:
        return "💘 3 этап отношений"

    if months < 5:
        return "💓 4 этап отношений"

    return "ПОЗДРАВЛЯЮ! У вас чистая и настоящая любовь ❤️"


# =========================
# START
# =========================

async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not update.effective_user:
        return

    remember_user(
        update.effective_chat.id,
        update.effective_user
    )

    await update.message.reply_text(
        "💍 Добро пожаловать в бот групповых браков!\n\n"

        "💒 Создать брак:\n"
        "брак @user1 @user2\n\n"

        "👰 Ответить на предложение:\n"
        "брак да\n"
        "брак нет\n\n"

        "💕 Мои браки:\n"
        "мои браки\n\n"

        "💍 Подробности:\n"
        "брак 1\n\n"

        "🏆 Топ:\n"
        "топ браков\n\n"

        "💔 Развод:\n"
        "развод"
    )


# =========================
# СОЗДАНИЕ БРАКА
# =========================

async def create_marriage(update: Update, context: ContextTypes.DEFAULT_TYPE):

    user = update.effective_user
    chat_id = update.effective_chat.id

    remember_user(chat_id, user)

    usernames = extract_usernames(
        update.message.text
    )

    # Убираем повторы
    unique = []

    for username in usernames:
        if username.lower() not in [
            x.lower() for x in unique
        ]:
            unique.append(username)

    # Предлагающий + минимум 2 человека
    if len(unique) < 2:
        await update.message.reply_text(
            "💍 Для группового брака нужно минимум 3 человека.\n\n"
            "Пример:\n"
            "брак @user1 @user2"
        )
        return

    # Максимум 15 вместе с создателем
    if len(unique) > 14:
        await update.message.reply_text(
            "💍 Максимум в одном групповом браке — 15 человек."
        )
        return

    member_ids = [user.id]
    not_found = []

    for username in unique:

        user_id = find_user_by_username(
            chat_id,
            username
        )

        if user_id is None:
            not_found.append("@" + username)

        elif user_id not in member_ids:
            member_ids.append(user_id)

    if not_found:
        await update.message.reply_text(
            "💍 Я пока не могу найти:\n"
            + ", ".join(not_found)
            + "\n\n"
            "Пусть эти пользователи сначала напишут "
            "что-нибудь в группе, чтобы бот смог "
            "запомнить их Telegram-профили."
        )
        return

    if len(member_ids) < 3:
        await update.message.reply_text(
            "💍 В браке должно быть минимум 3 разных человека."
        )
        return

    if len(member_ids) > 15:
        await update.message.reply_text(
            "💍 В браке может быть максимум 15 человек."
        )
        return

    # Проверяем существующие браки
    already_married = []

    for member_id in member_ids:
        if active_marriages(chat_id, member_id):
            already_married.append(member_id)

    if already_married:
        names = ", ".join(
            get_names(chat_id, already_married)
        )

        await update.message.reply_text(
            "💍 Нельзя создать этот брак.\n\n"
            f"Уже состоят в браке: {names}"
        )
        return

    # Закрываем старые предложения этих людей
    proposals = db.execute("""
        SELECT *
        FROM proposals
        WHERE chat_id = ? AND active = 1
    """, (chat_id,)).fetchall()

    for proposal in proposals:

        old_members = text_to_ids(
            proposal["member_ids"]
        )

        if any(
            member_id in old_members
            for member_id in member_ids
        ):
            db.execute("""
                UPDATE proposals
                SET active = 0
                WHERE id = ?
            """, (proposal["id"],))

    # Все должны согласиться, кроме создателя
    pending = [
        member_id
        for member_id in member_ids
        if member_id != user.id
    ]

    db.execute("""
        INSERT INTO proposals
        (
            chat_id,
            proposer_id,
            member_ids,
            pending_ids,
            created_at,
            active
        )
        VALUES (?, ?, ?, ?, ?, 1)
    """, (
        chat_id,
        user.id,
        ids_to_text(member_ids),
        ids_to_text(pending),
        now()
    ))

    db.commit()

    names = " ".join(
        get_names(chat_id, member_ids)
    )

    proposer_name = get_username(
        chat_id,
        user.id
    )

    await update.message.reply_text(
        f"💍 {names}\n\n"
        f"Минуточку внимания!\n"
        f"{proposer_name} сделал вам предложение "
        f"*группового брака* 💕\n\n"
        "Принять решение можно командами:\n"
        "«брак да» / «брак нет»"
    )


# =========================
# ОТВЕТ ДА / НЕТ
# =========================

async def answer_marriage(
    update: Update,
    accepted: bool
):

    user = update.effective_user
    chat_id = update.effective_chat.id

    remember_user(chat_id, user)

    proposals = db.execute("""
        SELECT *
        FROM proposals
        WHERE chat_id = ?
        AND active = 1
        ORDER BY id DESC
    """, (chat_id,)).fetchall()

    proposal = None

    for row in proposals:

        pending = text_to_ids(
            row["pending_ids"]
        )

        if user.id in pending:
            proposal = row
            break

    if proposal is None:
        await update.message.reply_text(
            "💍 У тебя сейчас нет предложения "
            "группового брака."
        )
        return

    # ОТКАЗ
    if not accepted:

        db.execute("""
            UPDATE proposals
            SET active = 0
            WHERE id = ?
        """, (proposal["id"],))

        db.commit()

        user_name = get_username(
            chat_id,
            user.id
        )

        await update.message.reply_text(
            f"К сожалению, {user_name} "
            f"разорвал брак! 😔\n\n"
            "Создайте новый."
        )

        return

    # СОГЛАСИЕ
    pending = text_to_ids(
        proposal["pending_ids"]
    )

    pending.remove(user.id)

    user_name = get_username(
        chat_id,
        user.id
    )

    # Еще не все ответили
    if pending:

        db.execute("""
            UPDATE proposals
            SET pending_ids = ?
            WHERE id = ?
        """, (
            ids_to_text(pending),
            proposal["id"]
        ))

        db.commit()

        await update.message.reply_text(
            f"{user_name} Согласен на брак 🥰"
        )

        return

    # ВСЕ СОГЛАСИЛИСЬ
    member_ids = text_to_ids(
        proposal["member_ids"]
    )

    started_at = now()

    db.execute("""
        INSERT INTO marriages
        (
            chat_id,
            member_ids,
            started_at,
            active
        )
        VALUES (?, ?, ?, 1)
    """, (
        chat_id,
        ids_to_text(member_ids),
        started_at
    ))

    db.execute("""
        UPDATE proposals
        SET active = 0
        WHERE id = ?
    """, (proposal["id"],))

    db.commit()

    names = " ".join(
        get_names(chat_id, member_ids)
    )

    await update.message.reply_text(
        "🎁 Поздравляем молодожён!\n\n"
        f"Теперь {names} "
        "состоят с сегодняшнего дня в браке 💍❤️"
    )


# =========================
# МОИ БРАКИ
# =========================

async def my_marriages(update: Update, context: ContextTypes.DEFAULT_TYPE):

    user = update.effective_user
    chat_id = update.effective_chat.id

    remember_user(chat_id, user)

    marriages = active_marriages(
        chat_id,
        user.id
    )

    if not marriages:
        await update.message.reply_text(
            "💔 У тебя пока нет активных браков."
        )
        return

    lines = ["💍 Твои браки:\n"]

    for number, marriage in enumerate(
        marriages,
        start=1
    ):

        member_ids = text_to_ids(
            marriage["member_ids"]
        )

        names = ", ".join(
            get_names(chat_id, member_ids)
        )

        lines.append(
            f"Брак {number} — {names}"
        )

    lines.append(
        "\nЧтобы посмотреть подробности, "
        "напиши: брак 1"
    )

    await update.message.reply_text(
        "\n".join(lines)
    )


# =========================
# БРАК 1, БРАК 2...
# =========================

async def marriage_details(
    update: Update,
    number: int
):

    user = update.effective_user
    chat_id = update.effective_chat.id

    remember_user(chat_id, user)

    marriages = active_marriages(
        chat_id,
        user.id
    )

    if number < 1 or number > len(marriages):
        await update.message.reply_text(
            "💍 Такого номера брака у тебя нет."
        )
        return

    marriage = marriages[number - 1]

    member_ids = text_to_ids(
        marriage["member_ids"]
    )

    names = " ".join(
        get_names(chat_id, member_ids)
    )

    date = datetime.fromisoformat(
        marriage["started_at"]
    ).astimezone().strftime("%d.%m.%Y")

    await update.message.reply_text(
        f"👰‍♀️👰‍♀️👰‍♀️👰‍♀️\n"
        f"Брак между {names}\n\n"
        f"📆 Дата регистрации брака: {date}\n"
        f"🕐 Сколько длится брак: "
        f"{duration_text(marriage['started_at'])}\n\n"
        f"{relationship_stage(marriage['started_at'])}"
    )


# =========================
# ТОП БРАКОВ
# =========================

async def top_marriages(
    update: Update,
    context: ContextTypes.DEFAULT_TYPE
):

    user = update.effective_user
    chat_id = update.effective_chat.id

    remember_user(chat_id, user)

    marriages = active_marriages(chat_id)

    marriages.sort(
        key=lambda x: x["started_at"]
    )

    marriages = marriages[:10]

    if not marriages:
        await update.message.reply_text(
            "🏆 Пока нет активных браков."
        )
        return

    lines = [
        "🏆 ТОП-10 самых долгих браков:\n"
    ]

    for number, marriage in enumerate(
        marriages,
        start=1
    ):

        member_ids = text_to_ids(
            marriage["member_ids"]
        )

        names = " ".join(
            get_names(chat_id, member_ids)
        )

        lines.append(
            f"{number}. {names} — "
            f"{duration_text(marriage['started_at'])}"
        )

    await update.message.reply_text(
        "\n".join(lines)
    )


# =========================
# РАЗВОД
# =========================

async def divorce(
    update: Update,
    context: ContextTypes.DEFAULT_TYPE
):

    user = update.effective_user
    chat_id = update.effective_chat.id

    remember_user(chat_id, user)

    marriages = active_marriages(
        chat_id,
        user.id
    )

    if not marriages:
        await update.message.reply_text(
            "💔 У тебя нет активного брака."
        )
        return

    marriage = marriages[0]

    member_ids = text_to_ids(
        marriage["member_ids"]
    )

    if user.id in member_ids:
        member_ids.remove(user.id)

    db.execute("""
        UPDATE marriages
        SET active = 0
        WHERE id = ?
    """, (marriage["id"],))

    db.commit()

    user_name = get_username(
        chat_id,
        user.id
    )

    remaining = (
        ", ".join(
            get_names(chat_id, member_ids)
        )
        if member_ids
        else "никого"
    )

    await update.message.reply_text(
        f"К сожалению, {user_name} "
        "уходит из группового брака! 🙁\n\n"
        f"Участники брака: {remaining}"
    )


# =========================
# ЗАПОМИНАЕМ УЧАСТНИКОВ
# =========================

async def remember_users(update: Update):

    if not update.effective_user:
        return

    if not update.effective_chat:
        return

    remember_user(
        update.effective_chat.id,
        update.effective_user
    )


# =========================
# ОБРАБОТКА ОБЫЧНЫХ СООБЩЕНИЙ
# =========================

async def text_handler(
    update: Update,
    context: ContextTypes.DEFAULT_TYPE
):

    await remember_users(update)

    text = (
        update.message.text or ""
    ).strip()

    lower = text.lower()

    if lower == "брак да":
        await answer_marriage(
            update,
            True
        )

    elif lower == "брак нет":
        await answer_marriage(
            update,
            False
        )

    elif lower == "мои браки":
        await my_marriages(
            update,
            context
        )

    elif re.fullmatch(
        r"брак\s+\d+",
        lower
    ):
        number = int(
            lower.split()[1]
        )

        await marriage_details(
            update,
            number
        )

    elif lower == "топ браков":
        await top_marriages(
            update,
            context
        )

    elif lower == "развод":
        await divorce(
            update,
            context
        )

    elif lower.startswith("брак "):
        await create_marriage(
            update,
            context
        )


# =========================
# ЗАПУСК
# =========================

def main():

    app = (
        Application
        .builder()
        .token(TOKEN)
        .build()
    )

    app.add_handler(
        CommandHandler(
            "start",
            start
        )
    )

    app.add_handler(
        MessageHandler(
            filters.TEXT & ~filters.COMMAND,
            text_handler
        )
    )

    print("💍 Бот групповых браков запущен!")

    app.run_polling(
        allowed_updates=Update.ALL_TYPES
    )


if __name__ == "__main__":
    main()
