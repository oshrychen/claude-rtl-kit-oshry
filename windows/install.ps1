<#
  Claude-RTL Kit - Windows installer (BETA). ASCII-only on purpose: Windows PowerShell 5.1
  reads a BOM-less .ps1 as Windows-1252 and breaks on non-ASCII characters.

    powershell -ExecutionPolicy Bypass -File .\windows\install.ps1              # install / re-install
    powershell -ExecutionPolicy Bypass -File .\windows\install.ps1 -Check       # environment + prior-patch scan, no changes
    powershell -ExecutionPolicy Bypass -File .\windows\install.ps1 -Status
    powershell -ExecutionPolicy Bypass -File .\windows\install.ps1 -Uninstall

  What it does (mirrors mac/install.sh):
    1. checks Windows, Node >= 18, and which kind of Claude install this is:
         Squirrel  %LOCALAPPDATA%\AnthropicClaude\app-<ver>\     (classic installer, user-writable)
         MSIX      C:\Program Files\WindowsApps\Claude_*         (Microsoft Store style, locked)
    2. scans for PREVIOUS RTL patches (this project or others) and disables foreign watchers
    3. copies the vendored patch engine to %LOCALAPPDATA%\claude-rtl-kit\claude-desktop-rtl,
       builds the payload (with the Code-tab fix) and runs the test suite
    4. Squirrel: runs the upstream desktop\windows\patch.ps1 IN PLACE (claude.exe + app.asar are
       backed up to *.crtl-bak first; -Uninstall restores them). Unlike macOS there is no
       separate copy: Squirrel throws the whole app-<ver> folder away on every update anyway.
       If Claude is running (e.g. you are inside its Code tab) nothing is stopped: the watcher
       is installed and applies RTL within a minute of Claude being closed.
       MSIX: cannot be done from a normal shell. Prints the exact elevated command and stops.
    5. installs the per-user logon watcher (upstream watch.ps1) that re-applies RTL after every
       Claude update, with the real Node directory on its PATH
    6. verifies the result
#>
param(
  [switch]$Check,
  [switch]$Status,
  [switch]$Uninstall,
  [switch]$StopClaude,        # stop a running Claude Desktop and patch now instead of deferring
  [switch]$AcceptMsixChanges, # MSIX only, elevated shell: accept the invasive steps and run patch-msix.ps1
  [switch]$CI                 # CI smoke test: no watcher, no running-app logic, no notifications
)
$ErrorActionPreference = 'Stop'

