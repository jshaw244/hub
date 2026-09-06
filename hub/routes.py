"""The hub's own pages — currently just the landing page at /hub.

Deliberately thin. The hub owns chrome and composition, not features; anything
with real logic belongs in a module repo.
"""
from __future__ import annotations

import logging

from flask import Blueprint, current_app, render_template

log = logging.getLogger("hub.routes")

hub_bp = Blueprint("hub", __name__)

# Nav entry for the hub itself, prepended to the module list. Kept here rather
# than in registry.py because the hub is not a module — it has no summary card
# and cannot be absent.
HUB_NAV = {"name": "Hub", "url": "/hub", "active_paths": ["/hub"]}


def _cards() -> list[dict]:
    """Call every module's get_summary(), tolerating any that misbehave.

    get_summary() is contractually fail-graceful, but a module could still raise
    (or return a non-dict) despite that, and the landing page must render anyway.
    """
    cards = []
    for m in current_app.config.get("HUB_MODULES", []):
        fn = m.get("summary_fn")
        if not callable(fn):
            continue
        try:
            card = fn()
            if not isinstance(card, dict):
                raise TypeError(f"get_summary() returned {type(card).__name__}, want dict")
        except Exception as e:  # noqa: BLE001 — a broken card must not 500 the hub
            log.warning("get_summary() failed for %r: %s", m["name"], e)
            card = {"headline": m["name"], "detail": "unavailable", "url": m["url"]}
        card.setdefault("headline", m["name"])
        card.setdefault("url", m["url"])
        cards.append(card)
    return cards


@hub_bp.route("/hub")
def index():
    return render_template("hub.html", cards=_cards())
