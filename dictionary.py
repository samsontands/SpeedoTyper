"""Word dictionary for prefix completions.

Loads /usr/share/dict/words on macOS and filters to reasonable-length
lowercase words. Falls back to a small embedded list if unavailable.
"""

from __future__ import annotations

import os
import re
from pathlib import Path

SYSTEM_DICT_PATHS = [
    "/usr/share/dict/words",
    "/usr/share/dict/american-english",
]

FALLBACK_WORDS = (
    "the be to of and a in that have i it for not on with he as you do at this "
    "but his by from they we say her she or an will my one all would there their "
    "what so up out if about who get which go me when make can like time no just "
    "him know take people into year your good some could them see other than then "
    "now look only come its over think also back after use two how our work first "
    "well way even new want because any these give day most us is was are been has "
    "had were said did get got having does do doing done find found want wanted "
    "looking thinking going getting making taking coming being doing having saying "
    "please thank thanks hello hi hey morning evening afternoon night today "
    "tomorrow yesterday okay sure maybe probably definitely actually honestly "
    "really truly absolutely however therefore because although though while "
    "through during before after since until between among against within without "
    "email message reply send receive download upload login logout password "
    "username account profile settings preferences notification subscribe "
    "meeting schedule calendar appointment deadline project task assignment "
    "document file folder attachment presentation report summary agenda "
    "update status progress complete pending review approve reject submit "
    "question answer request response feedback comment suggestion idea "
    "thought opinion perspective concern issue problem solution resolution "
    "team member colleague manager director employee client customer user "
    "company business organization department office remote hybrid onsite "
    "computer laptop screen keyboard mouse trackpad monitor camera microphone "
    "internet website browser search engine google chrome safari firefox "
    "application software program feature function tool service platform "
    "python javascript typescript swift rust golang java kotlin ruby "
    "function class method variable constant string integer boolean array "
    "object dictionary list tuple hash map set queue stack tree graph "
    "algorithm complexity performance optimization refactor debug test "
    "deploy build compile run execute install uninstall update upgrade "
    "important critical urgent essential necessary required optional "
    "available unavailable possible impossible likely unlikely certain uncertain "
    "beautiful wonderful amazing fantastic incredible awesome brilliant "
    "interesting exciting boring tired happy sad angry frustrated excited "
    "family friend partner spouse parent child brother sister mother father "
    "morning coffee breakfast lunch dinner evening weekend holiday vacation "
).split()


def _load_system_dict() -> list[str]:
    for path in SYSTEM_DICT_PATHS:
        if os.path.isfile(path):
            try:
                with open(path, "r", encoding="utf-8", errors="ignore") as f:
                    words = [w.strip().lower() for w in f if w.strip()]
                return [
                    w for w in words
                    if w.isalpha() and 2 <= len(w) <= 18
                ]
            except OSError:
                continue
    return []


def _count_base_frequency() -> dict[str, int]:
    """Give common words a boost so they rank above obscure dictionary entries."""
    common = {}
    weight = len(FALLBACK_WORDS)
    for i, w in enumerate(FALLBACK_WORDS):
        common[w] = common.get(w, 0) + (weight - i) + 10
    return common


def load_dictionary() -> tuple[set[str], dict[str, int]]:
    words = set(FALLBACK_WORDS)
    words.update(_load_system_dict())
    return words, _count_base_frequency()
