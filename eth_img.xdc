# ZU4EV / xczu4ev-sfvc784-2-i; pins copied from ADC_ETH/eth_udp/project_1/eth.xdc.
create_clock -name eth_rxc -period 8.000 -waveform {0.000 4.000} [get_ports eth_rxc]

set_property PACKAGE_PIN AA13 [get_ports sys_rst_n]
set_property IOSTANDARD LVCMOS33 [get_ports sys_rst_n]
set_property PACKAGE_PIN AC14 [get_ports {led_ctrl[0]}]
set_property PACKAGE_PIN AD14 [get_ports {led_ctrl[1]}]
set_property PACKAGE_PIN AD15 [get_ports {led_ctrl[2]}]
set_property PACKAGE_PIN AF13 [get_ports {led_ctrl[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led_ctrl[*]}]

set_property PACKAGE_PIN K3 [get_ports eth_rst_n]
set_property PACKAGE_PIN E8 [get_ports eth_rx_ctl]
set_property PACKAGE_PIN C2 [get_ports eth_tx_ctl]
set_property PACKAGE_PIN C3 [get_ports eth_rxc]
set_property PACKAGE_PIN B4 [get_ports eth_txc]
set_property PACKAGE_PIN G5 [get_ports {eth_rxd[0]}]
set_property PACKAGE_PIN G3 [get_ports {eth_rxd[1]}]
set_property PACKAGE_PIN F3 [get_ports {eth_rxd[2]}]
set_property PACKAGE_PIN F5 [get_ports {eth_rxd[3]}]
set_property PACKAGE_PIN A4 [get_ports {eth_txd[0]}]
set_property PACKAGE_PIN D9 [get_ports {eth_txd[1]}]
set_property PACKAGE_PIN F8 [get_ports {eth_txd[2]}]
set_property PACKAGE_PIN E9 [get_ports {eth_txd[3]}]
set_property IOSTANDARD LVCMOS18 [get_ports {eth_rst_n eth_rx_ctl eth_tx_ctl eth_rxc eth_txc eth_rxd[*] eth_txd[*]}]

# External reset is asynchronous. Each logic domain synchronizes release.
set_false_path -from [get_ports sys_rst_n]

# RGMII RXDLY/TXDLY strap assumptions match the reference board. The reference
# has no verified board-level input/output delay numbers. These ports remain
# explicitly unsigned-off until PHY and PCB skew are supplied; do not invent
# delays or suppress missing I/O-delay warnings to claim full timing closure.
