//--------------------------------------------------------------------------------------------------------
// 模块： eth_mac
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： MAC接收与发送子模块结构连接，复用ADC_ETH协议层
// 作者： WANG
// 时间： 26.10.22
//--------------------------------------------------------------------------------------------------------
`timescale 1ns/1ps

// Full-duplex Ethernet MAC structural wrapper.
module  eth_mac
(
    input   wire                   rx_clk                 ,
    input   wire                   rx_rst_n               ,
    input   wire                   gmii_rx_dv             ,
    input   wire                   gmii_rx_er             ,
    input   wire           [7:0]   gmii_rxd               ,

    output  wire                   rx_frame_start         ,
    output  wire           [47:0]  rx_frame_dst_mac       ,
    output  wire           [47:0]  rx_frame_src_mac       ,
    output  wire           [15:0]  rx_frame_eth_type      ,
    output  wire                   rx_payload_valid       ,
    output  wire           [7:0]   rx_payload_data        ,
    output  wire                   rx_payload_last        ,
    output  wire                   rx_frame_done          ,
    output  wire                   rx_frame_error         ,

    input   wire                   tx_clk                 ,
    input   wire                   tx_rst_n               ,
    input   wire                   tx_frame_req_valid     ,
    output  wire                   tx_frame_req_ready     ,
    input   wire           [47:0]  tx_frame_dst_mac       ,
    input   wire           [47:0]  tx_frame_src_mac       ,
    input   wire           [15:0]  tx_frame_eth_type      ,
    input   wire           [15:0]  tx_frame_payload_length,
    input   wire                   tx_payload_valid       ,
    output  wire                   tx_payload_ready       ,
    input   wire           [7:0]   tx_payload_data        ,
    input   wire                   tx_payload_last        ,
    output  wire                   tx_busy                ,
    output  wire                   tx_done                ,
    output  wire                   gmii_tx_en             ,
    output  wire                   gmii_tx_er             ,
    output  wire           [7:0]   gmii_txd
);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//

//wire/reg define



//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
//********************************************************************//
//*************************** Instantiation **************************//
//********************************************************************//
eth_mac_rx u_eth_mac_rx
(
    .rx_clk          (rx_clk),
    .rx_rst_n        (rx_rst_n),
    .gmii_rx_dv      (gmii_rx_dv),
    .gmii_rx_er      (gmii_rx_er),
    .gmii_rxd        (gmii_rxd),
    .frame_start     (rx_frame_start),
    .frame_dst_mac   (rx_frame_dst_mac),
    .frame_src_mac   (rx_frame_src_mac),
    .frame_eth_type  (rx_frame_eth_type),
    .payload_valid   (rx_payload_valid),
    .payload_data    (rx_payload_data),
    .payload_last    (rx_payload_last),
    .frame_done      (rx_frame_done),
    .frame_error     (rx_frame_error)
);

eth_mac_tx u_eth_mac_tx
(
    .tx_clk               (tx_clk),
    .tx_rst_n             (tx_rst_n),
    .frame_req_valid      (tx_frame_req_valid),
    .frame_req_ready      (tx_frame_req_ready),
    .frame_dst_mac        (tx_frame_dst_mac),
    .frame_src_mac        (tx_frame_src_mac),
    .frame_eth_type       (tx_frame_eth_type),
    .frame_payload_length (tx_frame_payload_length),
    .payload_valid        (tx_payload_valid),
    .payload_ready        (tx_payload_ready),
    .payload_data         (tx_payload_data),
    .payload_last         (tx_payload_last),
    .tx_busy              (tx_busy),
    .tx_done              (tx_done),
    .gmii_tx_en           (gmii_tx_en),
    .gmii_tx_er           (gmii_tx_er),
    .gmii_txd             (gmii_txd)
);

endmodule
