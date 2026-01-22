import asyncio


async def loop_for_prelude(obj):
    while True:
        await asyncio.sleep(0.1)
        for item in obj.items():
            pass
