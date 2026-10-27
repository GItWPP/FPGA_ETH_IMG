param([string]$VivadoBin='C:\Xilinx\Vivado\2024.2\bin',[string]$Python='python')
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
& $Python "$PSScriptRoot/generate_hog_vectors.py"
if($LASTEXITCODE -ne 0) { throw 'HOG vectors failed' }
$build=Join-Path $PSScriptRoot 'build'
New-Item -ItemType Directory -Path $build -Force | Out-Null
Copy-Item -LiteralPath "$root/rtl/hog_svm_weights.mem" -Destination $build -Force
Push-Location $build
try {
    $rtl=@(Get-ChildItem -LiteralPath "$root/rtl" -Filter '*.v' | ForEach-Object { $_.FullName })
    & "$VivadoBin/xvlog.bat" @rtl "$PSScriptRoot/tb_hog_detect_top.v"
    if($LASTEXITCODE -ne 0) { throw 'Compile failed' }
    & "$VivadoBin/xelab.bat" tb_hog_detect_top -s tb_hog_detect_top -debug typical
    if($LASTEXITCODE -ne 0) { throw 'Elaboration failed' }
    & "$VivadoBin/xsim.bat" tb_hog_detect_top -runall -log tb_hog_detect_top.log
    $result=Get-Content tb_hog_detect_top.log -Raw
    if($LASTEXITCODE -ne 0 -or $result -match 'FAIL' -or $result -notmatch 'PASS tb_hog_detect_top') { throw 'HOG simulation failed' }
} finally { Pop-Location }
