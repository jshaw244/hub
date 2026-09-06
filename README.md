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

## Starting it

```powershell
c:\DATA\hub\scripts\start.ps1
```

Defaults to **production** on port 5000, with Plaid live and an ngrok tunnel up —
the hub is opened to look at real financial data, so that is the useful default.
It clears stale processes off 5000-5002, runs each module's preflight, starts
`flask --app hub:create_app`, and opens the browser. Press Enter in that window to
stop everything.

| Flag | Effect |
|---|---|
| `-Target sandbox` / `development` | port 5002 / 5001, that environment's DB and Plaid keys |
| `-FlaskDebug` | Flask debugger on; **forces ngrok off** — the Werkzeug debugger is remote code execution and must never be tunnelled |
| `-NoPlaid` | Plaid disabled, no tunnel. For working offline |
| `-NoBrowser` | don't open browser windows |
| `-Maintenance` | activated shell for the target, nothing launched |

### Module preflight

Before launching, the script runs `scripts\preflight.ps1` in each module repo that
has one. Finance's backs up `plaid*.db` and `schema.sql` with rotation, writes a
session audit line, and opens the `debug_db` terminal. Jobs and ledger have none
and are skipped.

This split is deliberate: the hub owns what is true of *the app* (venv, ports,
tunnel, launch, shutdown), and a module owns what is true of *itself*. Backing up
a SQLite file is not the hub's business, and putting it here would make the hub
depend on finance's internal layout.

A preflight that fails warns and does not block the launch — being unable to
rotate a backup is no reason to be unable to open your accounts. Preflight scripts
append any window PIDs they spawn to the `-PidFile` they are given, so shutdown can
close windows the launcher never started itself.

### Without the full stack

`python run.py` runs the hub alone on port 5010 — no Plaid, no ngrok, no backups.
Useful for Jobs or Ledger, neither of which needs a tunnel.

The venv lives here rather than in `personal_finance` because the hub is what
composes the modules. `pyvenv.cfg` and the `Scripts\` shebangs bake absolute
paths, so this venv is created fresh rather than moved.

## Adding a module

1. Create the sibling repo; expose `init_app(app)` or a blueprint, plus
   `get_summary()`.
2. Append one dict to `MODULE_SPECS` in `hub/registry.py`.
3. `pip install -e ..\<repo>` into this venv.

Nothing else in the hub changes — no nav edit, no template edit.
