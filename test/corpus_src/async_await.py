# Async/await
async def simple_async():
    return 42

async def async_with_await():
    x = await simple_async()
    return x * 2

async def async_for_loop():
    async for item in async_iter():
        print(item)

async def async_with():
    async with async_cm():
        x = 1

async def async_gen():
    yield 1
    yield 2
