#requires -version 5.1
<#
.SYNOPSIS
    full c -> 6502 -> ocpu binary pipeline.

.DESCRIPTION
    runs the following stages, in order:

      1. cc65   <source>.c                 ->  <source>.s         (6502 ca65)
      2. translate_6502.py                  ->  <source>.ocpu.s   (ocpu isa)
      3. ocpu_asm.py                        ->  <source>.hex      (16-bit words)
                                            +   <source>.data.json (data image)

    the resulting <source>.hex / .data.json pair can then be loaded into
    the cocotb testbench (`cocotb.start_soon(FpgaModel(...).servePages())`
    will consume them; see test/test_ocpu.py for the loader pattern).

.PARAMETER Source
    path to the .c file to compile.

.PARAMETER Cpu
    cc65 target cpu. defaults to 6502 (recommended).

.PARAMETER NoOptimize
    pass -O- to cc65 to disable optimisation. easier to debug translated
    output but produces longer ocpu code.

.EXAMPLE
    pwsh tools\build_c.ps1 -Source test\programs\c_src\hello.c
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$Source,
    [string]$Cpu = "6502",
    [switch]$NoOptimize,
    [switch]$NoMainEntry  # set when the translated program already has a
                          # custom entry sequence and doesn't need the
                          # synthetic JSR _main / HLT wrapper
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $Source)) {
    throw "source not found: $Source"
}
$Source = (Resolve-Path $Source).Path

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")

# tool discovery
function Find-Tool([string]$name) {
    # 1. PATH
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    # 2. repo-local cc65/bin (when the user has dropped the prebuilt
    #    snapshot zip directly under the repo, which is the path we
    #    document in tools/build_c.ps1)
    $local = Join-Path $repoRoot "cc65\bin\$name.exe"
    if (Test-Path $local) { return $local }
    # 3. user-local snapshot install
    $userLocal = Join-Path $env:LOCALAPPDATA "cc65\bin\$name.exe"
    if (Test-Path $userLocal) { return $userLocal }
    throw @"
required tool '$name' not found.
download the cc65 windows snapshot from
  https://sourceforge.net/projects/cc65/files/cc65-snapshot-win32.zip
and unzip it so that '$repoRoot\cc65\bin\$name.exe' exists.
"@
}

$cc65   = Find-Tool "cc65"
$python = Find-Tool "python"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$asm = Join-Path $PSScriptRoot "ocpu_asm.py"
$tx  = Join-Path $PSScriptRoot "translate_6502.py"

$base = [IO.Path]::ChangeExtension($Source, $null).TrimEnd('.')
$asmFile     = "$base.s"           # cc65 6502 output
$ocpuFile    = "$base.ocpu.s"      # translator output
$hexFile     = "$base.hex"         # final assembler output
$dataFile    = "$base.data.json"   # data image

Write-Host "==> cc65: $Source -> $asmFile" -ForegroundColor Cyan
$cc65Args = @("--cpu", $Cpu, "-t", "none", "-o", $asmFile, $Source)
if ($NoOptimize) { $cc65Args += "-O-" } else { $cc65Args += "-O" }
& $cc65 @cc65Args
if ($LASTEXITCODE -ne 0) { throw "cc65 failed (exit $LASTEXITCODE)" }

Write-Host "==> translate: $asmFile -> $ocpuFile" -ForegroundColor Cyan
$txArgs = @($asmFile, "-o", $ocpuFile)
if (-not $NoMainEntry) { $txArgs += "--main-entry" }
& $python $tx @txArgs
if ($LASTEXITCODE -ne 0) { throw "translator failed (exit $LASTEXITCODE)" }

Write-Host "==> assemble: $ocpuFile -> $hexFile (+ $dataFile)" -ForegroundColor Cyan
& $python $asm $ocpuFile -o $hexFile --data-out $dataFile
if ($LASTEXITCODE -ne 0) { throw "assembler failed (exit $LASTEXITCODE)" }

Write-Host ""
Write-Host "build successful." -ForegroundColor Green
Write-Host "    program  = $hexFile"
Write-Host "    data     = $dataFile"
Write-Host ""
Write-Host "to run in cocotb, point a new @cocotb.test at this binary by"
Write-Host "loading it via FpgaModel(..., pages=..., dataImage=...). see"
Write-Host "test/test_ocpu.py runProgram() for the reference pattern."