$Kit        = (Resolve-Path (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..')).Path
$Src        = Join-Path $Kit 'source\claude-desktop-rtl'
$InstallDir = Join-Path $env:LOCALAPPDATA 'claude-rtl-kit\claude-desktop-rtl'
$WinDir     = Join-Path $InstallDir 'desktop\windows'
$PatchPs1   = Join-Path $WinDir 'patch.ps1'
$MsixPs1    = Join-Path $WinDir 'patch-msix.ps1'
$SquirrelBase = Join-Path $env:LOCALAPPDATA 'AnthropicClaude'
$Marker     = 'claude-rtl-payload-v1'
$FixMarker  = 'epitaxy-user-turn'
$ForeignMarkers = @('rtl-core', 'claude-rtl-styles', 'claude-rtl-banner', 'claude-rtl-font')
$ForeignTasks   = @('ClaudeRtlPatchWatcher', 'ClaudeRtlMsixWatcher')

function Log($m){ Write-Host "kit: $m" }
# PS 5.1 turns a native command's stderr into terminating errors when it is redirected and
# $ErrorActionPreference is Stop; run such commands with the preference relaxed.
function Invoke-Native([scriptblock]$sb) {
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { & $sb } finally { $ErrorActionPreference = $prev }
}
function Warn($m){ Write-Host "kit: WARNING - $m" -ForegroundColor Yellow }
function Die($m){ Write-Host "kit: ERROR - $m" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------- helpers ----
function Find-Node {
  if (Get-Command node -ErrorAction SilentlyContinue) { return }
  # Claude Desktop's Code tab (and any GUI-launched shell) can have a PATH without the
  # user's Node. Look in the usual places before declaring it missing.
  $candidates = @()
  $pairs = @(
    @($env:ProgramFiles, 'nodejs'),
    @(${env:ProgramFiles(x86)}, 'nodejs'),
    @($env:LOCALAPPDATA, 'Programs\nodejs'),
    @($env:LOCALAPPDATA, 'Volta\bin'),
    @($env:USERPROFILE, 'scoop\apps\nodejs\current'),
    @($env:USERPROFILE, 'scoop\apps\nodejs-lts\current')
  )
  foreach ($p in $pairs) { if ($p[0]) { $candidates += (Join-Path $p[0] $p[1]) } }
  if ($env:NVM_SYMLINK) { $candidates += $env:NVM_SYMLINK }
  $nvmHome = $env:NVM_HOME; if (-not $nvmHome -and $env:APPDATA) { $nvmHome = Join-Path $env:APPDATA 'nvm' }
  if ($nvmHome -and (Test-Path $nvmHome)) {
    $vers = Get-ChildItem $nvmHome -Directory -Filter 'v*' -ErrorAction SilentlyContinue |
            Sort-Object { try { [version]($_.Name.TrimStart('v')) } catch { [version]'0.0' } } -Descending
    foreach ($v in $vers) { $candidates += $v.FullName }
  }
  $fnm = Join-Path $env:LOCALAPPDATA 'fnm_multishells'
  if (Test-Path $fnm) {
    $latest = Get-ChildItem $fnm -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest) { $candidates += $latest.FullName }
  }
  foreach ($d in $candidates) {
    if ($d -and (Test-Path (Join-Path $d 'node.exe'))) {
      $env:PATH = "$d;$env:PATH"
      Log "node found outside PATH at $d - added for this run."
      return
    }
  }
}

function Get-SquirrelApp {
  if (-not (Test-Path $SquirrelBase)) { return $null }
  Get-ChildItem $SquirrelBase -Directory -Filter 'app-*' -ErrorAction SilentlyContinue |
    Sort-Object { try { [version]($_.Name -replace '^app-','') } catch { [version]'0.0' } } -Descending |
    Select-Object -First 1
}

function Get-MsixPackage {
  try { return (Get-AppxPackage -Name 'Claude*' -ErrorAction SilentlyContinue | Select-Object -First 1) }
  catch { return $null }
}

function Test-AsarContains($asar, $needle) {
  if (-not (Test-Path $asar)) { return $false }
  try { $fs = [IO.File]::OpenRead($asar) } catch { return $false }
  try {
    $enc = [Text.Encoding]::GetEncoding('ISO-8859-1'); $buf = New-Object byte[] (4MB); $tail = ''
    while (($n = $fs.Read($buf,0,$buf.Length)) -gt 0) {
      $s = $tail + $enc.GetString($buf,0,$n)
      if ($s.IndexOf($needle) -ge 0) { return $true }
      if ($s.Length -ge $needle.Length) { $tail = $s.Substring($s.Length - $needle.Length) }
    }
  } finally { $fs.Close() }
  return $false
}

function Get-RunningClaude {
  if (-not (Test-Path $SquirrelBase)) { return @() }
  @(Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($SquirrelBase, [StringComparison]::OrdinalIgnoreCase) })
}

# ---------------------------------------------------------------- 1. environment ----
$script:Model = $null; $script:App = $null; $script:NodeDir = $null
function Check-Env {
  if ($env:OS -ne 'Windows_NT') { Die "Windows only." }
  Find-Node
  $node = Get-Command node -ErrorAction SilentlyContinue
  if (-not $node) { Die "Node.js not found. Install Node 18+ from https://nodejs.org (or winget install OpenJS.NodeJS.LTS), then re-run." }
  # parse "v22.1.0" in PowerShell (PS 5.1 mangles quotes passed to node -p)
  $nodeVer = ((& node -v) | Out-String).Trim().TrimStart('v')
  $major = 0; try { $major = [int]($nodeVer.Split('.')[0]) } catch { $major = 0 }
  if ($major -lt 18) { Die "Node >= 18 required, have v$nodeVer." }
  if (-not (Get-Command npx -ErrorAction SilentlyContinue)) { Die "npx missing (comes with Node)." }
  $script:NodeDir = Split-Path -Parent $node.Source

  $sq = Get-SquirrelApp
  $ms = Get-MsixPackage
  if ($sq) {
    $script:Model = 'squirrel'; $script:App = $sq
    Log "env OK - Claude (Squirrel) at $($sq.FullName), node $(& node -v) at $script:NodeDir"
  } elseif ($ms) {
    $script:Model = 'msix'; $script:App = $ms
    Log "env OK - Claude (MSIX / Store) $($ms.Version) at $($ms.InstallLocation), node $(& node -v) at $script:NodeDir"
  } else {
    Die "Claude Desktop not found (no $SquirrelBase\app-* and no MSIX package). Install it from https://claude.com/download first."
  }
  if (-not (Test-Path (Join-Path $Src 'desktop\windows\patch.ps1'))) { Die "vendored source missing at $Src." }
  if (-not (Select-String -Path (Join-Path $Src 'dom\surfaces.js') -Pattern $FixMarker -SimpleMatch -Quiet)) { Die "vendored source lacks the Code-tab fix." }
}

# ------------------------------------------------------- 2. previous patches scan ----
$script:Foreign = @()
function Scan-Prior {
  Log "scanning for previous RTL patches..."
  $asar = $null
  if ($script:Model -eq 'squirrel') { $asar = Join-Path $script:App.FullName 'resources\app.asar' }
  elseif ($script:Model -eq 'msix') { $asar = Join-Path $script:App.InstallLocation 'app\resources\app.asar' }
  $found = @()
  foreach ($m in $ForeignMarkers) { if (Test-AsarContains $asar $m) { $found += $m } }
  $ours = Test-AsarContains $asar $Marker
  if ($found.Count -gt 0) {
    Warn "app.asar carries markers of ANOTHER RTL project: $($found -join ', ')."
    $bak = "$asar.bak"; $crtl = "$asar.crtl-bak"
    if (Test-Path $crtl) { Log "  a pristine backup exists ($crtl); the upstream patch.ps1 -Restore can bring it back." }
    elseif (Test-Path $bak) { Log "  a backup from that project exists ($bak). Use that project's uninstall/restore first, or reinstall Claude." }
    else { Warn "  no pristine backup found. Reinstall Claude from https://claude.com/download before continuing." }
    $script:Foreign += 'asar'
  } elseif ($ours) {
    Log "  app.asar already carries this kit's payload (will be refreshed)."
  } else {
    Log "  Claude's app.asar is pristine."
  }
  foreach ($t in $ForeignTasks) {
    $task = Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
    if ($task) { Log "  foreign scheduled task found: $t ($($task.State))"; $script:Foreign += "task:$t" }
  }
  $run = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue
  if ($run) {
    foreach ($p in $run.PSObject.Properties) {
      if ($p.Name -match 'rtl' -and $p.Name -ne 'ClaudeRtlWatcher') { Log "  foreign logon entry found: $($p.Name)"; $script:Foreign += "run:$($p.Name)" }
    }
  }
  if (Test-Path $InstallDir) { Log "  existing kit source at $InstallDir - will be refreshed." }
}

function Disable-Foreign {
  foreach ($f in $script:Foreign) {
    if ($f -like 'task:*') {
      $t = $f.Substring(5)
      try { Disable-ScheduledTask -TaskName $t -ErrorAction Stop | Out-Null; Log "  disabled foreign task $t (not deleted)." }
      catch { Warn "  could not disable task $t (may need an elevated shell): $($_.Exception.Message)" }
    } elseif ($f -like 'run:*') {
      $n = $f.Substring(4)
      try {
        $bk = 'HKCU:\Software\claude-rtl-kit\disabled-run-entries'
        New-Item -Path $bk -Force | Out-Null
        $val = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name $n).$n
        Set-ItemProperty -Path $bk -Name $n -Value $val
        Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name $n
        Log "  removed foreign logon entry $n (saved under HKCU\Software\claude-rtl-kit)."
      } catch { Warn "  could not remove logon entry $n : $($_.Exception.Message)" }
    }
  }
}

