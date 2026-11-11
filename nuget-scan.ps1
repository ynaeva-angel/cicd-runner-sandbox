<#
.SYNOPSIS
  NuGet security scan: lists packages with known vulnerabilities (direct and transitive)
  and fails when any is rated High or Critical. Lower ratings are reported, not failed.

.EXAMPLE
  ./nuget-scan.ps1
  ./nuget-scan.ps1 -FailOn Moderate,High,Critical
#>
[CmdletBinding()]
param(
    [string]   $Solution = (Join-Path $PSScriptRoot 'Sandbox.sln'),
    [string[]] $FailOn = @('High', 'Critical'),
    [string]   $ReportPath = (Join-Path $PSScriptRoot 'nuget-vulnerability-report.txt')
)

$ErrorActionPreference = 'Stop'

dotnet restore $Solution --nologo | Out-Host
if ($LASTEXITCODE -ne 0) { Write-Host 'nuget-scan: restore failed'; exit 2 }

$output = @(dotnet list $Solution package --vulnerable --include-transitive)
if ($LASTEXITCODE -ne 0) { $output | Out-Host; Write-Host 'nuget-scan: dotnet list package failed'; exit 2 }
$output | Out-Host
$output | Set-Content -Path $ReportPath -Encoding utf8

# Rows look like:  > Newtonsoft.Json   12.0.3   12.0.3   High   https://github.com/advisories/GHSA-...
$findings = @()
$project = ''
foreach ($line in $output) {
    if ($line -match "^Project [`'``](.+?)[`'``]") { $project = $Matches[1]; continue }
    if ($line -match '^\s*>\s*(\S+)\s+.*?\s(Low|Moderate|High|Critical)\s+(https?://\S+)') {
        $findings += [pscustomobject]@{ Project = $project; Package = $Matches[1]; Severity = $Matches[2]; Advisory = $Matches[3] }
    }
}

$blocking = @($findings | Where-Object { $FailOn -contains $_.Severity })
$summary = @('### NuGet security scan', '')
if ($findings.Count -eq 0) { $summary += 'No vulnerable packages found.' }
else {
    $summary += '| Project | Package | Severity | Advisory |'
    $summary += '|---|---|---|---|'
    foreach ($f in $findings) { $summary += "| $($f.Project) | $($f.Package) | $($f.Severity) | $($f.Advisory) |" }
}
if ($env:GITHUB_STEP_SUMMARY) { $summary | Add-Content -Path $env:GITHUB_STEP_SUMMARY -Encoding utf8 }

if ($blocking.Count -gt 0) {
    foreach ($f in $blocking) { Write-Host "::error::$($f.Severity) vulnerability in $($f.Package) ($($f.Project)): $($f.Advisory)" }
    Write-Host "nuget-scan: $($blocking.Count) blocking finding(s) ($($FailOn -join '/'))"
    exit 1
}
Write-Host "nuget-scan: $($findings.Count) finding(s), none blocking"
exit 0
