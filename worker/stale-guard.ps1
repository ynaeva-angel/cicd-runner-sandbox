<#
.SYNOPSIS
  Stale guard (Section 7). Rejects runs that have waited on the Environment longer than
  -MaxWaitMinutes, so a powered-off worker gives a red check instead of a run stuck for
  30 days. Meant to run hourly as a scheduled task on a second PC, with the reviewer's
  token on that PC (gh auth login, or $env:GH_TOKEN).

.EXAMPLE
  ./worker/stale-guard.ps1 -MaxWaitMinutes 120
  ./worker/stale-guard.ps1 -MaxWaitMinutes 0 -WhatIf     # show what would be rejected
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $Repo = 'ynaeva-angel/cicd-runner-sandbox',
    [string] $Environment = 'local-ci',
    [string] $StatusContext = 'CVCS local CI',
    [int]    $MaxWaitMinutes = 120
)

$ErrorActionPreference = 'Stop'

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

$message = 'Angel worker unreachable'
$cutoff = (Get-Date).ToUniversalTime().AddMinutes(-$MaxWaitMinutes)
$runs = @((Invoke-GhJson "repos/$Repo/actions/runs?status=waiting&per_page=50").workflow_runs)
$rejected = 0

foreach ($run in $runs) {
    $since = ([datetimeoffset]$run.run_started_at).UtcDateTime
    if ($since -gt $cutoff) { continue }
    $dep = @(@(Invoke-GhJson "repos/$Repo/actions/runs/$($run.id)/pending_deployments") |
        Where-Object { $_.environment.name -eq $Environment })[0]
    if (-not $dep) { continue }

    $waited = [int]((Get-Date).ToUniversalTime() - $since).TotalMinutes
    if ($PSCmdlet.ShouldProcess("run $($run.id) (waiting $waited min)", 'reject')) {
        Send-GhJson "repos/$Repo/statuses/$($run.head_sha)" @{
            state = 'error'; context = $StatusContext; target_url = $run.html_url
            description = "$message (waited $waited min)"
        }
        Send-GhJson "repos/$Repo/actions/runs/$($run.id)/pending_deployments" @{
            environment_ids = @($dep.environment.id); state = 'rejected'; comment = "$message (waited $waited min)"
        }
        $rejected++
        Write-Host "rejected run $($run.id) after $waited min"
    }
}
Write-Host "stale guard: $rejected run(s) rejected, $($runs.Count) waiting run(s) inspected"
