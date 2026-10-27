param(
    [string]$VivadoBin='C:\Xilinx\Vivado\2024.2\bin',
    [ValidateSet(50,125)][int]$AlgorithmMHz=125,
    [string]$OutputDirectory=''
)
$ErrorActionPreference='Stop'
$projectRoot=Split-Path -Parent $PSScriptRoot
$profileDirectory=if($AlgorithmMHz -eq 50) {'project_eth\build_50mhz'} else {'project_eth\build'}
$outDir=if($OutputDirectory) {[System.IO.Path]::GetFullPath($OutputDirectory)} else {Join-Path $projectRoot $profileDirectory}
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
Push-Location $outDir
try {
    & (Join-Path $VivadoBin 'vivado.bat') -mode batch -source (Join-Path $PSScriptRoot 'setup_project.tcl') -log setup.log -journal setup.jou -tclargs $AlgorithmMHz
    if($LASTEXITCODE -ne 0) { throw 'Vivado project/IP setup failed' }
    & (Join-Path $VivadoBin 'vivado.bat') -mode batch -source (Join-Path $PSScriptRoot 'build_vivado.tcl') -log build.log -journal build.jou -tclargs $outDir
    if($LASTEXITCODE -ne 0) { throw 'Vivado build failed; inspect project_eth/build/build.log' }
    Copy-Item -LiteralPath (Join-Path $projectRoot 'project_eth\ip\clk_wiz_eth\clk_wiz_eth.xci') -Destination (Join-Path $outDir "clk_wiz_eth_${AlgorithmMHz}mhz.xci") -Force
} finally { Pop-Location }
