param([string]$VivadoBin='C:\Xilinx\Vivado\2024.2\bin', [string]$Python='python', [ValidateSet(50,125)][int]$AlgorithmMHz=125)
$ErrorActionPreference='Stop'
& (Join-Path $PSScriptRoot 'run_sim.ps1') -VivadoBin $VivadoBin -Python $Python
foreach($bench in @('tb_eth_packet_mailbox','tb_eth_rgmii_if','tb_eth_image_core','tb_eth_packet_queue','tb_eth_packet_tx_fast','tb_eth_window','tb_eth_pipeline','tb_img_byte_uram','tb_img_async_command','tb_sobel_stream_kernel','tb_sobel_stream_protocol')) {
    & (Join-Path $PSScriptRoot 'run_eth_sim.ps1') -VivadoBin $VivadoBin -Python $Python -Top $bench -AlgorithmMHz $AlgorithmMHz
}
Write-Output 'PASS all twenty RTL self-checks'
