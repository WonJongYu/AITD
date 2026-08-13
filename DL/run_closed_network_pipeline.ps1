# 길병원 폐쇄망에서 SQL 추출부터 SMART Task 1·2 학습까지 실행합니다.
# 사용 예:
#   .\run_closed_network_pipeline.ps1 -h HOST -p 5432 -U USER -d DATABASE

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$scriptDirectory = $PSScriptRoot
$sqlRunner = Join-Path $scriptDirectory "run_all_v2.ps1"
$modelRunner = Join-Path $scriptDirectory "SMART-main_DL\run_amiodarone.ps1"

if (-not (Test-Path -LiteralPath $sqlRunner -PathType Leaf)) {
    throw "SQL 실행 스크립트를 찾을 수 없습니다: $sqlRunner"
}
if (-not (Test-Path -LiteralPath $modelRunner -PathType Leaf)) {
    throw "SMART 실행 스크립트를 찾을 수 없습니다: $modelRunner"
}

Push-Location -LiteralPath $scriptDirectory
try {
    & $sqlRunner @args
    & $modelRunner
}
finally {
    Pop-Location
}

Write-Host "Closed-network SQL and SMART pipeline completed."

