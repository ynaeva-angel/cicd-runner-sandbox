# cicd-runner-sandbox

A throwaway repo for trying CI/CD runner flows away from the corporate organisation.
It contains a tiny generic .NET solution (a calculator and a greeter), nothing from any product.

Two flows can be tested here:

| Flow | What it proves | Files |
|---|---|---|
| **Hand-off** (Section 7) | A PR is built on a local machine that is *not* a registered runner. The shared runner is held for seconds; the `report` job waits on an Environment and is approved or rejected by the local worker. | `.github/workflows/pr-validation.yml`, `worker/local-ci-worker.ps1`, `worker/stale-guard.ps1` |
| **Dedicated runner** (Section 6) | A newly registered self-hosted runner can build before it is given the pool labels. | `.github/workflows/runner-smoke.yml` |

Both call the same `ci.ps1` (restore, build with `-m:1`, `dotnet test` on every `*.xTest.csproj`), so the workflow and the worker cannot drift.

## Layout

```
ci.ps1                         build + test entry point (-Areas Core,Web to narrow the tests)
src/Sandbox.Core, Sandbox.Web  two small libraries
tests/*.xTest                  xUnit projects, 4 tests each
worker/local-ci-worker.ps1     polls for waiting runs, builds, posts status + comment, approves/rejects
worker/stale-guard.ps1         rejects runs that waited too long ("Angel worker unreachable")
.github/pull_request_template.md   the "Areas to test" checkboxes
```

## Test the hand-off flow

Needs on the local machine: git, the .NET 8 SDK, and the `gh` CLI logged in as the Environment's
required reviewer (`gh auth status`). Classic tokens need the `repo` scope.

1. Open a PR against `main` (or any `sprint/**` branch):

   ```powershell
   git switch -c demo/change
   # edit something under src/ or tests/
   git commit -am "Try the hand-off"; git push -u origin demo/change
   gh pr create --fill
   ```

2. Within a minute the PR shows status **CVCS local CI - pending** and the run sits at
   "Waiting for review" on Environment `local-ci`. No runner is held at this point.

3. Run the worker:

   ```powershell
   ./worker/local-ci-worker.ps1 -Once     # one pass
   ./worker/local-ci-worker.ps1           # poll every 60 s until stopped
   ```

   It fetches the PR head into `%LOCALAPPDATA%\local-ci-worker\src`, runs `ci.ps1`, then:
   - tests pass: status `success`, PR comment, the `report` job is **approved** and ends green;
   - build or tests fail: status `failure`, PR comment listing the failing tests, the job is **rejected** and the run goes red.

Things worth trying:

- **Red path**: change `a + b` to `a - b` in `src/Sandbox.Core/Calculator.cs` and push.
- **Area selection**: tick `- [x] Core` in the PR body; only `Sandbox.Core.xTest` runs.
- **Superseded push**: push a second commit while the worker is building; the old run is cancelled by `concurrency`, the worker stops that build and picks up the new one on the next pass.
- **Worker offline**: leave a run waiting and run `./worker/stale-guard.ps1 -MaxWaitMinutes 0` (add `-WhatIf` for a dry run).

To run it against another repo: `-Repo owner/name -Environment local-ci`.
Logs and `.trx` files are kept 30 days under `%LOCALAPPDATA%\local-ci-worker\results\<run id>`.

## Test a dedicated self-hosted runner

1. Repo **Settings > Actions > Runners > New self-hosted runner** (Windows x64) and follow the
   download steps. When configuring, add the extra label and keep it out of any shared group:

   ```powershell
   ./config.cmd --url https://github.com/ynaeva-angel/cicd-runner-sandbox --token <registration token> --labels angel --name sandbox-runner
   ./run.cmd          # or install as a service with ./svc.cmd install; ./svc.cmd start
   ```

2. Trigger the smoke test and watch it:

   ```powershell
   gh workflow run runner-smoke.yml -f label=angel
   gh run watch
   ```

The job is pinned to `[self-hosted, windows, x64, angel]`, so it never lands on a hosted runner
and nothing else in this repo ever lands on the self-hosted one.

Because this repo is public, never let a fork's PR run on the self-hosted runner. The smoke
workflow is `workflow_dispatch` only, and the repo is set to require approval before any
outside contributor's workflow runs. Remove the runner when testing is done
(`./config.cmd remove`).

## How this maps to the real pipeline

| Sandbox | Real repo |
|---|---|
| hosted `ubuntu-latest` for `hand-off` and `report` | the shared enterprise runner pool |
| Environment `local-ci`, reviewer = repo owner | Environment `local-ci`, reviewer = the worker's identity |
| `gh auth login` on the dev PC | fine-grained token in Windows Credential Manager under the service account |
| `Sandbox.sln`, 2 test projects | 14 solutions, 5 `*.xTest` projects |
| checkboxes `Core`, `Web` | the 13 area checkboxes |

## SQL check and NuGet scan

- **SQL syntax check**: `ci.ps1` runs `tools/SqlSyntaxChecker` over every `.sql` under `Database/`
  (ScriptDom, SQL Server 2022 grammar; nothing is executed, no database needed). A syntax error
  fails the build wherever `ci.ps1` runs: the local worker and the self-hosted runner.
- **NuGet security scan**: `.github/workflows/nuget-security-scan.yml` runs `nuget-scan.ps1` on a
  GitHub-hosted Windows runner for every PR push, monthly, and on demand. It fails on High or
  Critical findings, direct or transitive. Run it locally with `./nuget-scan.ps1`.
- `nuget.config` pins nuget.org, so a build machine with no user-level NuGet source still restores.
