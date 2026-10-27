# Implementation-only constraints for explicitly bundled, acknowledged CDC.
# The three-stage event synchronizers are constrained only at their first D pin.
set_false_path -to [get_pins -hierarchical -regexp {.*(request_sync_reg|acknowledge_sync_reg|reply_toggle_sync_reg|peer_toggle_sync_reg)\[0\]/D}]

# Packet queues use Gray-coded commit/release pointers. Bound the complete
# source-to-first-stage path and bus skew; later stages use normal timing.
set rx_wr_source [get_cells -hierarchical -filter {NAME =~ eth_image_core_inst/eth_image_rx_inst/rx_mailbox_inst/wr_gray_reg*}]
set rx_wr_target [get_cells -hierarchical -filter {NAME =~ eth_image_core_inst/eth_image_rx_inst/rx_mailbox_inst/wr_gray_sync1_reg*}]
set_max_delay -datapath_only 8.000 -from $rx_wr_source -to $rx_wr_target
set_false_path -hold -from $rx_wr_source -to $rx_wr_target
set_bus_skew 4.000 -from $rx_wr_source -to $rx_wr_target

set rx_rd_source [get_cells -hierarchical -filter {NAME =~ eth_image_core_inst/eth_image_rx_inst/rx_mailbox_inst/rd_gray_reg*}]
set rx_rd_target [get_cells -hierarchical -filter {NAME =~ eth_image_core_inst/eth_image_rx_inst/rx_mailbox_inst/rd_gray_sync1_reg*}]
set_max_delay -datapath_only 8.000 -from $rx_rd_source -to $rx_rd_target
set_false_path -hold -from $rx_rd_source -to $rx_rd_target
set_bus_skew 4.000 -from $rx_rd_source -to $rx_rd_target

set tx_wr_source [get_cells -hierarchical -filter {NAME =~ eth_image_core_inst/tx_mailbox_inst/wr_gray_reg*}]
set tx_wr_target [get_cells -hierarchical -filter {NAME =~ eth_image_core_inst/tx_mailbox_inst/wr_gray_sync1_reg*}]
set_max_delay -datapath_only 8.000 -from $tx_wr_source -to $tx_wr_target
set_false_path -hold -from $tx_wr_source -to $tx_wr_target
set_bus_skew 4.000 -from $tx_wr_source -to $tx_wr_target

set tx_rd_source [get_cells -hierarchical -filter {NAME =~ eth_image_core_inst/tx_mailbox_inst/rd_gray_reg*}]
set tx_rd_target [get_cells -hierarchical -filter {NAME =~ eth_image_core_inst/tx_mailbox_inst/rd_gray_sync1_reg*}]
set_max_delay -datapath_only 8.000 -from $tx_rd_source -to $tx_rd_target
set_false_path -hold -from $tx_rd_source -to $tx_rd_target
set_bus_skew 4.000 -from $tx_rd_source -to $tx_rd_target

# ARP metadata follows its toggle event. With gigabit full-duplex framing,
# consecutive receive events are at least one complete Ethernet frame apart.
set arp_source [get_cells -hierarchical -filter {NAME =~ */u_eth_arp/reply_mac_hold_reg* || NAME =~ */u_eth_arp/reply_ip_hold_reg* || NAME =~ */u_eth_arp/peer_learn_mac_reg* || NAME =~ */u_eth_arp/peer_learn_ip_reg*}]
set arp_target [get_cells -hierarchical -filter {NAME =~ */u_eth_arp/tx_target_mac_reg* || NAME =~ */u_eth_arp/tx_target_ip_reg* || NAME =~ */u_eth_arp/cache_mac_reg* || NAME =~ */u_eth_arp/cache_ip_reg* || NAME =~ */u_eth_arp/resolved_mac_reg*}]
set_max_delay -datapath_only 8.000 -from $arp_source -to $arp_target
set_false_path -hold -from $arp_source -to $arp_target
