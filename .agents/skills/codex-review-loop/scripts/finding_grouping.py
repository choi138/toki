"""Order-independent connected components for review findings."""

from __future__ import annotations

from collections.abc import Callable, Sequence
from typing import TypeVar


Item = TypeVar("Item")


def connected_components(
    items: Sequence[Item],
    related: Callable[[Item, Item], bool],
) -> list[list[Item]]:
    parents = list(range(len(items)))

    def find(index: int) -> int:
        while parents[index] != index:
            parents[index] = parents[parents[index]]
            index = parents[index]
        return index

    def union(left: int, right: int) -> None:
        left_root = find(left)
        right_root = find(right)
        if left_root != right_root:
            parents[right_root] = left_root

    for left in range(len(items)):
        for right in range(left + 1, len(items)):
            if related(items[left], items[right]):
                union(left, right)

    grouped: dict[int, list[Item]] = {}
    for index, item in enumerate(items):
        grouped.setdefault(find(index), []).append(item)
    return list(grouped.values())
