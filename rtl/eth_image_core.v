//--------------------------------------------------------------------------------------------------------
// 模块： eth_image_core
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 千兆GMII协议、双向整包跨域缓存及原有图像算法结构连接
// 作者： WANG
// 时间： 26.10.22
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  eth_image_core
#(
    parameter LOCAL_MAC = 48'h02_55_49_4d_47_04,
    parameter LOCAL_IP = {8'd192,8'd168,8'd1,8'd12},
    parameter LOCAL_PORT = 16'd1234,
    parameter integer ASYNC_ALGORITHMS = 0
)
(
    input   wire                   sys_rst_n              ,
    input   wire                   gmii_rx_clk            ,
    input   wire                   gmii_rx_dv             ,
    input   wire                   gmii_rx_er             ,
    input   wire           [7:0]   gmii_rxd               ,
    input   wire                   gmii_tx_clk            ,
    output  wire                   gmii_tx_en             ,
    output  wire                   gmii_tx_er             ,
    output  wire           [7:0]   gmii_txd               ,
    input   wire                   app_clk                ,
    input   wire                   algo_clk               ,
    output  wire                   rx_packet_done         ,
    output  wire                   rx_packet_error        ,
    output  wire                   rx_drop_flag           ,
    output  wire                   tx_packet_done         ,
    output  wire                   tx_busy
);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//wire  define
wire                   rx_rst_n;
wire                   tx_rst_n;
wire                   app_rst_n;
wire                   udp_rx_start;
wire           [47:0]  udp_rx_mac;
wire           [31:0]  udp_rx_ip;
wire           [15:0]  udp_rx_port;
wire           [15:0]  udp_rx_length;
wire                   udp_rx_valid;
wire           [7:0]   udp_rx_data;
wire                   udp_rx_last;
wire                   app_packet_valid;
wire                   app_packet_ready;
wire           [95:0]  app_peer;
wire           [95:0]  app_tx_peer;
wire                   app_rx_valid;
wire                   app_rx_ready;
wire           [7:0]   app_rx_data;
wire                   app_tx_valid;
wire                   app_tx_ready;
wire           [7:0]   app_tx_data;
wire                   app_tx_start;
wire                   app_tx_start_ready;
wire           [15:0]  app_tx_length;
wire                   app_tx_done;
wire                   udp_tx_req;
wire                   udp_tx_ready;
wire           [95:0]  udp_tx_peer;
wire           [15:0]  udp_tx_length;
wire           [31:0]  udp_tx_sum;
wire                   udp_tx_valid;
wire                   udp_tx_byte_ready;
wire           [7:0]   udp_tx_data;
wire                   udp_tx_last;

//reg   define
reg            [95:0]  active_peer;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
assign app_packet_ready = app_rx_ready;

//请求的返回地址按包锁存，不使用可能被后续帧更新的全局最近端点
always@(posedge app_clk or negedge app_rst_n)
    if(app_rst_n == 1'b0)
        active_peer <= 96'd0;
    else if(app_packet_valid && app_packet_ready)
        active_peer <= app_peer;

//********************************************************************//
//*************************** Instantiation **************************//
//********************************************************************//
eth_reset_sync rx_reset_inst
(
    .sys_clk                (gmii_rx_clk                                     ),
    .async_rst_n            (sys_rst_n                                       ),
    .rst_n                  (rx_rst_n                                        )
);

eth_reset_sync tx_reset_inst
(
    .sys_clk                (gmii_tx_clk                                     ),
    .async_rst_n            (sys_rst_n                                       ),
    .rst_n                  (tx_rst_n                                        )
);

eth_reset_sync app_reset_inst
(
    .sys_clk                (app_clk                                         ),
    .async_rst_n            (sys_rst_n                                       ),
    .rst_n                  (app_rst_n                                       )
);

eth_udp_stack
#(
    .LOCAL_MAC              (LOCAL_MAC                                       ),
    .LOCAL_IP               (LOCAL_IP                                        ),
    .LOCAL_PORT             (LOCAL_PORT                                      )
)
eth_udp_stack_inst
(
    .gmii_rx_clk            (gmii_rx_clk                                     ),
    .rx_rst_n               (rx_rst_n                                        ),
    .gmii_rx_dv             (gmii_rx_dv                                      ),
    .gmii_rx_er             (gmii_rx_er                                      ),
    .gmii_rxd               (gmii_rxd                                        ),
    .gmii_tx_clk            (gmii_tx_clk                                     ),
    .tx_rst_n               (tx_rst_n                                        ),
    .gmii_tx_en             (gmii_tx_en                                      ),
    .gmii_tx_er             (gmii_tx_er                                      ),
    .gmii_txd               (gmii_txd                                        ),
    .udp_rx_packet_start    (udp_rx_start                                    ),
    .udp_rx_src_mac         (udp_rx_mac                                      ),
    .udp_rx_src_ip          (udp_rx_ip                                       ),
    .udp_rx_src_port        (udp_rx_port                                     ),
    .udp_rx_payload_length  (udp_rx_length                                   ),
    .udp_rx_payload_valid   (udp_rx_valid                                    ),
    .udp_rx_payload_data    (udp_rx_data                                     ),
    .udp_rx_payload_last    (udp_rx_last                                     ),
    .udp_rx_packet_done     (rx_packet_done                                  ),
    .udp_rx_packet_error    (rx_packet_error                                 ),
    .active_dst_mac         (udp_tx_peer[95:48]                              ),
    .active_dst_ip          (udp_tx_peer[47:16]                              ),
    .active_dst_port        (udp_tx_peer[15:0]                               ),
    .app_udp_req_valid      (udp_tx_req                                      ),
    .app_udp_req_ready      (udp_tx_ready                                    ),
    .app_udp_payload_length (udp_tx_length                                   ),
    .app_udp_payload_sum    (udp_tx_sum                                      ),
    .app_udp_payload_valid  (udp_tx_valid                                    ),
    .app_udp_payload_ready  (udp_tx_byte_ready                               ),
    .app_udp_payload_data   (udp_tx_data                                     ),
    .app_udp_payload_last   (udp_tx_last                                     ),
    .tx_busy                (tx_busy                                         ),
    .tx_done                (tx_packet_done                                  )
);

