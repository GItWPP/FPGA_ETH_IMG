//--------------------------------------------------------------------------------------------------------
// 模块： eth_udp_stack
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 独立GMII的MAC、IPv4、UDP及ARP协议栈结构连接
// 作者： WANG
// 时间： 26.10.22
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  eth_udp_stack
#(
    parameter LOCAL_MAC = 48'h02_55_49_4d_47_04,
    parameter LOCAL_IP = {8'd192,8'd168,8'd1,8'd12},
    parameter LOCAL_PORT = 16'd1234
)
(
    input   wire                   gmii_rx_clk            ,
    input   wire                   rx_rst_n               ,
    input   wire                   gmii_rx_dv             ,
    input   wire                   gmii_rx_er             ,
    input   wire           [7:0]   gmii_rxd               ,
    input   wire                   gmii_tx_clk            ,
    input   wire                   tx_rst_n               ,
    output  wire                   gmii_tx_en             ,
    output  wire                   gmii_tx_er             ,
    output  wire           [7:0]   gmii_txd               ,

    output  wire                   udp_rx_packet_start    ,
    output  wire           [47:0]  udp_rx_src_mac         ,
    output  wire           [31:0]  udp_rx_src_ip          ,
    output  wire           [15:0]  udp_rx_src_port        ,
    output  wire           [15:0]  udp_rx_payload_length  ,
    output  wire                   udp_rx_payload_valid   ,
    output  wire           [7:0]   udp_rx_payload_data    ,
    output  wire                   udp_rx_payload_last    ,
    output  wire                   udp_rx_packet_done     ,
    output  wire                   udp_rx_packet_error    ,

    input   wire           [47:0]  active_dst_mac         ,
    input   wire           [31:0]  active_dst_ip          ,
    input   wire           [15:0]  active_dst_port        ,
    input   wire                   app_udp_req_valid      ,
    output  wire                   app_udp_req_ready      ,
    input   wire           [15:0]  app_udp_payload_length ,
    input   wire           [31:0]  app_udp_payload_sum    ,
    input   wire                   app_udp_payload_valid  ,
    output  wire                   app_udp_payload_ready  ,
    input   wire           [7:0]   app_udp_payload_data   ,
    input   wire                   app_udp_payload_last   ,
    output  wire                   tx_busy                ,
    output  wire                   tx_done
);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
// Ethernet MAC RX stream
wire                   mac_rx_frame_start;
wire           [47:0]  mac_rx_dst_mac;
wire           [47:0]  mac_rx_src_mac;
wire           [15:0]  mac_rx_eth_type;
wire                   mac_rx_payload_valid;
wire           [7:0]   mac_rx_payload_data;
wire                   mac_rx_payload_last;
wire                   mac_rx_frame_done;
wire                   mac_rx_frame_error;

// UDP TX to transmit arbiter
wire                   udp_tx_frame_req_valid;
wire                   udp_tx_frame_req_ready;
wire           [47:0]  udp_tx_frame_dst_mac;
wire           [47:0]  udp_tx_frame_src_mac;
wire           [15:0]  udp_tx_frame_eth_type;
wire           [15:0]  udp_tx_frame_payload_length;
wire                   udp_tx_frame_payload_valid;
wire                   udp_tx_frame_payload_ready;
wire           [7:0]   udp_tx_frame_payload_data;
wire                   udp_tx_frame_payload_last;
wire                   udp_tx_busy;
wire                   udp_tx_done;

// ARP to transmit arbiter
wire                   arp_tx_frame_req_valid;
wire                   arp_tx_frame_req_ready;
wire           [47:0]  arp_tx_frame_dst_mac;
wire           [47:0]  arp_tx_frame_src_mac;
wire           [15:0]  arp_tx_frame_eth_type;
wire           [15:0]  arp_tx_frame_payload_length;
wire                   arp_tx_payload_valid;
wire                   arp_tx_payload_ready;
wire           [7:0]   arp_tx_payload_data;
wire                   arp_tx_payload_last;

// Arbiter to Ethernet MAC TX
wire                   mac_tx_frame_req_valid;
wire                   mac_tx_frame_req_ready;
wire           [47:0]  mac_tx_frame_dst_mac;
wire           [47:0]  mac_tx_frame_src_mac;
wire           [15:0]  mac_tx_frame_eth_type;
wire           [15:0]  mac_tx_frame_payload_length;
wire                   mac_tx_payload_valid;
wire                   mac_tx_payload_ready;
wire           [7:0]   mac_tx_payload_data;
wire                   mac_tx_payload_last;
wire                   mac_tx_busy;
wire                   mac_tx_done;

