create_clock -name sys_clk -period 20.000 [get_ports sys_clk]
set_property PACKAGE_PIN U18 [get_ports {sys_clk}]
set_property IOSTANDARD LVCMOS33 [get_ports sys_clk]
set_property PACKAGE_PIN M15 [get_ports {sys_rst_n}]
set_property IOSTANDARD LVCMOS33 [get_ports sys_rst_n]

set_property PACKAGE_PIN T10 [get_ports uart_tx_o]
set_property IOSTANDARD LVCMOS33 [get_ports uart_tx_o]
set_property PACKAGE_PIN T11 [get_ports uart_rx_i]
set_property IOSTANDARD LVCMOS33 [get_ports uart_rx_i]

# Asynchronous external interfaces. Internal 50 MHz paths remain timed.
# RX enters uart_rx_inst's two-stage ASYNC_REG synchronizer.
set_false_path -from [get_ports uart_rx_i]
# External active-low reset is released through rst_sync in uart_img_top.
set_false_path -from [get_ports sys_rst_n]
# UART TX is sampled against its start bit by the external receiver.
set_false_path -to [get_ports uart_tx_o]
