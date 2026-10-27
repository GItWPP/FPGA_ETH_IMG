param(
    [string]$VivadoBin='C:\Xilinx\Vivado\2024.2\bin',
    [string]$Top='tb_eth_packet_mailbox',
    [string]$Python='python',
    [string]$BuildFolder='build_eth',
    [ValidateSet(50,125)][int]$AlgorithmMHz=125
)
$ErrorActionPreference='Stop'
$projectRoot=Split-Path -Parent $PSScriptRoot
$outDir=Join-Path $PSScriptRoot $BuildFolder
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $projectRoot 'rtl\hog_svm_weights.mem') -Destination $outDir -Force
$sources=@(Get-ChildItem -LiteralPath (Join-Path $projectRoot 'rtl') -Filter '*.v' -Recurse | ForEach-Object FullName)
$sources+=Join-Path $PSScriptRoot "$Top.v"
$simulationRoots=@("xil_defaultlib.$Top")
$genericArgs=@()
if($Top -in @('tb_eth_image_core','tb_eth_window','tb_eth_pipeline')) {
    $halfPeriod=if($AlgorithmMHz -eq 125) {4} else {10}
    # Preserve '=' as part of one argument through the vendor .bat launcher.
    $genericArgs=@('--generic_top',('"ALGO_HALF_PERIOD={0}"' -f $halfPeriod))
}
# XPM asynchronous FIFO synchronizers also use the vendor global reset model.
$sources+=Join-Path (Split-Path -Parent $VivadoBin) 'data\verilog\src\glbl.v'
    $simulationRoots+='xil_defaultlib.glbl'
if($Top -eq 'tb_sobel_stream_protocol') {
    & $Python (Join-Path $PSScriptRoot 'generate_stream_vectors.py')
    if($LASTEXITCODE -ne 0) { throw 'Stream vector generation failed' }
}
if($Top -eq 'tb_eth_image_core') {
    & $Python (Join-Path $PSScriptRoot 'generate_eth_vectors.py')
    if($LASTEXITCODE -ne 0) { throw 'Ethernet vector generation failed' }
}
if($Top -eq 'tb_eth_window' -or $Top -eq 'tb_eth_pipeline' -or $Top -eq 'tb_eth_packet_tx_fast') {
    & $Python (Join-Path $PSScriptRoot 'generate_window_vectors.py')
    if($LASTEXITCODE -ne 0) { throw 'Window vector generation failed' }
}
Push-Location $outDir
try {
    & (Join-Path $VivadoBin 'xvlog.bat') --work xil_defaultlib -i $PSScriptRoot @sources
    if($LASTEXITCODE -ne 0) { throw 'Ethernet HDL compilation failed' }
    & (Join-Path $VivadoBin 'xelab.bat') --debug typical --relax -L xpm -L unisims_ver @simulationRoots @genericArgs -s "${Top}_sim"
    if($LASTEXITCODE -ne 0) { throw 'Ethernet HDL elaboration failed' }
    & (Join-Path $VivadoBin 'xsim.bat') "${Top}_sim" -runall -log "$Top.log"
    if($LASTEXITCODE -ne 0) { throw 'Ethernet simulation failed' }
    if(-not (Select-String -LiteralPath "$Top.log" -Pattern "PASS $Top" -Quiet)) { throw 'No PASS marker' }
} finally { Pop-Location }
