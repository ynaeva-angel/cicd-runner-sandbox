<#
.SYNOPSIS
  The one build-and-test entry point. The workflows and the local worker both call
  this script, so the two cannot drift.

.PARAMETER Stage
  all   (default) restore, build, SQL syntax check, [DB apply], test - what the worker runs.
  build restore + build. With -BaseRef, only the areas changed since that ref.
  test  run the *.xTest projects (all of them unless -Areas narrows it).
  db    SQL syntax check, plus DB apply when -DbApply is given.

.PARAMETER Areas
  Area names ticked in the PR body (Core, Web). Empty = run every *.xTest project.

.PARAMETER BaseRef
  Git ref to diff against (for a PR merge checkout: HEAD^1). Empty = build everything.

.PARAMETER DbApply
  Also apply Database/*.sql to a throwaway database on a SQL Server on this machine.

.PARAMETER SqlServer
  Instance for -DbApply. Default: $env:CI_SQL_SERVER, then LocalDB, .\SQLEXPRESS, localhost.

.PARAMETER ResultsDir
  Where the .trx files are written.
#>
[CmdletBinding()]
param(
    [ValidateSet('all', 'build', 'test', 'db')]
    [string]   $Stage = 'all',
    [string[]] $Areas = @(),
    [string]   $BaseRef = '',
    [switch]   $DbApply,
    [string]   $SqlServer = $env:CI_SQL_SERVER,
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

# Which projects does the change touch? $null = build the whole solution.
function Get-ChangedProjects([string] $Base) {
    $files = @(git diff --name-only $Base HEAD)
    if ($LASTEXITCODE -ne 0) { Write-Host "ci.ps1: cannot diff against '$Base', building everything"; return $null }
    $projects = @{}
    foreach ($f in $files) {
        if ($f -match '^(src|tests|tools)/([^/]+)/') {
            $proj = "$($Matches[1])/$($Matches[2])/$($Matches[2]).csproj"
            if (Test-Path $proj) { $projects[$proj] = $true } else { return $null }   # project added/removed: build all
        }
        elseif ($f -match '^(Database/|worker/|\.github/|.*\.md$)') { continue }       # nothing to compile
        else { Write-Host "ci.ps1: '$f' affects every project, building everything"; return $null }
    }
    return @($projects.Keys | Sort-Object)
}

function Invoke-Build {
    Invoke-Step 'restore' { dotnet restore Sandbox.sln --nologo }

    $targets = $null
    if ($BaseRef) { $targets = Get-ChangedProjects $BaseRef }
    if ($null -eq $targets) {
        Write-Host 'ci.ps1: build set = whole solution'
        Invoke-Step 'build' { dotnet build Sandbox.sln -c $Configuration --no-restore @buildFlags }
        return
    }
    if ($targets.Count -eq 0) {
        Write-Host 'ci.ps1: build set = none (no buildable area changed)'
        return
    }
    Write-Host "ci.ps1: build set = $($targets -join ', ')"
    foreach ($t in $targets) {
        Invoke-Step "build $t" { dotnet build $t -c $Configuration --no-restore @buildFlags }
    }
}

function Invoke-Db {
    # SQL syntax check (ScriptDom, SQL Server 2022 grammar). Parses only; nothing is executed.
    Invoke-Step 'validate-sql' {
        dotnet run --project tools/SqlSyntaxChecker -c $Configuration -- (Join-Path $PSScriptRoot 'Database')
    }
    if (-not $DbApply) { return }

    # Where to apply, in order of preference:
    #   1. -SqlServer / CI_SQL_SERVER   an instance you name (Windows authentication)
    #   2. a throwaway SQL Server 2022 container, when Docker is running on this machine
    #   3. a private LocalDB instance, then .\SQLEXPRESS, then localhost
    $servers = @()
    $container = $null
    if ($SqlServer) { $servers += $SqlServer }
    else {
        $container = Start-SqlContainer
        if ($container) { $servers += $container.Server }
        else {
            $ErrorActionPreference = 'Continue'
            if (Get-Command sqllocaldb -ErrorAction SilentlyContinue) {
                # A private LocalDB instance for CI, so nothing on the default instance is touched.
                sqllocaldb create ci-sandbox 2>&1 | Out-Null
                sqllocaldb start ci-sandbox 2>&1 | Out-Null
                $servers += @('(localdb)\ci-sandbox', '(localdb)\MSSQLLocalDB')
            }
            $ErrorActionPreference = 'Stop'
            $servers += @('.\SQLEXPRESS', 'localhost')
        }
    }

    # Applies the scripts, in order, to a throwaway database and drops it afterwards.
    Write-Host '::group::db-apply'
    try {
        if ($container) {
            $env:CI_SQL_USER = 'sa'; $env:CI_SQL_PASSWORD = $container.Password; $env:CI_SQL_WAIT_SECONDS = '120'
        }
        dotnet run --project tools/DbApply -c $Configuration -- (Join-Path $PSScriptRoot 'Database') @servers
        $code = $LASTEXITCODE
    }
    finally {
        $env:CI_SQL_USER = $null; $env:CI_SQL_PASSWORD = $null; $env:CI_SQL_WAIT_SECONDS = $null
        if ($container) {
            $ErrorActionPreference = 'Continue'
            docker rm -f $container.Name 2>&1 | Out-Null
            $ErrorActionPreference = 'Stop'
            Write-Host "ci.ps1: removed container $($container.Name)"
        }
    }
    Write-Host '::endgroup::'
    if ($code -ne 0) {
        Write-Host "ci.ps1: step 'db-apply' failed with exit code $code"
        exit $code
    }
}

# Starts a throwaway SQL Server 2022 container. Returns $null when Docker is not usable here.
function Start-SqlContainer {
    $ErrorActionPreference = 'Continue'
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Host 'ci.ps1: docker is not installed on this machine, falling back to a local SQL Server'
        return $null
    }
    docker info 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'ci.ps1: docker is installed but its engine is not reachable from this account, falling back'
        return $null
    }
    $name = "ci-sql-$PID"
    # Random per-run password; the container lives for one run and listens on loopback only.
    $password = 'Ci1!' + [guid]::NewGuid().ToString('N').Substring(0, 24)
    $image = 'mcr.microsoft.com/mssql/server:2022-latest'
    docker run -d --rm --name $name -e 'ACCEPT_EULA=Y' -e "MSSQL_SA_PASSWORD=$password" -e 'MSSQL_PID=Developer' `
        -p '127.0.0.1::1433' $image 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ci.ps1: could not start $image, falling back to a local SQL Server"
        return $null
    }
    $port = ("$(docker port $name 1433/tcp)" -split ':')[-1].Trim()
    Write-Host "ci.ps1: started container $name ($image) on 127.0.0.1,$port"
    return @{ Name = $name; Server = "127.0.0.1,$port"; Password = $password }
}

function Invoke-Tests {
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
        # Builds whatever the test project still needs, so it also works after a partial build.
        dotnet test $p.FullName -c $Configuration --nologo -m:1 -p:UseSharedCompilation=false `
            --logger "trx;LogFileName=$($p.BaseName).trx" --results-directory $ResultsDir
        if ($LASTEXITCODE -ne 0) { $failed++ }
        Write-Host '::endgroup::'
    }

    if ($failed -gt 0) {
        Write-Host "ci.ps1: $failed of $($projects.Count) test project(s) failed"
        exit 1
    }
    Write-Host "ci.ps1: $($projects.Count) test project(s) passed"
}

switch ($Stage) {
    'build' { Invoke-Build }
    'test'  { Invoke-Tests }
    'db'    { Invoke-Db }
    default { Invoke-Build; Invoke-Db; Invoke-Tests }
}
exit 0
