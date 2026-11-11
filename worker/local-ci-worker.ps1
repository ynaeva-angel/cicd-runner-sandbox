<#
.SYNOPSIS
  Local CI worker (Section 7). Not a registered runner: it only talks to GitHub through
  the REST API, outbound 443.

  Every -PollSeconds it lists workflow runs that are waiting on the Environment
  (default "local-ci"), builds the head commit with the repo's own ci.ps1, posts a commit
  status and a PR comment, then approves (green) or rejects (red) the waiting "report" job.

.EXAMPLE
  ./worker/local-ci-worker.ps1 -Once          # one pass, then exit
  ./worker/local-ci-worker.ps1                # poll forever (what the service runs)

.NOTES
  Auth: uses the gh CLI. Either `gh auth login` as the Environment's required reviewer,
  or set $env:GH_TOKEN to that identity's token (in production: read it from Windows
  Credential Manager under the service account; never store it in the repo or in GitHub).
  Works in Windows PowerShell 5.1 and PowerShell 7.
#>
[CmdletBinding()]
param(
    [string] $Repo = 'ynaeva-angel/cicd-runner-sandbox',
    [string] $Environment = 'local-ci',
    [string] $StatusContext = 'CVCS local CI',
    [string] $WorkRoot = (Join-Path $env:LOCALAPPDATA 'local-ci-worker'),
    [int]    $PollSeconds = 60,
    [int]    $KeepResultsDays = 30,
    [switch] $Once
)

$ErrorActionPreference = 'Stop'
$psExe = (Get-Process -Id $PID).Path

function Write-Log([string] $Message) {
    Write-Host ("{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $Message)
}

function Invoke-GhJson([string] $Path) {
    $raw = & gh api $Path
    if ($LASTEXITCODE -ne 0) { throw "gh api $Path failed ($LASTEXITCODE)" }
    return ($raw -join "`n") | ConvertFrom-Json
}

function Send-GhJson([string] $Path, [hashtable] $Body) {
    $tmp = [IO.Path]::GetTempFileName()
    try {
        [IO.File]::WriteAllText($tmp, ($Body | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding $false))
        & gh api -X POST $Path --input $tmp | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "gh api POST $Path failed ($LASTEXITCODE)" }
    }
    finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}

function Set-CommitStatus([string] $Sha, [string] $State, [string] $Description, [string] $TargetUrl) {
    if ($Description.Length -gt 140) { $Description = $Description.Substring(0, 137) + '...' }
    $body = @{ state = $State; context = $StatusContext; description = $Description }
    if ($TargetUrl) { $body.target_url = $TargetUrl }
    Send-GhJson "repos/$Repo/statuses/$Sha" $body
}

function Get-RunStatus([long] $RunId) {
    return (Invoke-GhJson "repos/$Repo/actions/runs/$RunId").status
}

# Runs waiting on our Environment, newest first, one per PR (newest SHA wins).
function Get-WaitingJobs {
    $runs = @((Invoke-GhJson "repos/$Repo/actions/runs?status=waiting&per_page=50").workflow_runs)
    $jobs = @()
    $seenPr = @{}
    foreach ($run in ($runs | Sort-Object -Property created_at -Descending)) {
        $pending = @(Invoke-GhJson "repos/$Repo/actions/runs/$($run.id)/pending_deployments") |
            Where-Object { $_.environment.name -eq $Environment }
        if (-not $pending) { continue }
        $dep = @($pending)[0]
        if (-not $dep.current_user_can_approve) {
            Write-Log "run $($run.id): this identity is not a required reviewer of '$Environment', skipping"
            continue
        }

        $prNumber = $null
        if ($run.pull_requests -and @($run.pull_requests).Count -gt 0) {
            $prNumber = @($run.pull_requests)[0].number
        }
        else {
            $prs = @(Invoke-GhJson "repos/$Repo/commits/$($run.head_sha)/pulls")
            if ($prs.Count -gt 0) { $prNumber = $prs[0].number }
        }

        $key = "$prNumber"
        if ($prNumber -and $seenPr.ContainsKey($key)) {
            Write-Log "run $($run.id): superseded by a newer run on PR #$prNumber, rejecting"
            Send-GhJson "repos/$Repo/actions/runs/$($run.id)/pending_deployments" @{
                environment_ids = @($dep.environment.id); state = 'rejected'; comment = 'Superseded by a newer commit.'
            }
            continue
        }
        $seenPr[$key] = $true

        $jobs += [pscustomobject]@{
            RunId = [long]$run.id; Sha = $run.head_sha; PrNumber = $prNumber
            EnvironmentId = $dep.environment.id; RunUrl = $run.html_url
        }
    }
    return $jobs
}

