//--------------------------------------------------------------------------------------------------------
// 模块： img_stream_top
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 与物理传输无关的字节协议、命令分发和全部图像算法封装
// 作者： WANG
// 时间： 26.10.22
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  img_stream_top
#(
    parameter integer MAX_WIDTH       = 1920,
    parameter integer MAX_HEIGHT      = 1080,
    parameter integer RX_TIMEOUT_CLKS = 5_000_000,
    parameter integer FAST_TRANSPORT = 0,
    parameter integer ASYNC_ALGORITHMS = 0
)
(
    input   wire                    sys_clk                ,
    input   wire                    sys_rst_n              ,
    input   wire                    algo_clk               ,
    input   wire           [7:0]    rx_data                ,
    input   wire                    rx_valid               ,
    output  wire                    rx_ready               ,
    input   wire           [95:0]   rx_peer                ,
    output  wire           [7:0]    tx_data                ,
    output  wire                    tx_valid               ,
    input   wire                    tx_ready               ,
    output  wire                    tx_start_flag          ,
    output  wire           [15:0]   tx_length              ,
    input   wire                    tx_start_ready         ,
    output  wire                    tx_done_flag,
    output  wire           [95:0]   tx_peer
);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//wire  define
wire                    rst_n;
wire                    packet_release_flag;
wire           [95:0]   request_peer;
wire                    receive_en;
wire                    packet_valid;
wire                    packet_ready;
wire           [7:0]    req_cmd;
wire           [15:0]   req_id;
wire           [15:0]   req_seq;
wire           [15:0]   req_length;
wire           [15:0]   req_crc;
wire                    rx_wr_en;
wire           [9:0]    rx_wr_addr;
wire           [9:0]    rx_rd_addr;
wire           [7:0]    rx_wr_data;
wire           [7:0]    rx_rd_data;
wire                    result_wr_en;
wire           [9:0]    result_wr_addr;
wire           [9:0]    resp_addr;
wire           [7:0]    result_wr_data;
wire           [7:0]    result_rd_data;
wire           [7:0]    resp_data;
wire                    resp_valid;
wire                    resp_ready;
wire                    packet_tx_ready;
wire                    resp_done;
wire           [7:0]    resp_cmd;
wire           [15:0]   resp_id;
wire           [15:0]   resp_seq;
wire           [15:0]   resp_length;

wire                    cmd_receive_en;
wire                    cmd_packet_valid;
wire                    cmd_packet_ready;
wire                    cmd_resp_valid;
wire                    cmd_resp_ready;
wire                    cmd_resp_done;
wire           [7:0]    cmd_resp_cmd;
wire           [15:0]   cmd_resp_id;
wire           [15:0]   cmd_resp_seq;
wire           [15:0]   cmd_resp_length;
wire           [7:0]    cmd_resp_data;
wire           [7:0]    fast_payload_data;

//reg   define
reg            [7:0]    control_resp_data;
(* ASYNC_REG = "TRUE" *) reg [1:0] rst_sync;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
assign rst_n = rst_sync[1];
assign resp_ready = packet_tx_ready && tx_start_ready && !resp_done;
assign tx_start_flag = resp_valid && resp_ready;
assign tx_length = resp_length + 16'd14;
assign tx_done_flag = resp_done;

//控制类应答原为组合查表，延迟一拍后与同步RAM应答使用相同时序
assign fast_payload_data = (resp_cmd == 8'hc1 || resp_cmd == 8'h83 || resp_cmd == 8'h93 || resp_cmd == 8'ha3)
                          ? resp_data : control_resp_data;
always@(posedge sys_clk)
    if(rst_n == 1'b0)
        control_resp_data <= 8'd0;
    else
        control_resp_data <= resp_data;

//rst_sync:外部复位异步拉低、经过两级寄存器同步释放
always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0)
        rst_sync <= 2'b00;
    else
        rst_sync <= {rst_sync[0], 1'b1};

//********************************************************************//
//*************************** Instantiation **************************//
//********************************************************************//

generate
    if(FAST_TRANSPORT) begin : pipeline_receive
        img_packet_rx_queue
        #(
            .TIMEOUT_CLKS       (RX_TIMEOUT_CLKS)
        )
        rx_queue_inst
        (
            .sys_clk            (sys_clk),
            .sys_rst_n          (rst_n),
            .byte_data          (rx_data),
            .byte_valid         (rx_valid),
            .byte_ready         (rx_ready),
            .byte_peer          (rx_peer),
            .packet_valid       (packet_valid),
            .packet_ready       (packet_ready),
            .packet_release_flag (packet_release_flag),
            .cmd                (req_cmd),
            .transfer_id        (req_id),
            .seq                (req_seq),
            .length             (req_length),
            .packet_crc         (req_crc),
            .packet_peer        (request_peer),
            .rd_addr            (rx_rd_addr),
            .rd_data            (rx_rd_data)
        );
    end else begin : legacy_receive
        assign rx_ready = receive_en && !packet_valid;
        assign request_peer = rx_peer;
