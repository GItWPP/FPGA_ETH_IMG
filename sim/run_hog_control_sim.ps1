param([string]$VivadoBin='C:\Xilinx\Vivado\2024.2\bin',[string]$Python='python')
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
& $Python "$PSScriptRoot/generate_hog_vectors.py"
if($LASTEXITCODE -ne 0) { throw 'HOG vectors failed' }
& $Python "$PSScriptRoot/generate_hog_control_tb.py"
if($LASTEXITCODE -ne 0) { throw 'HOG test generation failed' }
Push-Location "$PSScriptRoot/build"
try {
    $rtl=@(Get-ChildItem -LiteralPath "$root/rtl" -Filter '*.v' | ForEach-Object { $_.FullName })
    & "$VivadoBin/xvlog.bat" @rtl "$PSScriptRoot/tb_hog_uart_ctrl.v" "$PSScriptRoot/tb_hog_math.v"
    if($LASTEXITCODE -ne 0) { throw 'Compile failed' }
    foreach($bench in @('tb_hog_math','tb_hog_uart_ctrl')) {
        & "$VivadoBin/xelab.bat" $bench -s $bench -debug typical
        if($LASTEXITCODE -ne 0) { throw 'Elaboration failed' }
        & "$VivadoBin/xsim.bat" $bench -runall -log "$bench.log"
        $result=Get-Content "$bench.log" -Raw
        if($LASTEXITCODE -ne 0 -or $result -match 'FAIL' -or $result -notmatch "PASS $bench") { throw "Simulation failed: $bench" }
    }
} finally { Pop-Location }
