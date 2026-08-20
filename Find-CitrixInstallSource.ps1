<#
.SYNOPSIS
    Find-CitrixInstallSource.ps1 -- READ-ONLY forensics to identify WHAT keeps
    installing Citrix Workspace, and which release track it delivers.

.DESCRIPTION
    Written for the case where Citrix Workspace is uninstalled cleanly and then
    reappears -- on HCDL-9N44WH3 it was removed at 15:17 on 17 Aug and was back
    and running by 09:29 the next morning, as Citrix Workspace 2603 (x64)
    26.3.10.69, i.e. the CURRENT RELEASE rather than the 2507 LTSR the fleet is
    standardised on.

    Until the installing agent is identified, remove-then-install-LTSR is a loop:
    whatever pushed Current Release will push it again.

    Windows records the answer in several independent places, and which one holds
    it tells you the mechanism:

      InstallSource / SourceList   the directory the installer actually ran from.
                                   A WS1 or ConfigMgr cache path means a managed
                                   push; a user's Downloads or Temp folder means
                                   somebody installed it by hand.
      MsiInstaller events          record every install with a Client Process Id
                                   and survive the uninstall, so they show the
                                   history even on a machine that is currently
                                   clean.
      Citrix bootstrapper logs     left under Windows\Temp and per-user Temp;
                                   usually contain the full command line.
      Prefetch                     proves which installer binary ran and when.
      ConfigMgr / WS1 caches       a Citrix payload sitting in a management
                                   agent's cache is close to proof of a push.
      Downloads folders            a CitrixWorkspaceApp*.exe in a user profile
                                   points at self-service installation from the
                                   Citrix or Storefront web page, which always
                                   serves Current Release, never LTSR.
      Scheduled tasks / services   a surviving updater task can reinstall on its
                                   own schedule.

    Everything here is read-only. Nothing is changed, removed or installed.

    Exit codes (WS1):
      0 = no evidence of a Citrix installer source found
      1 = evidence found (see the log; the summary names the likely mechanism)
      2 = could not run (not elevated)

.PARAMETER Days
    How far back to search event logs and file timestamps. Default 14.

.PARAMETER LtsrPrefix
    Version prefix considered the approved LTSR family. Default '25.7.'.
    Anything else found installed or cached is reported as release drift.

.NOTES
    Author  : MEB -- Oak Street Health / CVS Health IT Operations
    Version : 1.1.0
    Date    : 2026-08-20
    v1.1.0  : Rank mechanisms by how directly they name a culprit rather than
              by item count -- on HCDL-9N44WH3 the first run buried the real
              answer (4 downloaded installers) under 27 corroborating log
              folders and 28 install events. Also stopped printing an empty
              "(client PID )" for 1033 events, which carry no PID, and now
              calls out a management cache holding an APPROVED LTSR payload,
              since that is the deployment that should be running.
    Context : NT AUTHORITY\SYSTEM (WS1 Device context) or elevated admin
    PowerShell 5.1 compatible. Logs to C:\drop\citrix.
    Run this BEFORE uninstalling again -- an install that is still present
    carries far more evidence than one already removed.
#>

[CmdletBinding()]
param(
    [int]$Days = 14,
    [string]$LtsrPrefix = '25.7.'
)

$ScriptVersion     = '1.1.0'
$DestinationFolder = 'C:\drop\citrix'
$LogRetainDays     = 30

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
$script:LogFile = $null
$script:Findings = @()

