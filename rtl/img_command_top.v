//--------------------------------------------------------------------------------------------------------
// 模块： img_command_top
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 普通图像、HOG与Band独立命令分发，共享缓存仲裁及跨会话失效
// 作者： WANG
// 时间： 26.10.21
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  img_command_top
#(
    parameter integer MAX_WIDTH = 1920,
    parameter integer MAX_HEIGHT = 1080,
    parameter integer FAST_COPY = 0,
    parameter integer EXTERNAL_COPY = 0
)
(
    input   wire                    sys_clk                ,
    input   wire                    sys_rst_n              ,
    output  wire                    receive_en             ,
    input   wire                    packet_valid           ,
    output  wire                    packet_ready           ,
    input   wire           [7:0]    req_cmd                ,
    input   wire           [15:0]   req_id                 ,
    input   wire           [15:0]   req_seq                ,
    input   wire           [15:0]   req_length             ,
    input   wire           [15:0]   req_crc                ,

    output  wire           [9:0]    rx_rd_addr             ,
    input   wire           [7:0]    rx_rd_data             ,
    output  wire                    result_wr_en           ,
    output  wire           [9:0]    result_wr_addr         ,
    output  wire           [7:0]    result_wr_data         ,

    output  wire           [2:0]    pixel_mode             ,
    output  wire           [15:0]   pixel_in_data          ,
    output  wire           [143:0]  pixel_window_data      ,
    output  wire                    pixel_in_valid         ,
    input   wire                    pixel_in_ready         ,
    input   wire           [15:0]   pixel_out_data         ,
    input   wire                    pixel_out_valid        ,
    output  wire                    pixel_out_ready        ,

    output  wire                    resp_valid             ,
    input   wire                    resp_ready             ,
    output  wire           [7:0]    resp_cmd               ,
    output  wire           [15:0]   resp_id                ,
    output  wire           [15:0]   resp_seq               ,
    output  wire           [15:0]   resp_length            ,
    input   wire           [9:0]    resp_addr              ,
    input   wire           [7:0]    result_rd_data         ,
    output  wire           [7:0]    resp_data              ,
    input   wire                    resp_done              ,
    output  wire                    hog_frame_wr_en        ,
    output  wire           [16:0]   hog_frame_wr_addr      ,
    output  wire           [7:0]    hog_frame_wr_data      ,
    output  wire                    hog_start_valid        ,
    input   wire                    hog_start_ready        ,
    input   wire                    hog_done_flag          ,
    output  wire           [8:0]    hog_score_rd_addr      ,
    input   wire           [31:0]   hog_score_rd_data      ,
    input   wire           [31:0]   hog_model_id           ,
    output  wire                    copy_response
);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//wire  define
wire                    route_hog;
wire                    route_band;
wire                    band_success;
wire                    band_start_success;
wire                    image_success;
wire                    image_start_success;
wire                    image_copy_response;
wire                    hog_success;
wire                    hog_start_success;
wire                    image_receive_en;
wire                    hog_receive_en;
wire                    band_receive_en;
wire                    image_packet_ready;
wire                    hog_packet_ready;
wire                    band_packet_ready;
wire           [9:0]    image_rx_rd_addr;
wire           [9:0]    hog_rx_rd_addr;
wire           [9:0]    band_rx_rd_addr;
wire                    image_result_wr_en;
wire                    hog_result_wr_en;
wire                    band_result_wr_en;
wire           [9:0]    image_result_wr_addr;
wire           [9:0]    hog_result_wr_addr;
wire           [9:0]    band_result_wr_addr;
wire           [7:0]    image_result_wr_data;
wire           [7:0]    hog_result_wr_data;
wire           [7:0]    band_result_wr_data;
wire                    image_resp_valid;
wire                    hog_resp_valid;
wire                    band_resp_valid;
wire           [7:0]    image_resp_cmd;
wire           [7:0]    hog_resp_cmd;
wire           [7:0]    band_resp_cmd;
wire           [15:0]   image_resp_id;
wire           [15:0]   hog_resp_id;
wire           [15:0]   band_resp_id;
wire           [15:0]   image_resp_seq;
wire           [15:0]   hog_resp_seq;
wire           [15:0]   band_resp_seq;
wire           [15:0]   image_resp_length;
wire           [15:0]   hog_resp_length;
wire           [15:0]   band_resp_length;
wire           [7:0]    image_resp_data;
wire           [7:0]    hog_resp_data;
wire           [7:0]    band_resp_data;
//reg   define
reg            [1:0]    owner_kind;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
assign route_hog = (req_cmd[7:4] == 4'h1);
assign route_band = (req_cmd[7:4] == 4'h2);
assign receive_en = image_receive_en && hog_receive_en && band_receive_en;
assign packet_ready = image_packet_ready && hog_packet_ready && band_packet_ready;
assign copy_response = (owner_kind == 2'd0) && image_copy_response;

//共享RAM和应答端口在接受整包时锁存所有者，整个事务期间保持
always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        owner_kind <= 2'd0;
    else if(packet_valid && packet_ready)
        owner_kind <= route_band ? 2'd2 : (route_hog ? 2'd1 : 2'd0);
assign rx_rd_addr = (owner_kind == 2'd2) ? band_rx_rd_addr : ((owner_kind == 2'd1) ? hog_rx_rd_addr : image_rx_rd_addr);
assign result_wr_en = (owner_kind == 2'd2) ? band_result_wr_en : ((owner_kind == 2'd1) ? hog_result_wr_en : image_result_wr_en);
assign result_wr_addr = (owner_kind == 2'd2) ? band_result_wr_addr : ((owner_kind == 2'd1) ? hog_result_wr_addr : image_result_wr_addr);
assign result_wr_data = (owner_kind == 2'd2) ? band_result_wr_data : ((owner_kind == 2'd1) ? hog_result_wr_data : image_result_wr_data);
assign resp_valid = (owner_kind == 2'd2) ? band_resp_valid : ((owner_kind == 2'd1) ? hog_resp_valid : image_resp_valid);
assign resp_cmd = (owner_kind == 2'd2) ? band_resp_cmd : ((owner_kind == 2'd1) ? hog_resp_cmd : image_resp_cmd);
assign resp_id = (owner_kind == 2'd2) ? band_resp_id : ((owner_kind == 2'd1) ? hog_resp_id : image_resp_id);
assign resp_seq = (owner_kind == 2'd2) ? band_resp_seq : ((owner_kind == 2'd1) ? hog_resp_seq : image_resp_seq);
assign resp_length = (owner_kind == 2'd2) ? band_resp_length : ((owner_kind == 2'd1) ? hog_resp_length : image_resp_length);
assign resp_data = (owner_kind == 2'd2) ? band_resp_data : ((owner_kind == 2'd1) ? hog_resp_data : image_resp_data);

