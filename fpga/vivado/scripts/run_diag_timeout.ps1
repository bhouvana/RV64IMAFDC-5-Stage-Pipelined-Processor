param(
    [Parameter(Mandatory=$true)][string]$ModuleName,
    [string[]]$Generics = @(),
    [int]$TimeoutSec = 600
)
$repoRoot = "C:\Python\5-stage-pipelined-processor-main"
$vivado = "D:\2026.1\Vivado\bin\vivado.bat"
$logFile = "C:\Users\poorn\AppData\Local\Temp\claude\c--Python-5-stage-pipelined-processor-main\fbb56e94-1fb3-4a4e-8fc3-a78b2cdbee53\scratchpad\diag_$ModuleName.log"

$tclArgs = @($ModuleName) + $Generics
$argStr = ($tclArgs | ForEach-Object { "`"$_`"" }) -join " "

Push-Location $repoRoot
$psi = Start-Process -FilePath $vivado -ArgumentList @(
    "-mode","batch","-nolog","-nojournal",
    "-source","fpga/vivado/scripts/diag_module_synth.tcl",
    "-tclargs",$argStr
) -PassThru -RedirectStandardOutput $logFile -RedirectStandardError "$logFile.err" -WindowStyle Hidden
Pop-Location

$finished = $psi.WaitForExit($TimeoutSec * 1000)
if (-not $finished) {
    Write-Output "TIMEOUT after ${TimeoutSec}s -- killing process tree for module $ModuleName"
    Get-CimInstance Win32_Process -Filter "Name='vivado.exe'" | Where-Object {
        $p = $_; $cur = $p
        $isChild = $false
        while ($cur.ParentProcessId -and $cur.ParentProcessId -ne 0) {
            if ($cur.ParentProcessId -eq $psi.Id) { $isChild = $true; break }
            $cur = Get-CimInstance Win32_Process -Filter "ProcessId=$($cur.ParentProcessId)" -ErrorAction SilentlyContinue
            if (-not $cur) { break }
        }
        $isChild -or ($_.ProcessId -eq $psi.Id)
    } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Stop-Process -Id $psi.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Get-Process -Name vivado* -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Output "RESULT module=$ModuleName status=TIMEOUT"
} else {
    Write-Output "RESULT module=$ModuleName status=EXIT_CODE_$($psi.ExitCode)"
}
Write-Output "--- log tail ---"
Get-Content $logFile -Tail 40 -ErrorAction SilentlyContinue
