param(
    [Parameter(Mandatory=$true)][string]$TclScript,
    [Parameter(Mandatory=$true)][string]$LogName,
    [int]$TimeoutSec = 1800
)
$repoRoot = "C:\Python\5-stage-pipelined-processor-main"
$vivado = "D:\2026.1\Vivado\bin\vivado.bat"
$logFile = "C:\Users\poorn\AppData\Local\Temp\claude\c--Python-5-stage-pipelined-processor-main\fbb56e94-1fb3-4a4e-8fc3-a78b2cdbee53\scratchpad\$LogName.log"

Push-Location $repoRoot
$psi = Start-Process -FilePath $vivado -ArgumentList @(
    "-mode","batch","-nolog","-nojournal","-source",$TclScript
) -PassThru -RedirectStandardOutput $logFile -RedirectStandardError "$logFile.err" -WindowStyle Hidden
Pop-Location

$finished = $psi.WaitForExit($TimeoutSec * 1000)
if (-not $finished) {
    Write-Output "TIMEOUT after ${TimeoutSec}s -- killing"
    Get-Process -Name vivado* -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Output "RESULT $LogName status=TIMEOUT"
} else {
    Write-Output "RESULT $LogName status=EXIT_CODE_$($psi.ExitCode)"
}
Write-Output "--- log tail ---"
Get-Content $logFile -Tail 50 -ErrorAction SilentlyContinue