wire                   udp_rx_ip_checksum_ok;
wire                   udp_rx_checksum_ok;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
assign tx_busy = mac_tx_busy;
assign tx_done = mac_tx_done;

//********************************************************************//
//*************************** Instantiation **************************//
//********************************************************************//
eth_mac u_eth_mac
(
    .rx_clk                  (gmii_rx_clk),
    .rx_rst_n                (rx_rst_n),
    .gmii_rx_dv              (gmii_rx_dv),
    .gmii_rx_er              (gmii_rx_er),
    .gmii_rxd                (gmii_rxd),
    .rx_frame_start          (mac_rx_frame_start),
    .rx_frame_dst_mac        (mac_rx_dst_mac),
    .rx_frame_src_mac        (mac_rx_src_mac),
    .rx_frame_eth_type       (mac_rx_eth_type),
    .rx_payload_valid        (mac_rx_payload_valid),
    .rx_payload_data         (mac_rx_payload_data),
    .rx_payload_last         (mac_rx_payload_last),
    .rx_frame_done           (mac_rx_frame_done),
    .rx_frame_error          (mac_rx_frame_error),

    .tx_clk                  (gmii_tx_clk),
    .tx_rst_n                (tx_rst_n),
    .tx_frame_req_valid      (mac_tx_frame_req_valid),
    .tx_frame_req_ready      (mac_tx_frame_req_ready),
    .tx_frame_dst_mac        (mac_tx_frame_dst_mac),
    .tx_frame_src_mac        (mac_tx_frame_src_mac),
    .tx_frame_eth_type       (mac_tx_frame_eth_type),
    .tx_frame_payload_length (mac_tx_frame_payload_length),
    .tx_payload_valid        (mac_tx_payload_valid),
    .tx_payload_ready        (mac_tx_payload_ready),
    .tx_payload_data         (mac_tx_payload_data),
    .tx_payload_last         (mac_tx_payload_last),
    .tx_busy                 (mac_tx_busy),
    .tx_done                 (mac_tx_done),
    .gmii_tx_en              (gmii_tx_en),
    .gmii_tx_er              (gmii_tx_er),
    .gmii_txd                (gmii_txd)
);

eth_udp_rx u_eth_udp_rx
(
    .rx_clk                (gmii_rx_clk),
    .rx_rst_n              (rx_rst_n),
    .local_mac             (LOCAL_MAC),
    .local_ip              (LOCAL_IP),
    .local_port            (LOCAL_PORT),
    .frame_start           (mac_rx_frame_start),
    .frame_dst_mac         (mac_rx_dst_mac),
    .frame_src_mac         (mac_rx_src_mac),
    .frame_eth_type        (mac_rx_eth_type),
    .frame_payload_valid   (mac_rx_payload_valid),
    .frame_payload_data    (mac_rx_payload_data),
    .frame_payload_last    (mac_rx_payload_last),
    .frame_done            (mac_rx_frame_done),
    .frame_error           (mac_rx_frame_error),
    .udp_packet_start      (udp_rx_packet_start),
    .udp_src_mac           (udp_rx_src_mac),
    .udp_src_ip            (udp_rx_src_ip),
    .udp_src_port          (udp_rx_src_port),
    .udp_payload_length    (udp_rx_payload_length),
    .udp_payload_valid     (udp_rx_payload_valid),
    .udp_payload_data      (udp_rx_payload_data),
    .udp_payload_last      (udp_rx_payload_last),
    .udp_packet_done       (udp_rx_packet_done),
    .udp_packet_error      (udp_rx_packet_error),
    .ip_checksum_ok        (udp_rx_ip_checksum_ok),
    .udp_checksum_ok       (udp_rx_checksum_ok)
);

eth_udp_tx u_eth_udp_tx
(
    .tx_clk               (gmii_tx_clk),
    .tx_rst_n             (tx_rst_n),
    .local_mac            (LOCAL_MAC),
    .local_ip             (LOCAL_IP),
    .local_port           (LOCAL_PORT),
    .dst_mac              (active_dst_mac),
    .dst_ip               (active_dst_ip),
    .dst_port             (active_dst_port),
    .udp_req_valid        (app_udp_req_valid),
    .udp_req_ready        (app_udp_req_ready),
    .udp_payload_length   (app_udp_payload_length),
    .udp_payload_sum      (app_udp_payload_sum),
    .udp_payload_valid    (app_udp_payload_valid),
    .udp_payload_ready    (app_udp_payload_ready),
    .udp_payload_data     (app_udp_payload_data),
    .udp_payload_last     (app_udp_payload_last),
    .frame_req_valid      (udp_tx_frame_req_valid),
    .frame_req_ready      (udp_tx_frame_req_ready),
    .frame_dst_mac        (udp_tx_frame_dst_mac),
    .frame_src_mac        (udp_tx_frame_src_mac),
    .frame_eth_type       (udp_tx_frame_eth_type),
    .frame_payload_length (udp_tx_frame_payload_length),
    .frame_payload_valid  (udp_tx_frame_payload_valid),
    .frame_payload_ready  (udp_tx_frame_payload_ready),
    .frame_payload_data   (udp_tx_frame_payload_data),
    .frame_payload_last   (udp_tx_frame_payload_last),
    .tx_busy              (udp_tx_busy),
    .tx_done              (udp_tx_done)
);

