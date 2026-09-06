# Personal Hub

The composition root for a set of personal tools that should feel like one system.
The hub owns the Flask app, the shared chrome, and the module registry — and
nothing else. Every feature lives in its own repo.

## Layout

```
c:\DATA\hub\          <- this repo (pip project + git repo)
  pyproject.toml
  run.py              <- standalone launcher, port 5010
  hub\                <- the importable package
    app.py            <- create_app() factory
    registry.py       <- MODULE_SPECS: the one place modules get wired in
    routes.py         <- the hub's own /hub landing page
    templates\
      base.html       <- THE shared chrome; every module page extends this
      hub.html        <- landing page, one summary card per module
```

## Sibling modules

Each module is a separate git repo alongside this one, pip-installed **editable**
into the hub's venv:

| Module  | Repo                        | Mounted at | Exposes |
|---------|-----------------------------|------------|---------|
| Finance | `c:\DATA\personal_finance`  | `/`        | `init_app(app)`, `get_summary()` |
| Jobs    | `c:\DATA\jobs`              | `/jobs`    | `jobs_bp`, `get_summary()` |
| Ledger  | `c:\DATA\ledger`            | `/ledger`  | `ledger_bp`, `get_summary()` |

Separate repos, not subdirectories: the hub is a *runtime* composition (editable
install + blueprint registration), not a filesystem hierarchy. It also keeps
job-hunt data out of the public finance repo.

Finance keeps the bare `/` route. Moving its connect page would break the
ngrok-set `PLAID_WEBHOOK_URL` flow and existing bookmarks for no real gain.

## Module contract

A module is any installed package exposing **one** of:

- `init_app(app)` — for modules needing app-level wiring beyond a blueprint.
  Finance takes this path: it owns Flask-Login and registers two blueprints.
- a blueprint attribute named by `bp_attr` in its spec, registered at `url_prefix`.

Optionally plus:

- `get_summary() -> dict` — the hub-card contract. Shape `{"headline", "detail",
  "url"}`, plus `"error"` when degraded. Must be **read-only, cheap, and
  fail-graceful**: it runs on every landing-page render, so a broken module has to
  return a degraded card rather than raise.

A module that is absent or fails to import is skipped with a warning and drops out
of the nav. The hub always starts.

## Setup

```powershell
cd c:\DATA\hub
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -e .
pip install -e ..\jobs
pip install -e ..\ledger
pip install -e ..\personal_finance
pip install -r ..\personal_finance\src\requirements.txt
```

Then:

```powershell
$env:ENV_TARGET = 'sandbox'
python run.py        # http://127.0.0.1:5010/hub
```

The venv lives here rather than in `personal_finance` because the hub is what
composes the modules. `pyvenv.cfg` and the `Scripts\` shebangs bake absolute
paths, so this venv is created fresh rather than moved.

## Adding a module

1. Create the sibling repo; expose `init_app(app)` or a blueprint, plus
   `get_summary()`.
2. Append one dict to `MODULE_SPECS` in `hub/registry.py`.
3. `pip install -e ..\<repo>` into this venv.

Nothing else in the hub changes — no nav edit, no template edit.