img_packet_rx
#(
    .TIMEOUT_CLKS           (RX_TIMEOUT_CLKS                                 )
)
img_packet_rx_inst
(
    .sys_clk                (sys_clk                                         ),
    .sys_rst_n              (rst_n                                           ),

    .receive_en             (receive_en                                      ),
    .byte_data              (rx_data                                         ),
    .byte_flag              (rx_valid && rx_ready                            ),
    .byte_error             (1'b0                                            ),
    .buf_wr_en              (rx_wr_en                                        ),
    .buf_wr_addr            (rx_wr_addr                                      ),
    .buf_wr_data            (rx_wr_data                                      ),
    .packet_valid           (packet_valid                                    ),
    .packet_ready           (packet_ready                                    ),
    .cmd                    (req_cmd                                         ),
    .transfer_id            (req_id                                          ),
    .seq                    (req_seq                                         ),
    .length                 (req_length                                      ),
    .packet_crc             (req_crc                                         )
);

img_block_buffer
rx_buffer_inst
(
    .sys_clk                (sys_clk                                         ),
    .wr_en                  (rx_wr_en                                        ),
    .wr_addr                (rx_wr_addr                                      ),
    .wr_data                (rx_wr_data                                      ),
    .rd_addr                (rx_rd_addr                                      ),
    .rd_data                (rx_rd_data                                      )
);
    end
endgenerate

img_block_buffer
result_buffer_inst
(
    .sys_clk                (sys_clk                                         ),
    .wr_en                  (result_wr_en                                    ),
    .wr_addr                (result_wr_addr                                  ),
    .wr_data                (result_wr_data                                  ),
    .rd_addr                (resp_addr                                       ),
    .rd_data                (result_rd_data                                  )
);

generate
    if(ASYNC_ALGORITHMS) begin : async_algorithm
        img_fast_command
        #(
            .MAX_WIDTH              (MAX_WIDTH),
            .MAX_HEIGHT             (MAX_HEIGHT)
        )
        command_bridge_inst
        (
            .sys_clk                 (sys_clk),
            .sys_rst_n               (rst_n),
            .receive_en              (cmd_receive_en),
            .packet_valid            (cmd_packet_valid),
            .packet_ready            (cmd_packet_ready),
            .req_cmd                 (req_cmd),
            .req_id                  (req_id),
            .req_seq                 (req_seq),
            .req_length              (req_length),
            .req_crc                 (req_crc),
            .rx_rd_addr              (rx_rd_addr),
            .rx_rd_data              (rx_rd_data),
            .result_wr_en            (result_wr_en),
            .result_wr_addr          (result_wr_addr),
            .result_wr_data          (result_wr_data),
            .resp_valid              (cmd_resp_valid),
            .resp_ready              (cmd_resp_ready),
            .resp_cmd                (cmd_resp_cmd),
            .resp_id                 (cmd_resp_id),
            .resp_seq                (cmd_resp_seq),
            .resp_length             (cmd_resp_length),
            .resp_addr               (resp_addr),
            .resp_data               (cmd_resp_data),
            .resp_done               (cmd_resp_done),
            .req_peer                (request_peer),
            .algo_clk                (algo_clk)
        );
    end else begin : same_clock_algorithm
        img_algorithm_top
        #(
            .MAX_WIDTH              (MAX_WIDTH),
            .MAX_HEIGHT             (MAX_HEIGHT),
            .FAST_COPY              (FAST_TRANSPORT)
        )
        algorithm_inst
        (
            .sys_clk                 (sys_clk),
            .sys_rst_n               (rst_n),
            .receive_en              (cmd_receive_en),
            .packet_valid            (cmd_packet_valid),
            .packet_ready            (cmd_packet_ready),
            .req_cmd                 (req_cmd),
            .req_id                  (req_id),
            .req_seq                 (req_seq),
            .req_length              (req_length),
            .req_crc                 (req_crc),
            .rx_rd_addr              (rx_rd_addr),
            .rx_rd_data              (rx_rd_data),
            .result_wr_en            (result_wr_en),
            .result_wr_addr          (result_wr_addr),
            .result_wr_data          (result_wr_data),
            .resp_valid              (cmd_resp_valid),
            .resp_ready              (cmd_resp_ready),
            .resp_cmd                (cmd_resp_cmd),
            .resp_id                 (cmd_resp_id),
            .resp_seq                (cmd_resp_seq),
            .resp_length             (cmd_resp_length),
            .resp_addr               (resp_addr),
            .resp_data               (cmd_resp_data),
            .resp_done               (cmd_resp_done),
            .result_rd_data          (result_rd_data),
            .copy_response           ()
        );
    end
