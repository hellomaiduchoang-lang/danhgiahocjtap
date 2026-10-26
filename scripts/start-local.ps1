$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$apiRoot = Join-Path $projectRoot "api"
$runtimeRoot = Join-Path $env:LOCALAPPDATA "ClassTrack\runtime"
$nodeDirectory = Join-Path $runtimeRoot "node-v24.22.1-win-x64"
$postgresDirectory = Join-Path $runtimeRoot "postgresql-18.6\pgsql"
$postgresBin = Join-Path $postgresDirectory "bin"
$dataDirectory = Join-Path $runtimeRoot "postgres-data"
$node = Join-Path $nodeDirectory "node.exe"
$npm = Join-Path $nodeDirectory "npm.cmd"
$pgCtl = Join-Path $postgresBin "pg_ctl.exe"
$envPath = Join-Path $apiRoot ".env"

foreach ($path in @($node, $npm, $pgCtl, $envPath)) {
  if (-not (Test-Path -LiteralPath $path)) {
    throw "ClassTrack is not set up yet. Run .\scripts\setup-local.ps1 first. Missing: $path"
  }
}

# Keep one predictable address. If the port is already serving ClassTrack, use
# that server; if another process owns it, stop with instructions instead of
# silently starting on a different address that could cause API 404s.
$configuredPort = 3000
$portLine = Get-Content -LiteralPath $envPath | Where-Object { $_ -match '^\s*PORT\s*=' } | Select-Object -Last 1
if ($portLine -and $portLine -match '^\s*PORT\s*=\s*(\d+)') {
  $configuredPort = [int]$Matches[1]
}
$address = "http://127.0.0.1:$configuredPort"
$portProbe = [System.Net.Sockets.TcpClient]::new()
try {
  $connection = $portProbe.BeginConnect([System.Net.IPAddress]::Loopback, $configuredPort, $null, $null)
  $portIsOpen = $connection.AsyncWaitHandle.WaitOne(500)
  if ($portIsOpen) {
    try { $portProbe.EndConnect($connection) } catch { $portIsOpen = $false }
  }
} finally {
  $portProbe.Dispose()
}
if ($portIsOpen) {
  try {
    $health = Invoke-RestMethod -Uri "$address/api/health" -TimeoutSec 2
    $sessionStatus = $null
    try {
      $null = Invoke-WebRequest -Uri "$address/api/session" -TimeoutSec 2 -UseBasicParsing
      $sessionStatus = 200
    } catch {
      if ($_.Exception.Response) { $sessionStatus = [int]$_.Exception.Response.StatusCode }
    }
    if ($health.status -eq "ok" -and $sessionStatus -in @(401, 403)) {
      Write-Host "ClassTrack is already running at $address. Open that address; no second server was started."
      exit 0
    }
  } catch {
    # The port is open, but it is not a healthy ClassTrack server.
  }
  throw "Port $configuredPort is in use by a different or outdated server. Stop that process, then run .\scripts\start-local.ps1 again."
}
$env:PORT = [string]$configuredPort
$env:APP_ORIGIN = $address

& $pgCtl -D $dataDirectory status *> $null
if ($LASTEXITCODE -ne 0) {
  $logPath = Join-Path $env:TEMP "ClassTrack-postgresql.log"
  & $pgCtl -D $dataDirectory -l $logPath -o "-h 127.0.0.1 -p 5432" start -w
  if ($LASTEXITCODE -ne 0) { throw "PostgreSQL failed to start. Inspect $logPath." }
}

$env:PATH = "$postgresBin;$nodeDirectory;$env:PATH"
Set-Location -LiteralPath $apiRoot
Write-Host "ClassTrack will open at $($env:APP_ORIGIN). Press Ctrl+C to stop the web server."
& $npm start
if ($LASTEXITCODE -ne 0) { throw "ClassTrack API exited with code $LASTEXITCODE." }