//********************************************************************//
//*************************** Instantiation **************************//
//********************************************************************//
img_ctrl
#(
    .MAX_WIDTH              (MAX_WIDTH                                       ),
    .MAX_HEIGHT             (MAX_HEIGHT                                      ),
    .FAST_COPY              (FAST_COPY                                       ),
    .EXTERNAL_COPY          (EXTERNAL_COPY                                   )
)
image_ctrl_inst
(
    .sys_clk                (sys_clk                                         ),
    .sys_rst_n              (sys_rst_n                                       ),
    .receive_en             (image_receive_en                                ),
    .packet_valid           (packet_valid && packet_ready && !route_hog && !route_band),
    .packet_ready           (image_packet_ready                              ),
    .req_cmd                (req_cmd                                         ),
    .req_id                 (req_id                                          ),
    .req_seq                (req_seq                                         ),
    .req_length             (req_length                                      ),
    .req_crc                (req_crc                                         ),
    .rx_rd_addr             (image_rx_rd_addr                                ),
    .rx_rd_data             (rx_rd_data                                      ),
    .result_wr_en           (image_result_wr_en                              ),
    .result_wr_addr         (image_result_wr_addr                            ),
    .result_wr_data         (image_result_wr_data                            ),
    .pixel_mode             (pixel_mode                                      ),
    .pixel_in_data          (pixel_in_data                                   ),
    .pixel_window_data      (pixel_window_data                               ),
    .pixel_in_valid         (pixel_in_valid                                  ),
    .pixel_in_ready         (pixel_in_ready                                  ),
    .pixel_out_data         (pixel_out_data                                  ),
    .pixel_out_valid        (pixel_out_valid                                 ),
    .pixel_out_ready        (pixel_out_ready                                 ),
    .resp_valid             (image_resp_valid                                ),
    .resp_ready             (resp_ready && owner_kind == 2'd0                ),
    .resp_cmd               (image_resp_cmd                                  ),
    .resp_id                (image_resp_id                                   ),
    .resp_seq               (image_resp_seq                                  ),
    .resp_length            (image_resp_length                               ),
    .resp_addr              (resp_addr                                       ),
    .result_rd_data         (result_rd_data                                  ),
    .resp_data              (image_resp_data                                 ),
    .resp_done              (resp_done && owner_kind == 2'd0                 ),
    .cache_clear            (hog_success || band_success                     ),
    .session_clear          (hog_start_success || band_start_success         ),
    .success_flag           (image_success                                   ),
    .success_start_flag     (image_start_success                             ),
    .copy_response          (image_copy_response                             )
);

hog_uart_ctrl
hog_uart_ctrl_inst
(
    .sys_clk                (sys_clk                                         ),
    .sys_rst_n              (sys_rst_n                                       ),
    .receive_en             (hog_receive_en                                  ),
    .packet_valid           (packet_valid && packet_ready && route_hog       ),
    .packet_ready           (hog_packet_ready                                ),
    .req_cmd                (req_cmd                                         ),
    .req_id                 (req_id                                          ),
    .req_seq                (req_seq                                         ),
    .req_length             (req_length                                      ),
    .req_crc                (req_crc                                         ),
    .rx_rd_addr             (hog_rx_rd_addr                                  ),
    .rx_rd_data             (rx_rd_data                                      ),
    .result_wr_en           (hog_result_wr_en                                ),
    .result_wr_addr         (hog_result_wr_addr                              ),
    .result_wr_data         (hog_result_wr_data                              ),
    .resp_valid             (hog_resp_valid                                  ),
    .resp_ready             (resp_ready && owner_kind == 2'd1                ),
    .resp_cmd               (hog_resp_cmd                                    ),
    .resp_id                (hog_resp_id                                     ),
    .resp_seq               (hog_resp_seq                                    ),
    .resp_length            (hog_resp_length                                 ),
    .resp_addr              (resp_addr                                       ),
    .result_rd_data         (result_rd_data                                  ),
    .resp_data              (hog_resp_data                                   ),
    .resp_done              (resp_done && owner_kind == 2'd1                 ),
    .cache_clear            (image_success || band_success                   ),
    .session_clear          (image_start_success || band_start_success       ),
    .success_flag           (hog_success                                     ),
    .success_start_flag     (hog_start_success                               ),
    .hog_frame_wr_en        (hog_frame_wr_en                                 ),
    .hog_frame_wr_addr      (hog_frame_wr_addr                               ),
    .hog_frame_wr_data      (hog_frame_wr_data                               ),
    .hog_start_valid        (hog_start_valid                                 ),
    .hog_start_ready        (hog_start_ready                                 ),
    .hog_done_flag          (hog_done_flag                                   ),
    .hog_score_rd_addr      (hog_score_rd_addr                               ),
    .hog_score_rd_data      (hog_score_rd_data                               ),
    .hog_model_id           (hog_model_id                                    )
);
band_command_top
#(
    .USE_ULTRARAM   (FAST_COPY)
)
band_command_top_inst
(
    .sys_clk                (sys_clk                                         ),
    .sys_rst_n              (sys_rst_n                                       ),
    .cache_clear            (image_success || hog_success                    ),
    .session_clear          (image_start_success || hog_start_success        ),
    .success_flag           (band_success                                    ),
    .success_start_flag     (band_start_success                              ),
    .receive_en             (band_receive_en                                 ),
    .packet_valid           (packet_valid && packet_ready && route_band      ),
    .packet_ready           (band_packet_ready                               ),
    .req_cmd                (req_cmd                                         ),
    .req_id                 (req_id                                          ),
    .req_seq                (req_seq                                         ),
    .req_length             (req_length                                      ),
    .req_crc                (req_crc                                         ),
    .rx_rd_addr             (band_rx_rd_addr                                 ),
    .rx_rd_data             (rx_rd_data                                      ),
    .result_wr_en           (band_result_wr_en                               ),
    .result_wr_addr         (band_result_wr_addr                             ),
    .result_wr_data         (band_result_wr_data                             ),
    .resp_valid             (band_resp_valid                                 ),
    .resp_ready             (resp_ready && owner_kind == 2'd2                ),
    .resp_cmd               (band_resp_cmd                                   ),
    .resp_id                (band_resp_id                                    ),
    .resp_seq               (band_resp_seq                                   ),
    .resp_length            (band_resp_length                                ),
    .resp_addr              (resp_addr                                       ),
    .result_rd_data         (result_rd_data                                  ),
    .resp_data              (band_resp_data                                  ),
    .resp_done              (resp_done && owner_kind == 2'd2                 )
);

endmodule