endgenerate

generate
    if(FAST_TRANSPORT) begin : window_transport
        img_response_cache img_response_cache_inst
        (
            .sys_clk                (sys_clk                                         ),
            .sys_rst_n              (rst_n                                           ),
            .packet_valid           (packet_valid                                    ),
            .packet_ready           (packet_ready                                    ),
            .receive_en             (receive_en                                      ),
            .packet_release_flag    (packet_release_flag                             ),
            .req_cmd                (req_cmd                                         ),
            .req_id                 (req_id                                          ),
            .req_seq                (req_seq                                         ),
            .req_length             (req_length                                      ),
            .req_crc                (req_crc                                         ),
            .req_peer               (request_peer                                    ),
            .cmd_packet_valid       (cmd_packet_valid                                ),
            .cmd_packet_ready       (cmd_packet_ready                                ),
            .result_wr_en           (result_wr_en                                    ),
            .result_wr_addr         (result_wr_addr                                  ),
            .result_wr_data         (result_wr_data                                  ),
            .cmd_resp_valid         (cmd_resp_valid                                  ),
            .cmd_resp_ready         (cmd_resp_ready                                  ),
            .cmd_resp_cmd           (cmd_resp_cmd                                    ),
            .cmd_resp_id            (cmd_resp_id                                     ),
            .cmd_resp_seq           (cmd_resp_seq                                    ),
            .cmd_resp_length        (cmd_resp_length                                 ),
            .cmd_resp_data          (cmd_resp_data                                   ),
            .cmd_resp_done          (cmd_resp_done                                   ),
            .resp_valid             (resp_valid                                      ),
            .resp_ready             (resp_ready                                      ),
            .resp_cmd               (resp_cmd                                        ),
            .resp_id                (resp_id                                         ),
            .resp_seq               (resp_seq                                        ),
            .resp_length            (resp_length                                     ),
            .resp_addr              (resp_addr                                       ),
            .resp_data              (resp_data                                       ),
            .resp_peer              (tx_peer                                         ),
            .resp_done              (resp_done                                       )
        );
    end else begin : single_transport
        assign tx_peer = rx_peer;
        assign receive_en = cmd_receive_en;
        assign packet_ready = cmd_packet_ready;
        assign cmd_packet_valid = packet_valid;
        assign resp_valid = cmd_resp_valid;
        assign cmd_resp_ready = resp_ready;
        assign resp_cmd = cmd_resp_cmd;
        assign resp_id = cmd_resp_id;
        assign resp_seq = cmd_resp_seq;
        assign resp_length = cmd_resp_length;
        assign resp_data = cmd_resp_data;
        assign cmd_resp_done = resp_done;
    end
endgenerate

generate
    if(FAST_TRANSPORT) begin : fast_tx

img_packet_tx_fast
img_packet_tx_inst
(
    .sys_clk                (sys_clk                                         ),
    .sys_rst_n              (rst_n                                           ),

    .start_valid            (resp_valid && tx_start_ready && !resp_done       ),
    .start_ready            (packet_tx_ready                                 ),
    .cmd                    (resp_cmd                                        ),
    .transfer_id            (resp_id                                         ),
    .seq                    (resp_seq                                        ),
    .length                 (resp_length                                     ),
    .payload_addr           (resp_addr                                       ),
    .payload_data           (fast_payload_data                               ),
    .byte_data              (tx_data                                         ),
    .byte_valid             (tx_valid                                        ),
    .byte_ready             (tx_ready                                        ),
    .done_flag              (resp_done                                       )
);

    end else begin : single_tx

img_packet_tx
img_packet_tx_inst
(
    .sys_clk                (sys_clk                                         ),
    .sys_rst_n              (rst_n                                           ),

    .start_valid            (resp_valid && tx_start_ready && !resp_done       ),
    .start_ready            (packet_tx_ready                                 ),
    .cmd                    (resp_cmd                                        ),
    .transfer_id            (resp_id                                         ),
    .seq                    (resp_seq                                        ),
    .length                 (resp_length                                     ),
    .payload_addr           (resp_addr                                       ),
    .payload_data           (resp_data                                       ),
    .byte_data              (tx_data                                         ),
    .byte_valid             (tx_valid                                        ),
    .byte_ready             (tx_ready                                        ),
    .done_flag              (resp_done                                       )
);

    end
endgenerate

endmodule
