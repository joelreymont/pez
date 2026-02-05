import asyncio


async def async_try_except_finally_cleanup(name, queries, future, timeout):
    try:
        return await asyncio.wait_for(future, timeout=timeout)
    except asyncio.TimeoutError:
        return None
    finally:
        if name in queries:
            queries[name].discard(future)
            if not queries[name]:
                del queries[name]
