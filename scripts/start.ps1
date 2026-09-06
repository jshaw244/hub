<#
.SYNOPSIS
    Start the personal hub: every module, Plaid live, ngrok tunnel up.

.DESCRIPTION
    The single entry point. Replaces personal_finance\runs\run.ps1, which had to
    live in finance back when finance was the host application. It isn't any more,
    so the launcher moved here, beside the app factory and the venv it uses.

    This script owns things true of THE APP:
      - activating the hub venv and choosing the port for the target
      - clearing stale Flask/ngrok processes off the reserved ports
      - the ngrok tunnel and PLAID_WEBHOOK_URL
      - launching `flask --app hub:create_app` and opening the browser
      - shutting all of it down again

    It does NOT own anything module-specific. Backing up plaid.db, rotating
    schema.sql, watching the schema, and the debug_db terminal are finance's
    concerns and live in personal_finance\scripts\preflight.ps1. Any module repo
    may provide scripts\preflight.ps1 and it will be run before launch; jobs and
    ledger have none and are simply skipped. That boundary is the point — the hub
    composes modules, it does not know their internals.

.PARAMETER Target
    sandbox | development | production. Defaults to production: the hub is opened
    to look at real financial data, so that is the useful default.

.PARAMETER FlaskDebug
    Run Flask's debugger. Forces ngrok OFF — the Werkzeug debugger is remote code
    execution, and tunnelling it to the public internet would be handing that out.

.PARAMETER NoPlaid
    Escape hatch: start with Plaid disabled and no tunnel, for working offline or
    when Plaid is down. Off by default.

.EXAMPLE
    .\scripts\start.ps1                      # production, everything on
    .\scripts\start.ps1 -Target sandbox      # sandbox against Plaid's sandbox
    .\scripts\start.ps1 -FlaskDebug          # debugger on, tunnel off
#>
[CmdletBinding()]
param(
    [ValidateSet("sandbox", "development", "production")]
    [string]$Target = "production",

    [switch]$Maintenance,
    [switch]$FlaskDebug,
    [switch]$NoPlaid,
    [switch]$NoBrowser
)

$ErrorActionPreference = "Stop"

# -------------------------------------------------------------------
# Paths
# -------------------------------------------------------------------
$HubRoot = (Resolve-Path "$PSScriptRoot\..").Path
Set-Location -Path $HubRoot

$VenvActivate = Join-Path $HubRoot ".venv\Scripts\Activate.ps1"
if (-not (Test-Path $VenvActivate)) {
    throw @"
Hub venv missing at $HubRoot\.venv.
Create it once:
    cd $HubRoot
    python -m venv .venv
    .\.venv\Scripts\Activate.ps1
    pip install -e . -e ..\jobs -e ..\ledger -e ..\personal_finance
    pip install -r ..\personal_finance\src\requirements.txt
"@
}

# Module repos, in the order their preflight should run. Listed explicitly rather
# than discovered by scanning, matching how MODULE_SPECS in hub/registry.py names
# its modules: the set of modules is a decision, not something to infer from the
# filesystem. A repo that isn't present is skipped.
$ModuleRepos = @(
    (Join-Path $HubRoot "..\personal_finance")
    (Join-Path $HubRoot "..\jobs")
    (Join-Path $HubRoot "..\ledger")
)

$portMap = @{ "production" = 5000; "development" = 5001; "sandbox" = 5002 }
$port = $portMap[$Target]

# Sandbox binds all interfaces so a phone on the LAN can complete Plaid Link;
# development and production stay on loopback.
$flaskHost = if ($Target -eq "sandbox") { "0.0.0.0" } else { "127.0.0.1" }

# Every window this launcher opens records its PID here, and preflight scripts
# append theirs too. The name is keyed to the TARGET, not to this process, so the
# *next* run can find and close what this one left behind — which is the whole
# point: killing the process on a port does not close the window hosting it.
$PidFile = Join-Path $env:TEMP "hub_windows_$Target.txt"

function Register-Window {
    param([int]$ProcessId)
    if ($ProcessId) { Add-Content -Path $PidFile -Value $ProcessId }
}

