"""Hub application factory.

The hub owns three things and nothing else:
  - the Flask app object and its session config
  - the shared chrome (templates/base.html) every module inherits
  - the module registry that mounts each module's blueprint(s)

Template resolution note: Flask's loader searches the *app's* template folder
before any blueprint's, so hub/templates/base.html wins over any base.html a
module still ships. That is what makes the chrome genuinely shared — a module
cannot accidentally shadow it.
"""
from __future__ import annotations

import logging
import os
from datetime import timedelta

from flask import Flask, redirect, request

from .registry import load_modules
from .routes import HUB_NAV, hub_bp


def create_app() -> Flask:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    )

    app = Flask(__name__)
    app.secret_key = os.getenv("FLASK_SECRET_KEY", "dev_secret_key")
    app.permanent_session_lifetime = timedelta(
        minutes=int(os.getenv("REPORTS_SESSION_MINUTES", "30"))
    )

    # Registered first so the hub's own routes take precedence over anything a
    # module might claim.
    app.register_blueprint(hub_bp)

    modules = load_modules(app)
    app.config["HUB_MODULES"] = modules

    # If finance isn't mounted, nothing owns "/" — send it to the hub landing so
    # the root URL is never a 404 during a partial install.
    if not any(m["url"] == "/" for m in modules):
        app.add_url_rule("/", "root_redirect", lambda: redirect("/hub"))

    @app.context_processor
    def inject_nav_modules():
        """Supply the hub nav its links on every render. Cheap by design: names,
        urls, and an active flag from the path. summary_fn is NOT called here —
        only the landing page pays that cost."""
        path = request.path
        nav = []
        for m in [HUB_NAV, *modules]:
            active = any(
                path == ap if ap == "/" else path.startswith(ap)
                for ap in m["active_paths"]
            )
            nav.append({"name": m["name"], "url": m["url"], "active": active})
        return {"nav_modules": nav}

    return app
