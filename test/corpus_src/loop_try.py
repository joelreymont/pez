import time


def run_bot(bot):
    while True:
        try:
            bot.infinity_polling()
        except Exception:
            print("Bot polling error")
            time.sleep(5)