function Get-TickedAreas([int] $PrNumber) {
    if (-not $PrNumber) { return @() }
    $body = (Invoke-GhJson "repos/$Repo/pulls/$PrNumber").body
    if (-not $body) { return @() }
    # Same rule as the hand-off job: "- [x] Area"
    return @([regex]::Matches($body, '(?m)^\s*[-*]\s*\[[xX]\]\s*([A-Za-z0-9_.]+)\s*\r?$') |
        ForEach-Object { $_.Groups[1].Value })
}

function Sync-Source([string] $Sha, $PrNumber) {
    $src = Join-Path $WorkRoot 'src'
    if (-not (Test-Path (Join-Path $src '.git'))) {
        New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null
        & gh repo clone $Repo $src -- --quiet
        if ($LASTEXITCODE -ne 0) { throw "clone of $Repo failed" }
    }
    if ($PrNumber) { & git -C $src fetch --quiet origin "+refs/pull/$PrNumber/head:refs/remotes/pull/$PrNumber" }
    else { & git -C $src fetch --quiet origin $Sha }
    if ($LASTEXITCODE -ne 0) { throw "fetch for $Sha failed" }
    & git -C $src checkout --quiet --force --detach $Sha
    if ($LASTEXITCODE -ne 0) { throw "checkout of $Sha failed" }
    & git -C $src clean -xdfq
    return $src
}

# Runs ci.ps1 as a child process. Returns the exit code, or $null when the waiting run
# disappeared (cancelled by a newer push) and the build was killed.
function Invoke-Build([string] $Src, [string[]] $Areas, [string] $OutDir, [long] $RunId) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Src 'ci.ps1'),
                 '-ResultsDir', (Join-Path $OutDir 'trx'))
    if ($Areas.Count -gt 0) { $argList += @('-Areas', ($Areas -join ',')) }

    $proc = Start-Process -FilePath $psExe -ArgumentList $argList -WorkingDirectory $Src -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $OutDir 'build.log') -RedirectStandardError (Join-Path $OutDir 'build.err.log')
    $null = $proc.Handle   # keeps ExitCode readable after exit

    $sinceCheck = 0
    while (-not $proc.WaitForExit(5000)) {
        $sinceCheck += 5
        if ($sinceCheck -ge 20) {
            $sinceCheck = 0
            if ((Get-RunStatus $RunId) -ne 'waiting') {
                & taskkill /PID $proc.Id /T /F | Out-Null
                return $null
            }
        }
    }
    return $proc.ExitCode
}

function Read-TestResults([string] $TrxDir) {
    $summary = [pscustomobject]@{ Total = 0; Passed = 0; Failed = 0; Failures = @() }
    if (-not (Test-Path $TrxDir)) { return $summary }
    foreach ($file in Get-ChildItem $TrxDir -Filter '*.trx') {
        [xml] $trx = Get-Content $file.FullName -Raw
        $c = $trx.TestRun.ResultSummary.Counters
        $summary.Total += [int]$c.total; $summary.Passed += [int]$c.passed; $summary.Failed += [int]$c.failed
        foreach ($r in @($trx.TestRun.Results.UnitTestResult | Where-Object { $_.outcome -eq 'Failed' })) {
            $msg = "$($r.Output.ErrorInfo.Message)".Trim() -replace '\s+', ' '
            if ($msg.Length -gt 300) { $msg = $msg.Substring(0, 297) + '...' }
            $summary.Failures += [pscustomobject]@{ Project = $file.BaseName; Test = $r.testName; Message = $msg }
        }
    }
    return $summary
}