function Close-RecordedWindows {
    if (-not (Test-Path $PidFile)) { return 0 }
    $n = 0
    foreach ($line in Get-Content $PidFile) {
        if ($line -notmatch '^\d+$') { continue }
        $procId = [int]$line
        if ($procId -eq $PID) { continue }
        $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
        # PIDs get reused, so confirm it is still one of ours before killing it.
        if ($proc -and $proc.ProcessName -match '^(pwsh|powershell|python|ngrok)$') {
            Write-Host "  Closing leftover $($proc.ProcessName) (PID $procId)" -ForegroundColor Yellow
            & taskkill /PID $procId /F /T 2>&1 | Out-Null
            $n++
        }
    }
    Remove-Item $PidFile -ErrorAction SilentlyContinue
    return $n
}

# Titles are a secondary net for windows started before this file existed, or by a
# run whose PID file was deleted. Deliberately strict: matching something loose
# like "*personal_finance*" would also match an ordinary terminal sitting in that
# directory, and closing the user's own shell would be a bad way to fail.
$WindowPattern = '^(hub|personal_finance) \[.+\] - (Flask|ngrok|debug)$'

function Close-TaggedWindows {
    $stale = Get-Process pwsh, powershell -ErrorAction SilentlyContinue |
        Where-Object { $_.Id -ne $PID -and $_.MainWindowTitle -match $WindowPattern }
    foreach ($w in $stale) {
        Write-Host "  Closing stale window: $($w.MainWindowTitle) (PID $($w.Id))" -ForegroundColor Yellow
        & taskkill /PID $w.Id /F /T 2>&1 | Out-Null
    }
    return ($stale | Measure-Object).Count
}

# Every window this launcher opens is titled to this shape, which is how stale
# ones are recognised on the next run. Deliberately strict: matching something
# loose like "*personal_finance*" would also match an ordinary terminal that
# happens to be sitting in that directory, and closing the user's own shell would
# be a genuinely bad way to fail.
$WindowPattern = '^(hub|personal_finance) \[.+\] - (Flask|ngrok|debug)$'

function Close-TaggedWindows {
    param([string]$Why)
    $stale = Get-Process pwsh, powershell -ErrorAction SilentlyContinue |
        Where-Object { $_.Id -ne $PID -and $_.MainWindowTitle -match $WindowPattern }
    foreach ($w in $stale) {
        Write-Host "  $Why window: $($w.MainWindowTitle) (PID $($w.Id))" -ForegroundColor Yellow
        & taskkill /PID $w.Id /F /T 2>&1 | Out-Null
    }
    return ($stale | Measure-Object).Count
}

Write-Host "`n=== Starting hub [$Target] ===" -ForegroundColor Cyan
Write-Host "Hub root: $HubRoot"
Write-Host "Port:     $port"

# -------------------------------------------------------------------
# Environment
# -------------------------------------------------------------------
$env:ENV_TARGET     = $Target
$env:PLAID_ENV      = $Target
$env:FLASK_RUN_PORT = $port

if ($FlaskDebug) { $env:FLASK_DEBUG = "1" } else { Remove-Item Env:FLASK_DEBUG -ErrorAction SilentlyContinue }
if ($NoPlaid)    { $env:PLAID_DISABLED = "1" } else { Remove-Item Env:PLAID_DISABLED -ErrorAction SilentlyContinue }

. $VenvActivate

