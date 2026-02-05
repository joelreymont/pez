from __future__ import annotations

from typing import Dict, List


class ChatMemberUpdated:
    @property
    def difference(self) -> Dict[str, List]:
        return {}


class InaccessibleMessage:
    @staticmethod
    def __universal_deprecation(property_name):
        return property_name

    def __getattr__(self, item):
        if item in (
            "message_thread_id",
            "from_user",
            "reply_to_message",
        ):
            return self.__universal_deprecation(item)
        raise AttributeError(f'"{self.__class__.__name__}" object has no attribute "{item}"')
