param([string]$VivadoBin='C:\Xilinx\Vivado\2024.2\bin', [string]$Python='python')
$ErrorActionPreference='Stop'
$simRoot=$PSScriptRoot
$projectRoot=Split-Path -Parent $simRoot
$buildDir=Join-Path $simRoot 'build'
New-Item -ItemType Directory -Path $buildDir -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $projectRoot 'rtl/hog_svm_weights.mem') -Destination $buildDir -Force
& $Python (Join-Path $simRoot 'generate_vectors.py')
if($LASTEXITCODE -ne 0) { throw 'Vector generation failed' }
& $Python (Join-Path $simRoot 'generate_hog_vectors.py')
if($LASTEXITCODE -ne 0) { throw 'HOG vector generation failed' }
& $Python (Join-Path $simRoot 'generate_hog_control_tb.py')
if($LASTEXITCODE -ne 0) { throw 'HOG control vector generation failed' }
& $Python (Join-Path $projectRoot 'tools/generate_band_vectors.py')
if($LASTEXITCODE -ne 0) { throw 'Band vector generation failed' }
Push-Location $buildDir
try {
    $rtl=@(Get-ChildItem -LiteralPath (Join-Path $projectRoot 'rtl') -Filter '*.v' | ForEach-Object { $_.FullName })
    $testbenches=@(Get-ChildItem -LiteralPath $simRoot -Filter 'tb_*.v' | Where-Object BaseName -NotLike 'tb_eth_*' | ForEach-Object { $_.FullName })
    & (Join-Path $VivadoBin 'xvlog.bat') -i $simRoot @rtl @testbenches
    if($LASTEXITCODE -ne 0) { throw 'Verilog compilation failed' }
    foreach($bench in @('tb_img_pixel_proc','tb_img_kernel','tb_uart_img_top','tb_img_ctrl_1080p','tb_hog_math','tb_hog_uart_ctrl','tb_hog_detect_top','tb_band_uart_ctrl','tb_band_decode_top')) {
        & (Join-Path $VivadoBin 'xelab.bat') $bench -s $bench -debug typical
        if($LASTEXITCODE -ne 0) { throw "Elaboration failed: $bench" }
        & (Join-Path $VivadoBin 'xsim.bat') $bench -runall -log "$bench.log"
        if($LASTEXITCODE -ne 0) { throw "Simulation failed: $bench" }
        $result=Get-Content -LiteralPath "$bench.log" -Raw
        if($result -match 'FAIL' -or $result -notmatch "PASS $bench") { throw "Self-check failed: $bench" }
    }
    Write-Output 'PASS all RTL simulations'
} finally { Pop-Location }