eth_image_rx eth_image_rx_inst
(
    .rx_clk                 (gmii_rx_clk                                     ),
    .rx_rst_n               (rx_rst_n                                        ),
    .udp_packet_start       (udp_rx_start                                    ),
    .udp_peer               ({udp_rx_mac,udp_rx_ip,udp_rx_port}              ),
    .udp_length             (udp_rx_length                                   ),
    .udp_byte_valid         (udp_rx_valid                                    ),
    .udp_byte_data          (udp_rx_data                                     ),
    .udp_byte_last          (udp_rx_last                                     ),
    .udp_packet_done        (rx_packet_done                                  ),
    .udp_packet_error       (rx_packet_error                                 ),
    .rx_drop_flag           (rx_drop_flag                                    ),
    .app_clk                (app_clk                                         ),
    .app_rst_n              (app_rst_n                                       ),
    .app_packet_valid       (app_packet_valid                                ),
    .app_packet_ready       (app_packet_ready                                ),
    .app_peer               (app_peer                                        ),
    .app_byte_valid         (app_rx_valid                                    ),
    .app_byte_ready         (app_rx_ready                                    ),
    .app_byte_data          (app_rx_data                                     )
);

img_stream_top
#(
    .FAST_TRANSPORT         (1                                               ),
    .ASYNC_ALGORITHMS       (ASYNC_ALGORITHMS                                )
)
img_stream_top_inst
(
    .sys_clk                (app_clk                                         ),
    .sys_rst_n              (app_rst_n                                       ),
    .algo_clk               (algo_clk                                        ),
    .rx_data                (app_rx_data                                     ),
    .rx_valid               (app_rx_valid                                    ),
    .rx_ready               (app_rx_ready                                    ),
    .rx_peer                (active_peer                                     ),
    .tx_data                (app_tx_data                                     ),
    .tx_valid               (app_tx_valid                                    ),
    .tx_ready               (app_tx_ready                                    ),
    .tx_start_flag          (app_tx_start                                    ),
    .tx_length              (app_tx_length                                   ),
    .tx_start_ready         (app_tx_start_ready                              ),
    .tx_done_flag           (app_tx_done                                     ),
    .tx_peer                (app_tx_peer                                     )
);

eth_packet_queue tx_mailbox_inst
(
    .wr_clk                 (app_clk                                         ),
    .wr_rst_n               (app_rst_n                                       ),
    .wr_start_valid         (app_tx_start                                    ),
    .wr_start_ready         (app_tx_start_ready                              ),
    .wr_length              (app_tx_length                                   ),
    .wr_peer                (app_tx_peer                                     ),
    .wr_byte_valid          (app_tx_valid                                    ),
    .wr_byte_ready          (app_tx_ready                                    ),
    .wr_byte_data           (app_tx_data                                     ),
    .wr_finish_flag         (app_tx_done                                     ),
    .wr_abort_en            (1'b0                                            ),
    .wr_drop_flag           (                                                ),
    .rd_clk                 (gmii_tx_clk                                     ),
    .rd_rst_n               (tx_rst_n                                        ),
    .rd_packet_valid        (udp_tx_req                                      ),
    .rd_packet_ready        (udp_tx_ready                                    ),
    .rd_length              (udp_tx_length                                   ),
    .rd_peer                (udp_tx_peer                                     ),
    .rd_sum                 (udp_tx_sum                                      ),
    .rd_byte_valid          (udp_tx_valid                                    ),
    .rd_byte_ready          (udp_tx_byte_ready                               ),
    .rd_byte_data           (udp_tx_data                                     ),
    .rd_byte_last           (udp_tx_last                                     )
);

endmodule
