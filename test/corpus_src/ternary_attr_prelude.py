import asyncio

RETRY_MAX = 3


class Transaction:
    def __init__(self, request, addr, protocol, retransmissions=None):
        self.__addr = addr
        self.__future = asyncio.Future()
        self.__request = request
        self.__protocol = protocol
        self.__timeout_handle = None
        self.__tries = 0
        self.__timeout_delay = 1
        self.__tries_max = 1 + (retransmissions if retransmissions is not None else RETRY_MAX)
