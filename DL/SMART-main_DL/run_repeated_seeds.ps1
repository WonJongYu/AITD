param(
    [string]$PythonBin = $(
        if ([string]::IsNullOrWhiteSpace($env:PYTHON_BIN)) { "python" }
        else { $env:PYTHON_BIN }
    ),
    [ValidateSet("auto", "cpu", "cuda")]
    [string]$Device = "auto",
    [int]$BatchSize = 64,
    [int]$PretrainEpochs = 25,
    [int]$FinetuneEpochs = 50,
    [ValidateSet("target-sensitivity", "f1", "youden")]
    [string]$ThresholdMethod = "target-sensitivity",
    [double]$TargetSensitivity = 0.90,
    [int[]]$Seeds = @(3407, 2024, 2025, 2026, 2027)
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$scriptDirectory = $PSScriptRoot
Push-Location -LiteralPath $scriptDirectory
try {
    $commandArguments = @(
        "run_repeated_seeds.py",
        "--device", $Device,
        "--batch-size", $BatchSize.ToString(),
        "--pretrain-epochs", $PretrainEpochs.ToString(),
        "--finetune-epochs", $FinetuneEpochs.ToString(),
        "--threshold-method", $ThresholdMethod,
        "--target-sensitivity", $TargetSensitivity.ToString(
            [System.Globalization.CultureInfo]::InvariantCulture
        ),
        "--seeds"
    )
    $commandArguments += $Seeds | ForEach-Object { $_.ToString() }
    & $PythonBin @commandArguments
    if ($LASTEXITCODE -ne 0) {
        throw "반복 seed 분석이 종료 코드 $LASTEXITCODE 로 실패했습니다."
    }
}
finally {
    Pop-Location
}

