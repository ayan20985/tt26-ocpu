#requires -version 5.1
<#
.SYNOPSIS
    run all ocpu cocotb validation tests.

.DESCRIPTION
    delegates to test/run.py which uses the cocotb 2.x python runner.
    no `make` required. iverilog must be installed; the script
    automatically adds the default install location (C:\iverilog\bin)
    to PATH for this process.

    requirements:
        - python with cocotb >= 2.0 (`pip install -r test/requirements.txt`)
        - icarus verilog (winget install Icarus.Verilog)

.PARAMETER OneTest
    run only a single test function (e.g. -OneTest test_indy).

.PARAMETER Gates
    optional path to gate_level_netlist.v for gate-level simulation.

.PARAMETER Sim
    simulator backend ('icarus' default, or 'verilator' if installed).

.EXAMPLE
    pwsh tools\run_tests.ps1
    pwsh tools\run_tests.ps1 -OneTest test_indy
    pwsh tools\run_tests.ps1 -Gates path\to\gate_level_netlist.v
#>
[CmdletBinding()]
param(
    [string]$OneTest = "",
    [string]$Gates = "",
    [string]$Sim = "icarus"
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$testDir  = Join-Path $repoRoot "test"
$runner   = Join-Path $testDir "run.py"

if (-not (Test-Path $runner)) { throw "test/run.py not found at $runner" }

# bring iverilog onto PATH if it's installed at the default location and
# not already on the user's PATH.
$iverilogDefault = "C:\iverilog\bin"
if ((Test-Path $iverilogDefault) -and (-not (Get-Command iverilog -ErrorAction SilentlyContinue))) {
    $env:PATH = "$iverilogDefault;$env:PATH"
}

$pyArgs = @($runner, "--sim", $Sim)
if ($OneTest) { $pyArgs += @("--test", $OneTest) }
if ($Gates)   { $pyArgs += @("--gates", $Gates) }

Write-Host "==> python $($pyArgs -join ' ')" -ForegroundColor Cyan
& python @pyArgs
$rc = $LASTEXITCODE
if ($rc -ne 0) {
    throw "cocotb test run failed with exit code $rc"
}
Write-Host "==> all tests passed" -ForegroundColor Green