function Invoke-Job($Job) {
    $short = $Job.Sha.Substring(0, 7)
    Write-Log "run $($Job.RunId): PR #$($Job.PrNumber) @ $short - building"
    $outDir = Join-Path (Join-Path $WorkRoot 'results') "$($Job.RunId)"
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null

    $areas = @(Get-TickedAreas $Job.PrNumber)
    $areaText = 'all'
    if ($areas.Count -gt 0) { $areaText = $areas -join ', ' }
    Set-CommitStatus $Job.Sha 'pending' "building on $env:COMPUTERNAME (areas: $areaText)" $Job.RunUrl

    $started = Get-Date
    $exit = 1; $errorText = $null
    try {
        $src = Sync-Source $Job.Sha $Job.PrNumber
        $exit = Invoke-Build $src $areas $outDir $Job.RunId
    }
    catch { $errorText = "$_" }

    if ($null -eq $exit) {
        Write-Log "run $($Job.RunId): no longer waiting (newer push or cancelled), build stopped"
        return
    }
    $minutes = [math]::Round(((Get-Date) - $started).TotalMinutes, 1)
    $tests = Read-TestResults (Join-Path $outDir 'trx')
    $ok = ($exit -eq 0) -and (-not $errorText)

    if ($ok) {
        $state = 'success'; $decision = 'approved'
        $desc = "$($tests.Passed)/$($tests.Total) tests passed in $minutes min on $env:COMPUTERNAME"
    }
    else {
        $state = 'failure'; $decision = 'rejected'
        if ($errorText) { $desc = "worker error: $errorText" }
        elseif ($tests.Failed -gt 0) { $desc = "$($tests.Failed) of $($tests.Total) tests failed ($minutes min on $env:COMPUTERNAME)" }
        else { $desc = "build failed, exit code $exit ($minutes min on $env:COMPUTERNAME)" }
    }

    $lines = @("### $StatusContext - $state", '', "Commit ``$short`` | areas: $areaText | $minutes min on ``$env:COMPUTERNAME`` | run $($Job.RunId)", '')
    if ($ok) { $lines += "All $($tests.Total) tests passed." }
    elseif ($tests.Failures.Count -gt 0) {
        $lines += "**$($tests.Failed) of $($tests.Total) tests failed:**"; $lines += ''
        foreach ($f in $tests.Failures) { $lines += "- ``$($f.Test)`` ($($f.Project))"; if ($f.Message) { $lines += "  - $($f.Message)" } }
    }
    else {
        $lines += $desc
        $log = Join-Path $outDir 'build.log'
        if (Test-Path $log) {
            $lines += ''; $lines += '```'; $lines += @(Get-Content $log -Tail 25); $lines += '```'
        }
    }

    if ((Get-RunStatus $Job.RunId) -ne 'waiting') {
        Write-Log "run $($Job.RunId): finished ($state) but the run is no longer waiting, nothing posted"
        return
    }
    Set-CommitStatus $Job.Sha $state $desc $Job.RunUrl
    if ($Job.PrNumber) { Send-GhJson "repos/$Repo/issues/$($Job.PrNumber)/comments" @{ body = ($lines -join "`n") } }
    Send-GhJson "repos/$Repo/actions/runs/$($Job.RunId)/pending_deployments" @{
        environment_ids = @($Job.EnvironmentId); state = $decision; comment = $desc
    }
    Write-Log "run $($Job.RunId): $state -> $decision ($desc)"
}

function Remove-OldResults {
    $root = Join-Path $WorkRoot 'results'
    if (-not (Test-Path $root)) { return }
    Get-ChildItem $root -Directory | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$KeepResultsDays) } |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Log "local CI worker for $Repo, environment '$Environment', work root $WorkRoot"
while ($true) {
    try {
        $jobs = @(Get-WaitingJobs)
        if ($jobs.Count -eq 0) { Write-Log 'nothing waiting' }
        foreach ($job in $jobs) { Invoke-Job $job }   # one at a time
        Remove-OldResults
    }
    catch { Write-Log "pass failed: $_" }
    if ($Once) { break }
    Start-Sleep -Seconds $PollSeconds
}
