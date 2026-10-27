param([string]$Python='python')
$ErrorActionPreference='Stop'
& $Python -c 'import socket; from PIL import Image; import tkinter'
if($LASTEXITCODE -ne 0) { throw 'Install dependencies first: python -m pip install -r tools/requirements.txt' }
& $Python (Join-Path $PSScriptRoot 'eth_image_gui.py')
if($LASTEXITCODE -ne 0) { throw 'GUI exited with an error' }