# ------------------------------------------------------------------ 3. source ----
function Install-Source {
  New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
  $rc = & robocopy $Src $InstallDir /MIR /XD node_modules dist .git /NFL /NDL /NJH /NJS /NP
  if ($LASTEXITCODE -ge 8) { Die "robocopy failed (exit $LASTEXITCODE)." }
  Copy-Item (Join-Path $Kit 'VERSIONS.md') (Join-Path $InstallDir 'KIT-VERSIONS.md') -Force -ErrorAction SilentlyContinue
  Log "source installed -> $InstallDir (upstream v0.2.21 + Code-tab fix, see VERSIONS.md)"
  Push-Location $InstallDir
  try {
    Log "building payload..."
    Invoke-Native { & node build\build-payload.js 2>&1 | Out-Null }
    if ($LASTEXITCODE -ne 0) { Die "build-payload.js failed." }
    if (-not (Select-String -Path 'dist\payload.js' -Pattern $FixMarker -SimpleMatch -Quiet)) { Die "built payload lacks the Code-tab fix." }
    Log "running the test suite..."
    # no globs: PowerShell does not expand them and only Node 21+ does; the default
    # pattern (**/*.test.js) covers engine/, dom/ and build/ on every Node version.
    $out = Invoke-Native { & node --test 2>&1 }
    $sum = ($out | Where-Object { $_ -match '^# (tests|pass|fail)|tests \d|pass \d|fail \d' }) -join ' '
    if ($LASTEXITCODE -ne 0) { $out | Out-File (Join-Path $env:TEMP 'claude-rtl-tests.log'); Die "tests failed - see $env:TEMP\claude-rtl-tests.log" }
    Log "tests OK ($sum)"
  } finally { Pop-Location }
}