eth_arp u_eth_arp
(
    .rx_clk                  (gmii_rx_clk),
    .rx_rst_n                (rx_rst_n),
    .tx_clk                  (gmii_tx_clk),
    .tx_rst_n                (tx_rst_n),
    .local_mac               (LOCAL_MAC),
    .local_ip                (LOCAL_IP),
    .frame_start             (mac_rx_frame_start),
    .frame_dst_mac           (mac_rx_dst_mac),
    .frame_src_mac           (mac_rx_src_mac),
    .frame_eth_type          (mac_rx_eth_type),
    .frame_payload_valid     (mac_rx_payload_valid),
    .frame_payload_data      (mac_rx_payload_data),
    .frame_payload_last      (mac_rx_payload_last),
    .frame_done              (mac_rx_frame_done),
    .frame_error             (mac_rx_frame_error),
    .resolve_req             (1'b0),
    .resolve_ip              (active_dst_ip),
    .resolve_done            (),
    .resolve_failed          (),
    .resolved_mac            (),
    .peer_learn_valid        (),
    .peer_learn_mac          (),
    .peer_learn_ip           (),
    .tx_frame_req_valid      (arp_tx_frame_req_valid),
    .tx_frame_req_ready      (arp_tx_frame_req_ready),
    .tx_frame_dst_mac        (arp_tx_frame_dst_mac),
    .tx_frame_src_mac        (arp_tx_frame_src_mac),
    .tx_frame_eth_type       (arp_tx_frame_eth_type),
    .tx_frame_payload_length (arp_tx_frame_payload_length),
    .tx_payload_valid        (arp_tx_payload_valid),
    .tx_payload_ready        (arp_tx_payload_ready),
    .tx_payload_data         (arp_tx_payload_data),
    .tx_payload_last         (arp_tx_payload_last)
);

eth_tx_arbiter u_eth_tx_arbiter
(
    .clk                (gmii_tx_clk),
    .rst_n              (tx_rst_n),
    .arp_req_valid      (arp_tx_frame_req_valid),
    .arp_req_ready      (arp_tx_frame_req_ready),
    .arp_dst_mac        (arp_tx_frame_dst_mac),
    .arp_src_mac        (arp_tx_frame_src_mac),
    .arp_eth_type       (arp_tx_frame_eth_type),
    .arp_payload_length (arp_tx_frame_payload_length),
    .arp_payload_valid  (arp_tx_payload_valid),
    .arp_payload_ready  (arp_tx_payload_ready),
    .arp_payload_data   (arp_tx_payload_data),
    .arp_payload_last   (arp_tx_payload_last),
    .udp_req_valid      (udp_tx_frame_req_valid),
    .udp_req_ready      (udp_tx_frame_req_ready),
    .udp_dst_mac        (udp_tx_frame_dst_mac),
    .udp_src_mac        (udp_tx_frame_src_mac),
    .udp_eth_type       (udp_tx_frame_eth_type),
    .udp_payload_length (udp_tx_frame_payload_length),
    .udp_payload_valid  (udp_tx_frame_payload_valid),
    .udp_payload_ready  (udp_tx_frame_payload_ready),
    .udp_payload_data   (udp_tx_frame_payload_data),
    .udp_payload_last   (udp_tx_frame_payload_last),
    .mac_req_valid      (mac_tx_frame_req_valid),
    .mac_req_ready      (mac_tx_frame_req_ready),
    .mac_dst_mac        (mac_tx_frame_dst_mac),
    .mac_src_mac        (mac_tx_frame_src_mac),
    .mac_eth_type       (mac_tx_frame_eth_type),
    .mac_payload_length (mac_tx_frame_payload_length),
    .mac_payload_valid  (mac_tx_payload_valid),
    .mac_payload_ready  (mac_tx_payload_ready),
    .mac_payload_data   (mac_tx_payload_data),
    .mac_payload_last   (mac_tx_payload_last)
);


endmodule
