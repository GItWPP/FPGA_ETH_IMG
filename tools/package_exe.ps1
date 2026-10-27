param([string]$Python='python', [string]$Name='ETH_Image_ZU4EV')
$ErrorActionPreference='Stop'
$venvDir=Join-Path $PSScriptRoot '.packaging_venv'
$packPython=Join-Path $venvDir 'Scripts\python.exe'
if(-not (Test-Path -LiteralPath $packPython)) {
    & $Python -m venv $venvDir
    if($LASTEXITCODE -ne 0) { throw 'Cannot create packaging environment' }
}
& $packPython -m pip install -r (Join-Path $PSScriptRoot 'requirements-packaging.txt')
if($LASTEXITCODE -ne 0) { throw 'Cannot install packaging dependencies' }
if(-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'native\stream_udp.dll'))) {
    & (Join-Path $PSScriptRoot 'native\build.ps1')
}
$packDir=Join-Path $PSScriptRoot 'packaging'
$distDir=Join-Path $PSScriptRoot 'dist'
New-Item -ItemType Directory -Path $packDir,$distDir -Force | Out-Null
& $packPython -m PyInstaller --noconfirm --clean --onefile --windowed --noupx --name $Name --distpath $distDir --workpath (Join-Path $packDir 'build') --specpath $packDir --paths $PSScriptRoot --add-binary ((Join-Path $PSScriptRoot 'native\stream_udp.dll')+';.') --hidden-import eth_gui_selftest --hidden-import video_gui_selftest (Join-Path $PSScriptRoot 'eth_image_gui.py')
if($LASTEXITCODE -ne 0) { throw 'EXE packaging failed' }
$exePath=Join-Path $distDir "$Name.exe"
Get-FileHash -LiteralPath $exePath -Algorithm SHA256 | Format-List
Write-Output "PASS executable: $exePath"
