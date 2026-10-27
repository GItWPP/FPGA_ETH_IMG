//--------------------------------------------------------------------------------------------------------
// 模块： uart_img_top
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 50MHz纯PL串口图像处理顶层，默认1.5Mbps、RGB565分包往返
// 作者： WANG
// 时间： 26.10.21
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  uart_img_top
#(
    parameter integer CLK_HZ          = 50_000_000,
    parameter integer UART_BPS        = 1_500_000,
    parameter integer MAX_WIDTH       = 1920,
    parameter integer MAX_HEIGHT      = 1080,
    parameter integer RX_TIMEOUT_CLKS = 5_000_000
)
(
    input   wire                    sys_clk                ,   //板载50MHz时钟，U18
    input   wire                    sys_rst_n              ,   //KEY1，M15，低有效
    input   wire                    uart_rx_i              ,   //J20第9针，T11

    output  wire                    uart_tx_o              //J20第10针，T10
);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//wire  define
wire                    rst_n;
wire           [7:0]    rx_byte;
wire           [7:0]    tx_byte;
wire                    rx_flag;
wire                    rx_error;
wire                    tx_valid;
wire                    tx_ready;
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
wire           [2:0]    pixel_mode;
wire           [15:0]   pixel_in_data;
wire           [143:0]  pixel_window_data;
wire           [15:0]   pixel_out_data;
wire                    pixel_in_valid;
wire                    pixel_in_ready;
wire                    pixel_out_valid;
wire                    pixel_out_ready;
wire                    resp_valid;
wire                    resp_ready;
wire                    resp_done;
wire           [7:0]    resp_cmd;
wire           [15:0]   resp_id;
wire           [15:0]   resp_seq;
wire           [15:0]   resp_length;

wire                    hog_frame_wr_en;
wire           [16:0]   hog_frame_wr_addr;
wire           [7:0]    hog_frame_wr_data;
wire                    hog_start_valid;
wire                    hog_start_ready;
wire                    hog_done_flag;
wire           [8:0]    hog_score_rd_addr;
wire           [31:0]   hog_score_rd_data;
wire           [31:0]   hog_model_id;

//reg   define
(* ASYNC_REG = "TRUE" *) reg [1:0] rst_sync;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
assign rst_n = rst_sync[1];

//rst_sync:外部复位异步拉低、经过两级寄存器同步释放
always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0)
        rst_sync <= 2'b00;
    else
        rst_sync <= {rst_sync[0], 1'b1};

//********************************************************************//
//*************************** Instantiation **************************//
//********************************************************************//

uart_rx
#(
    .CLK_HZ             (CLK_HZ              ),
    .UART_BPS           (UART_BPS            )
)
uart_rx_inst
(
    .sys_clk            (sys_clk             ),
    .sys_rst_n          (rst_n               ),

    .rx                 (uart_rx_i           ),
    .data               (rx_byte             ),
    .data_flag          (rx_flag             ),
    .error_flag         (rx_error            )
);

uart_tx
#(
    .CLK_HZ             (CLK_HZ              ),
    .UART_BPS           (UART_BPS            )
)
uart_tx_inst
(
    .sys_clk            (sys_clk             ),
    .sys_rst_n          (rst_n               ),

    .data               (tx_byte             ),
    .data_valid         (tx_valid            ),
    .data_ready         (tx_ready            ),
    .tx                 (uart_tx_o           )
);

img_packet_rx
#(
    .TIMEOUT_CLKS       (RX_TIMEOUT_CLKS     )
)
img_packet_rx_inst
(
    .sys_clk            (sys_clk             ),
    .sys_rst_n          (rst_n               ),

    .receive_en         (receive_en          ),
    .byte_data          (rx_byte             ),
    .byte_flag          (rx_flag             ),
    .byte_error         (rx_error            ),
    .buf_wr_en          (rx_wr_en            ),
    .buf_wr_addr        (rx_wr_addr          ),
    .buf_wr_data        (rx_wr_data          ),
    .packet_valid       (packet_valid        ),
    .packet_ready       (packet_ready        ),
    .cmd                (req_cmd             ),
    .transfer_id        (req_id              ),
    .seq                (req_seq             ),
    .length             (req_length          ),
    .packet_crc         (req_crc             )
);

img_block_buffer
rx_buffer_inst
(
    .sys_clk            (sys_clk             ),
    .wr_en              (rx_wr_en            ),
    .wr_addr            (rx_wr_addr          ),
    .wr_data            (rx_wr_data          ),
    .rd_addr            (rx_rd_addr          ),
    .rd_data            (rx_rd_data          )
);