# -------------------------------------------------------------------
# Maintenance shell
# -------------------------------------------------------------------
if ($Maintenance) {
    Write-Host "Entering maintenance mode..." -ForegroundColor Cyan
    pwsh -NoExit -NoProfile -Command "
        . '$VenvActivate';
        `$env:ENV_TARGET     = '$Target';
        `$env:PLAID_ENV      = '$Target';
        `$env:FLASK_RUN_PORT = '$port';
        Set-Location '$HubRoot';
        Write-Host '`nMaintenance shell active [$Target].`n' -ForegroundColor Green;
    "
    exit 0
}

# -------------------------------------------------------------------
# Clear stale Flask/ngrok off the reserved ports
# -------------------------------------------------------------------
Write-Host "`nChecking for conflicting Flask/ngrok processes..." -ForegroundColor Cyan
foreach ($p in $portMap.Values) {
    $connections = Get-NetTCPConnection -State Listen -LocalPort $p -ErrorAction SilentlyContinue
    foreach ($procId in ($connections | Select-Object -ExpandProperty OwningProcess -Unique)) {
        $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
        if ($proc -and ($proc.ProcessName -match "python|ngrok")) {
            Write-Host ("  Closing stale {0} (PID {1}) on port {2}" -f $proc.ProcessName, $procId, $p) -ForegroundColor Yellow
            Stop-Process -Id $procId -Force
        }
    }
}
Write-Host "Ports 5000-5002 clear." -ForegroundColor Green

# Killing the process on a port does NOT close the window hosting it: the Flask
# and ngrok windows run with -NoExit so a crash stays readable, which means the
# shell outlives the command it ran. Without this, those windows pile up one set
# per restart. ngrok is missed by the port loop above regardless — it listens on
# 4040, not on 5000-5002.
$closed = (Close-RecordedWindows) + (Close-TaggedWindows)
if ($closed) { Write-Host "Closed $closed leftover window(s) from a previous run." -ForegroundColor Green }

# -------------------------------------------------------------------
# Module preflight
#
# Runs BEFORE the app starts, so a module that backs up its database does so
# before the app can write to it. A failing preflight warns but never blocks the
# launch: not being able to rotate a backup is no reason to be unable to look at
# your accounts.
# -------------------------------------------------------------------
foreach ($repo in $ModuleRepos) {
    if (-not (Test-Path $repo)) { continue }
    $repoPath = (Resolve-Path $repo).Path
    $preflight = Join-Path $repoPath "scripts\preflight.ps1"
    if (-not (Test-Path $preflight)) { continue }

    Write-Host "`nPreflight: $(Split-Path $repoPath -Leaf)" -ForegroundColor Cyan
    try {
        & pwsh -NoProfile -ExecutionPolicy Bypass -File $preflight `
            -Target $Target -Port $port -VenvActivate $VenvActivate -PidFile $PidFile
    } catch {
        Write-Host "  Preflight failed (continuing): $_" -ForegroundColor Yellow
    }
}

# -------------------------------------------------------------------
# ngrok tunnel
# -------------------------------------------------------------------
$publicUrl = $null
$ngrokProc = $null

if ($FlaskDebug) {
    Write-Host "`nDebug mode: skipping ngrok (never expose the Werkzeug debugger)." -ForegroundColor Yellow
}
elseif ($NoPlaid) {
    Write-Host "`nNoPlaid mode: skipping ngrok/webhooks." -ForegroundColor Yellow
}
elseif (Get-Command ngrok -ErrorAction SilentlyContinue) {
    Get-Process ngrok -ErrorAction SilentlyContinue | Stop-Process -Force
    Write-Host "`nStarting ngrok tunnel (port $port)..."
    # Titled so the next run's sweep can recognise and close it. Untitled, this
    # window survived every restart: it is not on 5000-5002 (ngrok listens on
    # 4040), so the port cleanup never saw it.
    $ngrokTitle = "hub [$Target] - ngrok"
    $ngrokProc = Start-Process pwsh -ArgumentList "-NoExit", "-Command",
        "`$Host.UI.RawUI.WindowTitle = '$ngrokTitle'; ngrok http $port" -PassThru
    Register-Window $ngrokProc.Id
    Start-Sleep -Seconds 4
    try {
        $resp = Invoke-RestMethod -Uri "http://127.0.0.1:4040/api/tunnels" -UseBasicParsing
        $publicUrl = $resp.tunnels | Where-Object { $_.config.addr -match "$port" } |
                     Select-Object -First 1 -ExpandProperty public_url
        if ($publicUrl) {
            Write-Host "ngrok public URL: $publicUrl"
            $env:PLAID_WEBHOOK_URL = "$publicUrl/plaid/webhook"
        }
    } catch {
        Write-Host "Could not fetch ngrok public URL" -ForegroundColor Yellow
    }
} else {
    Write-Host "`nngrok not found in PATH. Skipping tunnel." -ForegroundColor Yellow
}

# -------------------------------------------------------------------
# Launch the hub
# -------------------------------------------------------------------
$flaskTitle = "hub [$Target] - Flask"
$webhookUrl = $env:PLAID_WEBHOOK_URL

# create_app() is a factory and takes no port, so the flask CLI is used in both
# modes. Finance mounts itself inside this app at "/" (see src/hub_module.py), so
# PLAID_WEBHOOK_URL and existing bookmarks are unaffected by the hub sitting above it.
$runLine = if ($FlaskDebug) {
    "python -m flask --app 'hub:create_app' run --debug --host $flaskHost --port $port"
} else {
    "python -m flask --app 'hub:create_app' run --host $flaskHost --port $port"
}

$flaskCmd = @"
[Console]::Title = '$flaskTitle';
`$Host.UI.RawUI.WindowTitle = '$flaskTitle';
Set-Location '$HubRoot';
. '$VenvActivate';
`$env:ENV_TARGET     = '$Target';
`$env:PLAID_ENV      = '$Target';
`$env:FLASK_RUN_PORT = '$port';
`$env:PLAID_WEBHOOK_URL = '$webhookUrl';
`$env:PLAID_DISABLED = '$($env:PLAID_DISABLED)';
`$env:FLASK_DEBUG    = '$($env:FLASK_DEBUG)';
$runLine
"@

$flaskArgs = if ($FlaskDebug) {
    @("-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", $flaskCmd)
} else {
    @("-NoExit", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", $flaskCmd)
}
$flaskProc = Start-Process pwsh -ArgumentList $flaskArgs -PassThru
Register-Window $flaskProc.Id

Start-Sleep -Seconds 3

if (-not $NoBrowser) {
    Start-Process "http://127.0.0.1:$port/hub"
    if ($publicUrl) { Start-Process $publicUrl }
}

Write-Host "`n=== Hub running [$Target] ===" -ForegroundColor Cyan
Write-Host "  Hub      http://127.0.0.1:$port/hub"
Write-Host "  Finance  http://127.0.0.1:$port/"
Write-Host "  Jobs     http://127.0.0.1:$port/jobs/"
Write-Host "  Ledger   http://127.0.0.1:$port/ledger/"
Write-Host "`nPress Enter (or Ctrl+C) here to stop everything.`n" -ForegroundColor Yellow

# -------------------------------------------------------------------
# Shutdown
# -------------------------------------------------------------------
$trackedPids = @($ngrokProc, $flaskProc) | Where-Object { $_ } | ForEach-Object { $_.Id }
if (Test-Path $PidFile) {
    $trackedPids += Get-Content $PidFile | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }
}

try {
    $null = Read-Host
} finally {
    Write-Host "`nShutting down..." -ForegroundColor Cyan

    # By port first — the most direct handle on the Flask process itself.
    $portPids = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty OwningProcess -Unique
    foreach ($procId in $portPids) {
        Write-Host "  Stopping Flask (PID $procId on port $port)"
        & taskkill /PID $procId /F 2>&1 | Out-Null
    }

    Get-Process ngrok -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host "  Stopping ngrok (PID $($_.Id))"
        & taskkill /PID $_.Id /F 2>&1 | Out-Null
    }

    # Windows started here, plus any a module's preflight reported via $PidFile.
    foreach ($procId in ($trackedPids | Sort-Object -Unique)) {
        if (Get-Process -Id $procId -ErrorAction SilentlyContinue) {
            Write-Host "  Closing window (PID $procId)"
            & taskkill /PID $procId /F /T 2>&1 | Out-Null
        }
    }

    # Backstop for anything that slipped the PID tracking — the same sweep the
    # next startup would do, so a window cannot survive both paths.
    Close-TaggedWindows | Out-Null

    Remove-Item $PidFile -ErrorAction SilentlyContinue
    Write-Host "`n=== All services stopped. ===" -ForegroundColor Green
}
