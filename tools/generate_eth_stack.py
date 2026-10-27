"""Create the structural protocol wrapper from the verified ADC_ETH connections."""
from pathlib import Path
import argparse
from import_ethernet_reference import HEADER, SIGNAL, MAIN, INST
from format_hdl_layout import format_source


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('reference_root',type=Path)
    args=parser.parse_args()
    root=Path(__file__).resolve().parents[1]
    target=root/'rtl/ethernet/eth_udp_stack.v'
    if target.exists():
        raise FileExistsError(target)
    source=(args.reference_root/'rtl/net/eth_udp_core.v').read_text(encoding='utf-8')
    declarations=source[source.index('// Ethernet MAC RX stream'):source.index('// UDP RX application stream')]
    declarations+=source[source.index('// UDP TX to transmit arbiter'):source.index('// Most recently validated UDP peer')]
    instances=source[source.index('eth_mac u_eth_mac'):source.index('adc_cmd_decoder u_adc_cmd_decoder')]
    instances+=source[source.index('eth_udp_tx u_eth_udp_tx'):source.index('// Reserved status signals')]
    body='''`timescale  1ns/1ns

module  eth_udp_stack
#(
    parameter LOCAL_MAC = 48'h02_55_49_4d_47_04,
    parameter LOCAL_IP = {8'd192,8'd168,8'd1,8'd12},
    parameter LOCAL_PORT = 16'd1234
)
(
    input wire gmii_rx_clk,
    input wire rx_rst_n,
    input wire gmii_rx_dv,
    input wire gmii_rx_er,
    input wire [7:0] gmii_rxd,
    input wire gmii_tx_clk,
    input wire tx_rst_n,
    output wire gmii_tx_en,
    output wire gmii_tx_er,
    output wire [7:0] gmii_txd,

    output wire udp_rx_packet_start,
    output wire [47:0] udp_rx_src_mac,
    output wire [31:0] udp_rx_src_ip,
    output wire [15:0] udp_rx_src_port,
    output wire [15:0] udp_rx_payload_length,
    output wire udp_rx_payload_valid,
    output wire [7:0] udp_rx_payload_data,
    output wire udp_rx_payload_last,
    output wire udp_rx_packet_done,
    output wire udp_rx_packet_error,

    input wire [47:0] active_dst_mac,
    input wire [31:0] active_dst_ip,
    input wire [15:0] active_dst_port,
    input wire app_udp_req_valid,
    output wire app_udp_req_ready,
    input wire [15:0] app_udp_payload_length,
    input wire [31:0] app_udp_payload_sum,
    input wire app_udp_payload_valid,
    output wire app_udp_payload_ready,
    input wire [7:0] app_udp_payload_data,
    input wire app_udp_payload_last,
    output wire tx_busy,
    output wire tx_done
);
'''
    declarations+='wire udp_rx_ip_checksum_ok;\nwire udp_rx_checksum_ok;\n'
    main='assign tx_busy = mac_tx_busy;\nassign tx_done = mac_tx_done;\n'
    body=HEADER.format(name='eth_udp_stack',purpose='独立GMII的MAC、IPv4、UDP及ARP协议栈结构连接')+body
    body+='\n'+SIGNAL+declarations+'\n'+MAIN+main+'\n'+INST+instances+'\nendmodule\n'
    target.write_text(format_source(body),encoding='utf-8')
    # Restore correct attribute/declaration association in imported layers.
    from import_ethernet_reference import styled
    for path in (root/'rtl/ethernet').glob('*.v'):
        original=list((args.reference_root/'rtl').rglob(path.name))
        if len(original)==1:
            text=path.read_text(encoding='utf-8')
            purpose=next(line.split('：',1)[1].strip() for line in text.splitlines() if line.startswith('// 功能'))
            path.write_text(styled(original[0].read_text(encoding='utf-8'),path.stem,purpose),encoding='utf-8')
    print('PASS Ethernet stack structural wrapper generated')


if __name__=='__main__':
    main()
