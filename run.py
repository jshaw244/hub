"""Run the hub locally:

    python run.py        ->  http://127.0.0.1:5010/hub

Port 5010 stays clear of finance's 5000-5002 and the jobs standalone on 5003, so
this can run side-by-side with the existing runs/run.ps1 launcher during the
migration.

Finance reads ENV_TARGET at import time to pick its database and Plaid config, so
set it before starting if finance is installed:

    $env:ENV_TARGET = 'sandbox'; python run.py
"""
from hub import create_app

if __name__ == "__main__":
    create_app().run(host="127.0.0.1", port=5010, debug=True)
