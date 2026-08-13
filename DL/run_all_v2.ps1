# PostgreSQL 코호트·라벨·피처 추출 및 SMART CSV 생성을 실행합니다.
# 사용 예:
#   .\run_all_v2.ps1 -h HOST -p 5432 -U USER -d DATABASE

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$scriptDirectory = $PSScriptRoot
$sqlFile = Join-Path $scriptDirectory "run_all_v2.sql"

if (-not (Test-Path -LiteralPath $sqlFile -PathType Leaf)) {
    throw "SQL 실행 파일을 찾을 수 없습니다: $sqlFile"
}

Push-Location -LiteralPath $scriptDirectory
try {
    & psql @args -v "ON_ERROR_STOP=1" -f $sqlFile
    if ($LASTEXITCODE -ne 0) {
        throw "PostgreSQL 파이프라인이 종료 코드 $LASTEXITCODE 로 실패했습니다."
    }
}
finally {
    Pop-Location
}