function Initialize-Logging {
    if (-not (Test-Path -LiteralPath $DestinationFolder)) {
        New-Item -Path $DestinationFolder -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:LogFile = Join-Path $DestinationFolder "Citrix-InstallSource-$stamp.log"
    Get-ChildItem -LiteralPath $DestinationFolder -Filter 'Citrix-InstallSource-*.log' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$LogRetainDays) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Write-Log {
    param([string]$Message = '', [ValidateSet('INFO','WARNING','ERROR')][string]$Level = 'INFO')
    $line = ('{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message)
    switch ($Level) {
        'ERROR'   { Write-Host $line -ForegroundColor Red }
        'WARNING' { Write-Host $line -ForegroundColor Yellow }
        default   { Write-Host $line -ForegroundColor Gray }
    }
    if ($script:LogFile) { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue }
}

function Write-Section { param([string]$Title) Write-Log ''; Write-Log ("--- {0} {1}" -f $Title, ('-' * [math]::Max(0, 58 - $Title.Length))) }

function Add-Finding {
    param([Parameter(Mandatory)][string]$Mechanism, [Parameter(Mandatory)][string]$Evidence, [string]$Version = '')
    $script:Findings += [pscustomobject]@{ Mechanism = $Mechanism; Evidence = $Evidence; Version = $Version }
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-IsDrift {
    param([string]$Version)
    return ($Version -and $Version -notlike "$LtsrPrefix*")
}

# ---------------------------------------------------------------------------
# 1. Currently installed products + where they came from
# ---------------------------------------------------------------------------
function Find-InstalledAndSource {
    Write-Section 'Installed Citrix products and their install source'
    $any = $false
    foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        if (-not (Test-Path $root)) { continue }
        Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
            $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if (-not ($p.DisplayName -match 'Citrix')) { return }
            $any = $true
            Write-Log ("  {0}  v{1}" -f $p.DisplayName, $p.DisplayVersion)
            if ($p.InstallDate)   { Write-Log ("      InstallDate  : {0}" -f $p.InstallDate) }
            if ($p.InstallSource) {
                Write-Log ("      InstallSource: {0}" -f $p.InstallSource) 'WARNING'
                Add-Finding -Mechanism (Get-MechanismFromPath $p.InstallSource) -Evidence "InstallSource=$($p.InstallSource) for $($p.DisplayName)" -Version $p.DisplayVersion
            }
            if (Test-IsDrift $p.DisplayVersion) {
                Write-Log ("      *** RELEASE DRIFT: v{0} is not on the {1} LTSR track" -f $p.DisplayVersion, $LtsrPrefix) 'ERROR'
            }
        }
    }
    if (-not $any) { Write-Log '  No Citrix product currently installed (evidence below is historical).' }
}

function Get-MechanismFromPath {
    param([string]$Path)
    switch -Regex ($Path) {
        'ccmcache|ConfigMgr|CCM\\'          { return 'ConfigMgr/SCCM push' }
        'AirWatch|Workspace ?ONE|WS1|AWCM'  { return 'Workspace ONE push' }
        'Intune|IMECache|Microsoft\\Intune' { return 'Intune push' }
        '\\Users\\[^\\]+\\Downloads'        { return 'USER self-install (downloaded)' }
        '\\Users\\[^\\]+\\.*Temp'           { return 'USER self-install (from temp)' }
        '^\\\\'                             { return 'network share' }
        default                             { return 'unclassified path' }
    }
}

# ---------------------------------------------------------------------------
# 2. MSI source lists (survive better than InstallSource)
# ---------------------------------------------------------------------------
function Find-MsiSourceLists {
    Write-Section 'MSI source lists (historical, survives some uninstalls)'
    $root = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products'
    if (-not (Test-Path $root)) { Write-Log '  installer product database not readable'; return }
    $hits = 0
    foreach ($prod in (Get-ChildItem $root -ErrorAction SilentlyContinue)) {
        $ip = Get-ItemProperty -LiteralPath (Join-Path $prod.PSPath 'InstallProperties') -ErrorAction SilentlyContinue
        if (-not $ip -or $ip.DisplayName -notmatch 'Citrix') { continue }
        $hits++
        Write-Log ("  {0}  v{1}" -f $ip.DisplayName, $ip.DisplayVersion)
        if ($ip.InstallSource) {
            Write-Log ("      InstallSource: {0}" -f $ip.InstallSource) 'WARNING'
            Add-Finding -Mechanism (Get-MechanismFromPath $ip.InstallSource) -Evidence "MSI InstallSource=$($ip.InstallSource)" -Version $ip.DisplayVersion
        }
        foreach ($sub in @('SourceList','SourceList\Net','SourceList\URL')) {
            $sl = Get-ItemProperty -LiteralPath (Join-Path $prod.PSPath $sub) -ErrorAction SilentlyContinue
            if (-not $sl) { continue }
            foreach ($prop in ($sl.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' })) {
                if ($prop.Value -and $prop.Value -is [string] -and $prop.Value.Length -gt 3) {
                    Write-Log ("      {0}\{1} = {2}" -f $sub, $prop.Name, $prop.Value) 'WARNING'
                    Add-Finding -Mechanism (Get-MechanismFromPath $prop.Value) -Evidence "$sub\$($prop.Name)=$($prop.Value)" -Version $ip.DisplayVersion
                }
            }
        }
    }
    if (-not $hits) { Write-Log '  no Citrix entries in the installer product database' }
}

# ---------------------------------------------------------------------------
# 3. Event log -- installs recorded with the calling process
# ---------------------------------------------------------------------------
function Find-InstallEvents {
    Write-Section "MsiInstaller / install events (last $Days days)"
    $since = (Get-Date).AddDays(-$Days)
    $events = Get-WinEvent -FilterHashtable @{ LogName='Application'; StartTime=$since } -ErrorAction SilentlyContinue |
        Where-Object { $_.ProviderName -match 'MsiInstaller|Citrix' -and $_.Message -match 'Citrix' }
    if (-not $events) { Write-Log '  no matching install events'; return }

    # Installs/removals, newest first, with the client process that drove them.
    $interesting = $events | Where-Object { $_.Id -in @(1033,1034,11707,11724,1040,1042) } | Select-Object -First 60
    $pids = @{}
    foreach ($e in $interesting) {
        $msg = ($e.Message -replace '\s+',' ')
        $name = if ($msg -match 'Product Name:\s*([^.]+)\.') { $Matches[1].Trim() } else { '' }
        $ver  = if ($msg -match 'Product Version:\s*([^.]+(?:\.[^.]+)*?)\.\s') { $Matches[1].Trim() } else { '' }
        $cpid = if ($msg -match 'Client Process Id:\s*(\d+)') { $Matches[1] } else { '' }
        $verb = switch ($e.Id) { 1033 {'installed'} 11707 {'install completed'} 1034 {'removed'} 11724 {'removal completed'} default {'transaction'} }
        if ($name -or $cpid) {
            Write-Log ("  {0:yyyy-MM-dd HH:mm:ss}  Id={1,-5} {2,-18} {3} {4}{5}" -f `
                $e.TimeCreated, $e.Id, $verb, $name, $ver, $(if ($cpid) { "  [client PID $cpid]" } else { '' }))
        }
        if ($cpid) { $pids[$cpid] = $true }
        if ($e.Id -in @(1033,11707) -and $name -match 'Citrix' -and (Test-IsDrift $ver)) {
            $pidNote = if ($cpid) { " (client PID $cpid)" } else { '' }
            Add-Finding -Mechanism 'install event' -Evidence ("{0:yyyy-MM-dd HH:mm} {1} {2} installed{3}" -f $e.TimeCreated, $name, $ver, $pidNote) -Version $ver
        }
    }
    if ($pids.Keys.Count) {
        Write-Log ("  Client process IDs seen driving Citrix installs: {0}" -f (($pids.Keys | Sort-Object) -join ', ')) 'WARNING'
        Write-Log '  (a single repeated PID across separate days usually means a long-running management agent)'
    }
}

# ---------------------------------------------------------------------------
# 4. Citrix installer logs left on disk (often contain the command line)
# ---------------------------------------------------------------------------
function Find-CitrixInstallerLogs {
    Write-Section "Citrix installer logs on disk (last $Days days)"
    $since = (Get-Date).AddDays(-$Days)
    $dirs = @((Join-Path $env:SystemRoot 'Temp'), $env:TEMP)
    Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $dirs += (Join-Path $_.FullName 'AppData\Local\Temp')
    }
    $found = 0
    foreach ($d in ($dirs | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique)) {
        Get-ChildItem -LiteralPath $d -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'CTX|Citrix' -and $_.LastWriteTime -ge $since } |
            ForEach-Object {
                $found++
                Write-Log ("  {0}   (modified {1:yyyy-MM-dd HH:mm})" -f $_.FullName, $_.LastWriteTime) 'WARNING'
                Add-Finding -Mechanism 'installer log directory' -Evidence $_.FullName
            }
        Get-ChildItem -LiteralPath $d -File -Filter '*.log' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'CTX|Citrix|Workspace' -and $_.LastWriteTime -ge $since } |
            Select-Object -First 10 | ForEach-Object {
                $found++
                Write-Log ("  {0}   (modified {1:yyyy-MM-dd HH:mm})" -f $_.FullName, $_.LastWriteTime) 'WARNING'
            }
    }
    if (-not $found) { Write-Log '  none found' }
}

# ---------------------------------------------------------------------------
# 5. Management agent caches -- a payload here is close to proof of a push
# ---------------------------------------------------------------------------
function Find-ManagementCaches {
    Write-Section 'Management agent caches and logs'
    $roots = @(
        @{ Name='ConfigMgr/SCCM'; Path='C:\Windows\ccmcache' }
        @{ Name='Intune';         Path='C:\Program Files (x86)\Microsoft Intune Management Extension\Content' }
        @{ Name='Workspace ONE';  Path='C:\ProgramData\AirWatch' }
        @{ Name='Workspace ONE';  Path='C:\ProgramData\AirWatchMDM' }
    )
    $any = $false
    foreach ($r in $roots) {
        if (-not (Test-Path -LiteralPath $r.Path)) { continue }
        Write-Log ("  {0} present: {1}" -f $r.Name, $r.Path)
        $hits = Get-ChildItem -LiteralPath $r.Path -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'CitrixWorkspaceApp|CitrixReceiver|CWA.*\.exe' } | Select-Object -First 10
        foreach ($h in $hits) {
            $any = $true
            $v = $h.VersionInfo.FileVersion
            $isApproved = -not (Test-IsDrift $v)
            Write-Log ("    PAYLOAD: {0}  v{1}  (modified {2:yyyy-MM-dd HH:mm}){3}" -f `
                $h.FullName, $v, $h.LastWriteTime, $(if ($isApproved) { '   <-- APPROVED LTSR payload' } else { '   <-- NON-LTSR payload' })) `
                $(if ($isApproved) { 'WARNING' } else { 'ERROR' })
            if ($isApproved) {
                Write-Log ("    {0} already holds an approved LTSR installer. If Citrix is not installed, that deployment is not running -- check the assignment before blaming anything else." -f $r.Name) 'WARNING'
            }
            Add-Finding -Mechanism "$($r.Name) push" -Evidence $h.FullName -Version $v
        }
    }
    # WS1 agent logs naming Citrix
    $ws1Logs = 'C:\ProgramData\AirWatch\UnifiedAgent\Logs'
    if (Test-Path -LiteralPath $ws1Logs) {
        $since = (Get-Date).AddDays(-$Days)
        Get-ChildItem -LiteralPath $ws1Logs -File -Filter '*.log' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $since } | Select-Object -First 5 | ForEach-Object {
                $m = Select-String -LiteralPath $_.FullName -Pattern 'Citrix' -ErrorAction SilentlyContinue | Select-Object -First 5
                if ($m) {
                    $any = $true
                    Write-Log ("    WS1 log {0} mentions Citrix:" -f $_.Name) 'WARNING'
                    foreach ($line in $m) { Write-Log ("      {0}" -f $line.Line.Trim()) 'WARNING' }
                    Add-Finding -Mechanism 'Workspace ONE push' -Evidence "referenced in $($_.FullName)"
                }
            }
    }
    if (-not $any) { Write-Log '  no Citrix payload found in any management agent cache' }
}

# ---------------------------------------------------------------------------
# 6. Installers sitting in user profiles -- self-service installation
# ---------------------------------------------------------------------------
function Find-UserDownloadedInstallers {
    Write-Section 'Citrix installers in user profiles (self-service installation)'
    $any = $false
    Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        foreach ($sub in @('Downloads','Desktop','AppData\Local\Temp')) {
            $d = Join-Path $_.FullName $sub
            if (-not (Test-Path -LiteralPath $d)) { continue }
            Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match 'CitrixWorkspaceApp|CitrixReceiver' } |
                Select-Object -First 5 | ForEach-Object {
                    $any = $true
                    $v = $_.VersionInfo.FileVersion
                    Write-Log ("  {0}  v{1}  (modified {2:yyyy-MM-dd HH:mm})" -f $_.FullName, $v, $_.LastWriteTime) 'ERROR'
                    Add-Finding -Mechanism 'USER self-install (downloaded)' -Evidence $_.FullName -Version $v
                }
        }
    }
    if (-not $any) { Write-Log '  none found' }
    else {
        Write-Log '  NOTE: the Citrix/Storefront web download always serves CURRENT RELEASE, never LTSR.' 'ERROR'
    }
}

# ---------------------------------------------------------------------------
# 7. Prefetch -- proves which installer ran, and when
# ---------------------------------------------------------------------------
function Find-PrefetchEvidence {
    Write-Section 'Prefetch (which installer binary ran, and when)'
    $pf = Join-Path $env:SystemRoot 'Prefetch'
    if (-not (Test-Path -LiteralPath $pf)) { Write-Log '  prefetch not available'; return }
    $since = (Get-Date).AddDays(-$Days)
    $hits = Get-ChildItem -LiteralPath $pf -Filter '*.pf' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'CITRIX|CTX|BOOTSTRAPPER|WORKSPACE' -and $_.LastWriteTime -ge $since } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 15
    if (-not $hits) { Write-Log '  no relevant prefetch entries'; return }
    foreach ($h in $hits) { Write-Log ("  {0,-52} last run {1:yyyy-MM-dd HH:mm}" -f $h.Name, $h.LastWriteTime) 'WARNING' }
}

# ---------------------------------------------------------------------------
# 8. Scheduled tasks and services that could reinstall on their own
# ---------------------------------------------------------------------------
function Find-TasksAndServices {
    Write-Section 'Scheduled tasks and services referencing Citrix'
    $any = $false
    try {
        Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
            $_.TaskName -match 'Citrix|Receiver|Workspace' -or ($_.Actions.Execute -join ' ') -match 'Citrix'
        } | ForEach-Object {
            $any = $true
            $info = Get-ScheduledTaskInfo -TaskName $_.TaskName -TaskPath $_.TaskPath -ErrorAction SilentlyContinue
            Write-Log ("  TASK {0}{1}  state={2} lastRun={3}" -f $_.TaskPath, $_.TaskName, $_.State, $info.LastRunTime) 'WARNING'
            foreach ($a in $_.Actions) { if ($a.Execute) { Write-Log ("       -> {0} {1}" -f $a.Execute, $a.Arguments) 'WARNING' } }
            Add-Finding -Mechanism 'scheduled task' -Evidence "$($_.TaskPath)$($_.TaskName)"
        }
    } catch { Write-Log "  could not enumerate scheduled tasks: $($_.Exception.Message)" 'WARNING' }

    Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'Citrix|CWA|Receiver' } | ForEach-Object {
        $any = $true
        Write-Log ("  SERVICE {0} ({1}) status={2}" -f $_.Name, $_.DisplayName, $_.Status) 'WARNING'
        Add-Finding -Mechanism 'service' -Evidence $_.Name
    }
    if (-not $any) { Write-Log '  none found' }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
try { Initialize-Logging }
catch {
    Write-Host "FATAL: cannot create log directory '$DestinationFolder': $($_.Exception.Message)" -ForegroundColor Red
    exit 2
}

$exit = 0
try {
    Write-Log ('=' * 70)
    Write-Log "Citrix install-source forensics (READ-ONLY)  (script v$ScriptVersion)"
    Write-Log "Computer: $env:COMPUTERNAME   User: $(whoami)"
    Write-Log "Searching back $Days days.  Approved LTSR family: $LtsrPrefix*"
    if (-not (Test-IsAdmin)) {
        Write-Log 'Not elevated -- most evidence will be unreadable.' 'ERROR'
        $exit = 2; exit $exit
    }

    Find-InstalledAndSource
    Find-MsiSourceLists
    Find-InstallEvents
    Find-CitrixInstallerLogs
    Find-ManagementCaches
    Find-UserDownloadedInstallers
    Find-PrefetchEvidence
    Find-TasksAndServices

    Write-Section 'Conclusion'
    if (-not $script:Findings) {
        Write-Log '  No installer source identified. Either the evidence has aged out, or the'
        Write-Log '  install predates the search window. Re-run with a larger -Days, and run it'
        Write-Log '  again WHILE Citrix is installed -- a live install carries the InstallSource'
        Write-Log '  path, which is the single most direct answer.'
    } else {
        $exit = 1
        # Rank by how directly a mechanism names a culprit, NOT by item count.
        # Corroborating traces (installer log folders, install events) are the
        # most numerous and the least actionable, so counting would bury the
        # answer -- 27 log folders outranking 4 downloaded installers tells you
        # nothing useful.
        $weight = @{
            'USER self-install (downloaded)' = 100
            'USER self-install (from temp)'  = 95
            'ConfigMgr/SCCM push'            = 90
            'Workspace ONE push'             = 90
            'Intune push'                    = 90
            'network share'                  = 70
            'scheduled task'                 = 60
            'service'                        = 50
            'unclassified path'              = 40
            'installer log directory'        = 10
            'install event'                  = 5
        }
        $byMech = $script:Findings | Group-Object Mechanism |
            Sort-Object @{Expression={ if ($weight.ContainsKey($_.Name)) { $weight[$_.Name] } else { 30 } }; Descending=$true},
                        @{Expression='Count'; Descending=$true}
        foreach ($g in $byMech) {
            Write-Log ("  {0}  ({1} item(s))" -f $g.Name, $g.Count) 'WARNING'
            foreach ($f in ($g.Group | Select-Object -First 4)) {
                Write-Log ("      {0}{1}" -f $f.Evidence, $(if ($f.Version) { "  [v$($f.Version)]" } else { '' })) 'WARNING'
            }
        }
        $drift = @($script:Findings | Where-Object { Test-IsDrift $_.Version })
        if ($drift) {
            Write-Log ''
            Write-Log ("  RELEASE DRIFT confirmed: {0} item(s) reference a version outside the {1} LTSR family." -f $drift.Count, $LtsrPrefix) 'ERROR'
            Write-Log '  Stopping the source matters more than reinstalling LTSR -- otherwise it returns.' 'ERROR'
        }
        Write-Log ''
        Write-Log ("  Most likely mechanism: {0}" -f $byMech[0].Name) 'WARNING'
    }
}
catch {
    Write-Log "Unhandled exception: $($_.Exception.Message)" 'ERROR'
    Write-Log $_.ScriptStackTrace 'ERROR'
    $exit = 2
}
finally {
    Write-Log "Exit code: $exit"
    Write-Log ('=' * 70)
}

exit $exit
