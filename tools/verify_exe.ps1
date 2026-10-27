param([string]$HostIP='192.168.1.12', [int]$Port=1234)
$ErrorActionPreference='Stop'
$projectRoot=Split-Path -Parent $PSScriptRoot
$exePath=Join-Path $PSScriptRoot 'dist\ETH_Image_ZU4EV.exe'
$reportDir=Join-Path $PSScriptRoot 'board_results'
New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
$beforeHash=(Get-FileHash -LiteralPath $exePath -Algorithm SHA256).Hash.ToLowerInvariant()
$results=@()
foreach($testMode in @('band','hog','gamma','copy','video_copy','video_hog','video_sobel25')) {
    $testName=if($testMode -eq 'band') {'1.png'} elseif($testMode -eq 'copy') {'1920x1080_fpga_copy.png'} else {'test1.png'}
    $testImage=if($testMode -eq 'video_sobel25') { Join-Path $projectRoot 'test_video\test.mp4' } elseif($testMode.StartsWith('video_')) { Join-Path $projectRoot 'test_video\fpga_demo_25.mp4' } else { Join-Path $projectRoot "test_img\$testName" }
    $testReport=Join-Path $reportDir "exe_${testMode}.json"
    $arguments=@('--self-test','--host',$HostIP,'--port',"$Port",'--report',('"{0}"' -f $testReport),'--input',('"{0}"' -f $testImage),'--test-mode',$testMode)
    if($testMode -eq 'video_sobel25') { $arguments+=@('--snapshot',('"{0}"' -f (Join-Path $reportDir 'video_sobel25_workbench.png'))) }
    $testProcess=Start-Process -FilePath $exePath -ArgumentList $arguments -WindowStyle Hidden -PassThru -Wait
    if($testProcess.ExitCode -ne 0) { throw "Frozen GUI test failed: $testMode" }
    $report=Get-Content -Raw -LiteralPath $testReport | ConvertFrom-Json
    if($report.status -ne 'passed' -or -not $report.frozen) { throw "Invalid frozen GUI report: $testMode" }
    if($testMode -in @('copy','gamma') -and $report.transfer_metrics.window -ne 32) { throw "Window transfer not exercised: $testMode" }
    $results+=@{mode=$testMode; status=$report.status; frozen=$report.frozen; gui_status=$report.gui_status}
}
$afterHash=(Get-FileHash -LiteralPath $exePath -Algorithm SHA256).Hash.ToLowerInvariant()
if($afterHash -ne $beforeHash) { throw 'Executable changed during GUI verification' }
@{status='passed'; host=$HostIP; port=$Port; executable_sha256=$afterHash; bitstream_sha256=(Get-FileHash -LiteralPath (Join-Path $projectRoot 'project_eth\build\eth_img.bit') -Algorithm SHA256).Hash.ToLowerInvariant(); modes=$results} |
    ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $reportDir 'exe_acceptance.json') -Encoding utf8
Write-Output "PASS frozen Ethernet GUI: band, hog, gamma, full-HD copy, 25fps video copy/HOG and native 720p Sobel; SHA256=$afterHash"
