<#
.SYNOPSIS
  The one build-and-test entry point. The workflows and the local worker both call
  this script, so the two cannot drift.

.PARAMETER Areas
  Area names ticked in the PR body (Core, Web). Empty = run every *.xTest project.

.PARAMETER ResultsDir
  Where the .trx files are written.
#>
[CmdletBinding()]
param(
    [string[]] $Areas = @(),
    [string]   $Configuration = 'Release',
    [string]   $ResultsDir = (Join-Path $PSScriptRoot 'TestResults')
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

# A single comma-separated string ("Core,Web") is accepted as well as an array.
$Areas = @($Areas | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

# Same flags as the real pipeline: one MSBuild node, no compiler server, no node reuse.
$buildFlags = @('-m:1', '-nodeReuse:false', '-p:UseSharedCompilation=false', '--nologo')

function Invoke-Step([string] $Name, [scriptblock] $Body) {
    Write-Host "::group::$Name"
    & $Body
    $code = $LASTEXITCODE
    Write-Host '::endgroup::'
    if ($code -ne 0) {
        Write-Host "ci.ps1: step '$Name' failed with exit code $code"
        exit $code
    }
}

Invoke-Step 'restore' { dotnet restore Sandbox.sln --nologo }
Invoke-Step 'build'   { dotnet build Sandbox.sln -c $Configuration --no-restore @buildFlags }

# SQL syntax check (ScriptDom, SQL Server 2022 grammar). Parses only; nothing is executed.
Invoke-Step 'validate-sql' {
    dotnet run --project tools/SqlSyntaxChecker -c $Configuration --no-build -- (Join-Path $PSScriptRoot 'Database')
}

# Discover test projects the same way the real pipeline does: *.xTest.csproj
$projects = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'tests') -Recurse -Filter '*.xTest.csproj')
if ($Areas.Count -gt 0) {
    $projects = @($projects | Where-Object {
        $name = $_.BaseName
        @($Areas | Where-Object { $name -ieq "Sandbox.$_.xTest" }).Count -gt 0
    })
}
if ($projects.Count -eq 0) {
    Write-Host "ci.ps1: no test project matches areas '$($Areas -join ', ')'"
    exit 2
}

if (Test-Path $ResultsDir) { Remove-Item $ResultsDir -Recurse -Force }
New-Item -ItemType Directory -Path $ResultsDir -Force | Out-Null

$failed = 0
foreach ($p in $projects) {
    Write-Host "::group::test $($p.BaseName)"
    dotnet test $p.FullName -c $Configuration --no-build --nologo `
        --logger "trx;LogFileName=$($p.BaseName).trx" --results-directory $ResultsDir
    if ($LASTEXITCODE -ne 0) { $failed++ }
    Write-Host '::endgroup::'
}

if ($failed -gt 0) {
    Write-Host "ci.ps1: $failed of $($projects.Count) test project(s) failed"
    exit 1
}
Write-Host "ci.ps1: $($projects.Count) test project(s) passed"
exit 0
