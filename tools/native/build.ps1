param([string]$Compiler='gcc')
$ErrorActionPreference='Stop'
& $Compiler -std=c11 -O3 -shared -Wall -Wextra -Werror -static-libgcc -s -o (Join-Path $PSScriptRoot 'stream_udp.dll') (Join-Path $PSScriptRoot 'stream_udp.c') -lws2_32
if($LASTEXITCODE -ne 0) { throw 'Native UDP transport compilation failed' }
Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'stream_udp.dll') -Algorithm SHA256

$sourceDigest=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'stream_udp.c') -Algorithm SHA256).Hash.ToLowerInvariant()
$dllDigest=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'stream_udp.dll') -Algorithm SHA256).Hash.ToLowerInvariant()
@{status='built'; compiler=(& $Compiler --version | Select-Object -First 1); source_sha256=$sourceDigest; dll_sha256=$dllDigest; flags='-std=c11 -O3 -shared -Wall -Wextra -Werror -static-libgcc -s -lws2_32'} |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'build_manifest.json') -Encoding utf8
