#requires -version 5.1
<#
.SYNOPSIS
    one-shot c -> ocpu execution + final state dump.

.DESCRIPTION
    end-to-end developer convenience wrapper:

      1. runs `tools\build_c.ps1` on -Source (default: test\programs\c_src\user.c)
         to produce a .hex + .data.json pair.
      2. invokes the cocotb runner with --program <hex> so the
         `test_user_program` test loads the binary onto the cpu, runs
         it to halt, and dumps:
            * a / x / y / sp / sr (with N V Z C I broken out)
            * page_reg and data_page
            * the iram page the cpu was sitting in when HLT executed
            * every page the FpgaModel ever shipped to iram (the full
              program image, in the order they were loaded)
            * the entire dram dictionary (initial .data image plus every
              byte the program wrote at runtime)

    intended workflow:

        # edit the c source...
        notepad test\programs\c_src\user.c
        # ...then run:
        pwsh tools\run_c.ps1

    pass -Source to point at a different file. pass -NoBuild to skip the
    compile stage when you only changed the cocotb / testbench side.

.PARAMETER Source
    path to the c source. defaults to test\programs\c_src\user.c.

.PARAMETER NoBuild
    skip the cc65 + translate + assemble stages and just run the
    existing .hex.

.PARAMETER MaxCycles
    cycle budget for the simulation (default 50000). bump this if your
    program loops longer than the default.

.EXAMPLE
    pwsh tools\run_c.ps1
.EXAMPLE
    pwsh tools\run_c.ps1 -Source test\programs\c_src\sum_arr.c
.EXAMPLE
    pwsh tools\run_c.ps1 -NoBuild -MaxCycles 200000
#>
[CmdletBinding()]
param(
    [string]$Source = "test\programs\c_src\user.c",
    [switch]$NoBuild,
    [int]$MaxCycles = 50000
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $Source)) {
    throw "source file not found: $Source"
}
$Source = (Resolve-Path $Source).Path

$repoRoot   = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$hexFile    = [IO.Path]::ChangeExtension($Source, "hex")
$buildC     = Join-Path $PSScriptRoot "build_c.ps1"
$runPy      = Join-Path $repoRoot     "test\run.py"

if (-not $NoBuild) {
    Write-Host "==> compiling $Source" -ForegroundColor Cyan
    & powershell.exe -ExecutionPolicy Bypass -File $buildC -Source $Source
    if ($LASTEXITCODE -ne 0) {
        throw "build_c.ps1 failed (exit $LASTEXITCODE)"
    }
} else {
    Write-Host "==> -NoBuild: skipping compile, expecting $hexFile to exist" `
        -ForegroundColor Yellow
}

if (-not (Test-Path $hexFile)) {
    throw "expected hex file $hexFile not found after build."
}

# auto-add iverilog to PATH for this process if user installed it to the
# default windows path without putting it on PATH globally
$iverilogDefault = "C:\iverilog\bin"
if ((Test-Path $iverilogDefault) -and (-not ($env:Path -split ';' -contains $iverilogDefault))) {
    $env:Path = "$iverilogDefault;$env:Path"
}

Write-Host ""
Write-Host "==> running $hexFile on the ocpu" -ForegroundColor Cyan
Write-Host ""
& python $runPy --program $hexFile --max-cycles $MaxCycles
$rc = $LASTEXITCODE

Write-Host ""
if ($rc -eq 0) {
    Write-Host "==> done. scroll up to the FINAL CPU STATE block for the dump." `
        -ForegroundColor Green
} else {
    Write-Host "==> cocotb runner exited with code $rc" -ForegroundColor Red
}
exit $rc
