param(
    [string]$PythonBin = $(
        if ([string]::IsNullOrWhiteSpace($env:PYTHON_BIN)) { "python" }
        else { $env:PYTHON_BIN }
    ),
    [ValidateSet("auto", "cpu", "cuda")]
    [string]$Device = $(
        if ([string]::IsNullOrWhiteSpace($env:DEVICE)) { "auto" }
        else { $env:DEVICE }
    ),
    [int]$Seed = $(
        if ([string]::IsNullOrWhiteSpace($env:SEED)) { 3407 }
        else { [int]$env:SEED }
    ),
    [int]$BatchSize = $(
        if ([string]::IsNullOrWhiteSpace($env:BATCH_SIZE)) { 64 }
        else { [int]$env:BATCH_SIZE }
    ),
    [int]$PretrainEpochs = $(
        if ([string]::IsNullOrWhiteSpace($env:PRETRAIN_EPOCHS)) { 25 }
        else { [int]$env:PRETRAIN_EPOCHS }
    ),
    [int]$FinetuneEpochs = $(
        if ([string]::IsNullOrWhiteSpace($env:FINETUNE_EPOCHS)) { 50 }
        else { [int]$env:FINETUNE_EPOCHS }
    ),
    [ValidateSet("target-sensitivity", "f1", "youden")]
    [string]$ThresholdMethod = "target-sensitivity",
    [double]$TargetSensitivity = 0.90
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Invoke-PythonStep {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$CommandArguments
    )

    & $PythonBin @CommandArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Python 단계가 종료 코드 $LASTEXITCODE 로 실패했습니다: $($CommandArguments -join ' ')"
    }
}

$scriptDirectory = $PSScriptRoot
Push-Location -LiteralPath $scriptDirectory
try {
    Invoke-PythonStep @(
        "data/amiodarone/preprocess.py",
        "--seed", $Seed.ToString()
    )

    Invoke-PythonStep @(
        "pretrain_amiodarone.py",
        "--device", $Device,
        "--seed", $Seed.ToString(),
        "--batch-size", $BatchSize.ToString(),
        "--epochs", $PretrainEpochs.ToString()
    )

    Invoke-PythonStep @(
        "train_amiodarone.py",
        "--task", "task1",
        "--device", $Device,
        "--seed", $Seed.ToString(),
        "--batch-size", $BatchSize.ToString(),
        "--epochs", $FinetuneEpochs.ToString(),
        "--require-pretrained",
        "--class-weights",
        "--threshold-method", $ThresholdMethod,
        "--target-sensitivity", $TargetSensitivity.ToString(
            [System.Globalization.CultureInfo]::InvariantCulture
        )
    )

    Invoke-PythonStep @(
        "train_amiodarone.py",
        "--task", "task2",
        "--device", $Device,
        "--seed", $Seed.ToString(),
        "--batch-size", $BatchSize.ToString(),
        "--epochs", $FinetuneEpochs.ToString(),
        "--require-pretrained",
        "--class-weights",
        "--threshold-method", $ThresholdMethod,
        "--target-sensitivity", $TargetSensitivity.ToString(
            [System.Globalization.CultureInfo]::InvariantCulture
        )
    )
}
finally {
    Pop-Location
}

Write-Host "Amiodarone SMART pipeline completed. Results: export/amiodarone/"