# ------------------------------------------------------------------- 4. patch ----
function Patch-Squirrel {
  $running = @(); if (-not $CI) { $running = Get-RunningClaude }
  if ($running.Count -gt 0 -and -not $StopClaude) {
    Warn "Claude Desktop is running (you are probably inside it). Nothing is stopped."
    Warn "The watcher below applies RTL within about a minute after you CLOSE Claude (File > Quit or tray icon > Quit), then reopen it."
    $script:Deferred = $true
    return
  }
  $psArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$PatchPs1)
  if ($running.Count -gt 0) { $psArgs += '-Force' }
  & powershell @psArgs
  if ($LASTEXITCODE -ne 0) { Die "upstream patch.ps1 failed (see above). Undo with: powershell -ExecutionPolicy Bypass -File `"$PatchPs1`" -Restore" }
  $script:Deferred = $false
}

function Patch-Msix {
  $admin = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
  Write-Host ""
  Warn "This is the Microsoft Store (MSIX) build of Claude. Patching it is INVASIVE:"
  Warn "  - needs an elevated (Run as administrator) PowerShell,"
  Warn "  - takes ownership of Claude's package folder and modifies claude.exe + app.asar in place,"
  Warn "  - re-signs claude.exe with a self-signed certificate and adds it to the machine Trusted Root store"
  Warn "    (so Cowork keeps working). -Restore / -Cleanup revert all of it."
  Warn "  Alternative with zero prerequisites: the upstream one-click installer,"
  Warn "  https://github.com/liorshaya/claude-desktop-rtl/releases/latest (no Code-tab fix)."
  if (-not $admin -or -not $AcceptMsixChanges) {
    Write-Host ""
    Log "To proceed, open PowerShell AS ADMINISTRATOR and run:"
    Write-Host "  powershell -ExecutionPolicy Bypass -File `"$(Join-Path $Kit 'windows\install.ps1')`" -AcceptMsixChanges" -ForegroundColor Cyan
    Log "(Claude must be closed. This applies the patch and installs the auto-repatch task.)"
    exit 2
  }
  & powershell -NoProfile -ExecutionPolicy Bypass -File $MsixPs1 -Force
  if ($LASTEXITCODE -ne 0) { Die "upstream patch-msix.ps1 failed (see above). Undo with: powershell -ExecutionPolicy Bypass -File `"$MsixPs1`" -Restore" }
  & powershell -NoProfile -ExecutionPolicy Bypass -File $MsixPs1 -Watch
  if ($LASTEXITCODE -ne 0) { Warn "patch-msix.ps1 -Watch failed - RTL is applied but will not survive the next Claude update automatically." }
}

# ----------------------------------------------------------------- 5. watcher ----
function Install-Watcher {
  # The upstream watcher is a hidden PowerShell started at logon (HKCU Run key). launchd/systemd
  # have a bare PATH; on Windows the Run key inherits the user's PATH, but a Node that lives in a
  # non-standard folder still needs to be findable, so we pin the directory in the user PATH.
  $userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
  if ($userPath -notlike "*$script:NodeDir*") {
    [Environment]::SetEnvironmentVariable('PATH', "$script:NodeDir;$userPath", 'User')
    Log "added $script:NodeDir to the user PATH (for the logon watcher)."
  }
  & powershell -NoProfile -ExecutionPolicy Bypass -File $PatchPs1 -Watch
  if ($LASTEXITCODE -ne 0) { Die "watcher install failed." }
}

# ------------------------------------------------------------------ 6. verify ----
function Verify-Squirrel {
  $app = Get-SquirrelApp
  $asar = Join-Path $app.FullName 'resources\app.asar'
  $payload = Test-AsarContains $asar $Marker
  $fix = Test-AsarContains $asar $FixMarker
  if (-not $payload) { Die "verify: payload not found in $asar." }
  if (-not $fix) { Die "verify: Code-tab fix not found in $asar." }
  $exe = Join-Path $app.FullName 'claude.exe'
  $fuse = Invoke-Native { (& npx --yes @electron/fuses read --app $exe 2>&1 | Out-String) }
  $line = (($fuse -split "`n") | Where-Object { $_ -match 'EnableEmbeddedAsarIntegrityValidation' }) -join ''
  Log "verified $($app.FullName) - payload present, Code-tab fix present, $($line.Trim())"
}