img_block_buffer
result_buffer_inst
(
    .sys_clk            (sys_clk             ),
    .wr_en              (result_wr_en        ),
    .wr_addr            (result_wr_addr      ),
    .wr_data            (result_wr_data      ),
    .rd_addr            (resp_addr           ),
    .rd_data            (result_rd_data      )
);

img_process_top
img_process_top_inst
(
    .sys_clk            (sys_clk             ),
    .sys_rst_n          (rst_n               ),

    .mode               (pixel_mode          ),
    .in_data            (pixel_in_data       ),
    .window_data        (pixel_window_data   ),
    .in_valid           (pixel_in_valid      ),
    .in_ready           (pixel_in_ready      ),
    .out_data           (pixel_out_data      ),
    .out_valid          (pixel_out_valid     ),
    .out_ready          (pixel_out_ready     ),
    .hog_frame_wr_en       (hog_frame_wr_en),
    .hog_frame_wr_addr     (hog_frame_wr_addr),
    .hog_frame_wr_data     (hog_frame_wr_data),
    .hog_start_valid       (hog_start_valid),
    .hog_start_ready       (hog_start_ready),
    .hog_done_flag         (hog_done_flag),
    .hog_score_rd_addr     (hog_score_rd_addr),
    .hog_score_rd_data     (hog_score_rd_data),
    .hog_model_id          (hog_model_id)
);

img_command_top
#(
    .MAX_WIDTH          (MAX_WIDTH           ),
    .MAX_HEIGHT         (MAX_HEIGHT          )
)
img_ctrl_inst
(
    .sys_clk            (sys_clk             ),
    .sys_rst_n          (rst_n               ),

    .receive_en         (receive_en          ),
    .packet_valid       (packet_valid        ),
    .packet_ready       (packet_ready        ),
    .req_cmd            (req_cmd             ),
    .req_id             (req_id              ),
    .req_seq            (req_seq             ),
    .req_length         (req_length          ),
    .req_crc            (req_crc             ),
    .rx_rd_addr         (rx_rd_addr          ),
    .rx_rd_data         (rx_rd_data          ),
    .result_wr_en       (result_wr_en        ),
    .result_wr_addr     (result_wr_addr      ),
    .result_wr_data     (result_wr_data      ),
    .pixel_mode         (pixel_mode          ),
    .pixel_in_data      (pixel_in_data       ),
    .pixel_window_data  (pixel_window_data   ),
    .pixel_in_valid     (pixel_in_valid      ),
    .pixel_in_ready     (pixel_in_ready      ),
    .pixel_out_data     (pixel_out_data      ),
    .pixel_out_valid    (pixel_out_valid     ),
    .pixel_out_ready    (pixel_out_ready     ),
    .resp_valid         (resp_valid          ),
    .resp_ready         (resp_ready          ),
    .resp_cmd           (resp_cmd            ),
    .resp_id            (resp_id             ),
    .resp_seq           (resp_seq            ),
    .resp_length        (resp_length         ),
    .resp_addr          (resp_addr           ),
    .result_rd_data     (result_rd_data      ),
    .resp_data          (resp_data           ),
    .resp_done          (resp_done           ),
    .hog_frame_wr_en       (hog_frame_wr_en),
    .hog_frame_wr_addr     (hog_frame_wr_addr),
    .hog_frame_wr_data     (hog_frame_wr_data),
    .hog_start_valid       (hog_start_valid),
    .hog_start_ready       (hog_start_ready),
    .hog_done_flag         (hog_done_flag),
    .hog_score_rd_addr     (hog_score_rd_addr),
    .hog_score_rd_data     (hog_score_rd_data),
    .hog_model_id          (hog_model_id)
);

img_packet_tx
img_packet_tx_inst
(
    .sys_clk            (sys_clk             ),
    .sys_rst_n          (rst_n               ),

    .start_valid        (resp_valid          ),
    .start_ready        (resp_ready          ),
    .cmd                (resp_cmd            ),
    .transfer_id        (resp_id             ),
    .seq                (resp_seq            ),
    .length             (resp_length         ),
    .payload_addr       (resp_addr           ),
    .payload_data       (resp_data           ),
    .byte_data          (tx_byte             ),
    .byte_valid         (tx_valid            ),
    .byte_ready         (tx_ready            ),
    .done_flag          (resp_done           )
);

endmodule
