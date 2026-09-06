"""Module registry — the single place a hub module gets wired in.

Each entry below is a *candidate*, not a guarantee. The hub tries to import it and
mounts it if present; a module that is absent, broken, or misconfigured is skipped
with a warning and simply doesn't appear in the nav. That is deliberate: the hub
page must render even when a module fails to import, the same fail-graceful
contract `get_summary()` follows. It also lets each module repo be cloned or not
independently — finance alone, or finance + jobs, or all three.

Mounting protocol, tried in this order:
  1. `init_app(app)` — for modules needing app-level wiring beyond a blueprint.
     Finance takes this path because it owns Flask-Login (login_manager.init_app)
     and registers two blueprints of its own.
  2. `<bp_attr>` — a plain Flask blueprint, registered at `url_prefix`.

To add module #4: append one dict here. Nothing else in the hub changes.
"""
from __future__ import annotations

import importlib
import logging

log = logging.getLogger("hub.registry")


# `import_path` is the installed package the hub imports. Each module repo is
# pip-installed editable into the hub venv, so these resolve without PYTHONPATH.
MODULE_SPECS: list[dict] = [
    {
        "name": "Finance",
        "import_path": "src.hub_module",
        # Finance keeps the bare "/" connect page: moving it would break the
        # ngrok-set PLAID_WEBHOOK_URL flow and existing bookmarks.
        "url": "/",
        "active_paths": ["/", "/reports"],
    },
    {
        "name": "Jobs",
        "import_path": "jobs",
        "bp_attr": "jobs_bp",
        "url_prefix": "/jobs",
        "url": "/jobs/",
        "active_paths": ["/jobs"],
    },
    {
        "name": "Ledger",
        "import_path": "ledger",
        "bp_attr": "ledger_bp",
        "url_prefix": "/ledger",
        "url": "/ledger/",
        "active_paths": ["/ledger"],
    },
]


def _mount(app, module, spec: dict) -> None:
    """Attach one imported module to the app. Raises on failure; caller logs."""
    init_app = getattr(module, "init_app", None)
    if callable(init_app):
        init_app(app)
        return

    bp_attr = spec.get("bp_attr")
    if not bp_attr:
        raise RuntimeError(
            f"{spec['name']} exposes neither init_app() nor a 'bp_attr' in its spec"
        )
    app.register_blueprint(getattr(module, bp_attr), url_prefix=spec.get("url_prefix"))


def load_modules(app) -> list[dict]:
    """Import + mount every available module. Returns the loaded ones, in spec order.

    Each returned dict carries what the nav and the hub landing page need:
    name, url, active_paths, and summary_fn (or None if the module has no card).
    """
    loaded: list[dict] = []

    for spec in MODULE_SPECS:
        name = spec["name"]
        try:
            module = importlib.import_module(spec["import_path"])
        except Exception as e:  # noqa: BLE001 — absent/broken module must not be fatal
            log.warning("Module %r not available, skipping: %s", name, e)
            continue

        try:
            _mount(app, module, spec)
        except Exception as e:  # noqa: BLE001 — a bad mount must not take down the hub
            log.warning("Module %r failed to mount, skipping: %s", name, e)
            continue

        loaded.append(
            {
                "name": name,
                "url": spec["url"],
                "active_paths": spec["active_paths"],
                "summary_fn": getattr(module, "get_summary", None),
            }
        )
        log.info("Registered module: %s at %s", name, spec["url"])

    return loaded