function Show-Status {
  Check-Env
  if ($script:Model -eq 'squirrel') {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $PatchPs1 -Status
    $asar = Join-Path $script:App.FullName 'resources\app.asar'
    Log "code-tab fix : $(Test-AsarContains $asar $FixMarker)"
  } else {
    if (Test-Path $MsixPs1) { & powershell -NoProfile -ExecutionPolicy Bypass -File $MsixPs1 -Status } else { Log "kit source not installed yet." }
  }
  Log "kit source   : $(if (Test-Path $PatchPs1) { $InstallDir } else { 'not installed' })"
  Log "watch log    : $env:LOCALAPPDATA\claude-rtl\watch.log"
}

function Do-Uninstall {
  Check-Env
  if (-not (Test-Path $PatchPs1)) { Log "kit source not installed; nothing to remove."; return }
  if ($script:Model -eq 'squirrel') {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $PatchPs1 -Unwatch
    & powershell -NoProfile -ExecutionPolicy Bypass -File $PatchPs1 -Restore -Force
    Log "restored the pristine claude.exe + app.asar and removed the watcher."
  } else {
    Log "MSIX: run from an ELEVATED PowerShell:"
    Write-Host "  powershell -ExecutionPolicy Bypass -File `"$MsixPs1`" -Cleanup" -ForegroundColor Cyan
  }
  Log "kit source kept at $InstallDir (delete it if you want)."
}

# ------------------------------------------------------------------ dispatch ----
$script:Deferred = $false
if ($Status)    { Show-Status; exit 0 }
if ($Uninstall) { Do-Uninstall; exit 0 }
if ($Check)     { Check-Env; Scan-Prior; exit 0 }

Check-Env
Scan-Prior
if ($script:Foreign -contains 'asar') { Die "another project's patch is inside Claude's app.asar - restore or reinstall Claude first (see above), then re-run." }
if ($script:Foreign.Count -gt 0 -and -not $CI) { Disable-Foreign }
Install-Source
if ($script:Model -eq 'msix') { Patch-Msix; exit 0 }
Patch-Squirrel
if (-not $CI) { Install-Watcher }
if ($script:Deferred) {
  Write-Host ""
  Log "NEXT STEP: close Claude Desktop completely. The watcher patches it within about a minute (log: $env:LOCALAPPDATA\claude-rtl\watch.log). Then open Claude again."
  Log "           To patch immediately instead (this closes Claude): re-run with -StopClaude"
} else {
  Verify-Squirrel
  Write-Host ""
  Log "DONE. Open Claude Desktop - Hebrew/Arabic now render right-to-left. Undo anytime with -Uninstall."
}
