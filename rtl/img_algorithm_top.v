//--------------------------------------------------------------------------------------------------------
// 模块： img_algorithm_top
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 单时钟算法域封装，图像、HOG和Band保持各自独立模块
// 作者： WANG
// 时间： 26.10.23
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  img_algorithm_top
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
    output  wire                    copy_response
);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//wire  define
wire           [2:0]    pixel_mode;
wire           [15:0]   pixel_in_data;
wire           [143:0]  pixel_window_data;
wire           [15:0]   pixel_out_data;
wire                    pixel_in_valid;
wire                    pixel_in_ready;
wire                    pixel_out_valid;
wire                    pixel_out_ready;
wire                    hog_frame_wr_en;
wire           [16:0]   hog_frame_wr_addr;
wire           [7:0]    hog_frame_wr_data;
wire                    hog_start_valid;
wire                    hog_start_ready;
wire                    hog_done_flag;
wire           [8:0]    hog_score_rd_addr;
wire           [31:0]   hog_score_rd_data;
wire           [31:0]   hog_model_id;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
// 命令分发和像素算法共用同一时钟，跨域握手由外层桥接模块完成

//********************************************************************//
//*************************** Instantiation **************************//
//********************************************************************//
img_process_top
img_process_top_inst
(
    .sys_clk                (sys_clk                                         ),
    .sys_rst_n              (sys_rst_n                                           ),

    .mode                   (pixel_mode                                      ),
    .in_data                (pixel_in_data                                   ),
    .window_data            (pixel_window_data                               ),
    .in_valid               (pixel_in_valid                                  ),
    .in_ready               (pixel_in_ready                                  ),
    .out_data               (pixel_out_data                                  ),
    .out_valid              (pixel_out_valid                                 ),
    .out_ready              (pixel_out_ready                                 ),
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

img_command_top
#(
    .MAX_WIDTH              (MAX_WIDTH                                       ),
    .MAX_HEIGHT             (MAX_HEIGHT                                      ),
    .FAST_COPY              (FAST_COPY                                       ),
    .EXTERNAL_COPY          (EXTERNAL_COPY                                   )
)
img_ctrl_inst
(
    .sys_clk                (sys_clk                                         ),
    .sys_rst_n              (sys_rst_n                                           ),

    .receive_en             (receive_en                                  ),
    .packet_valid           (packet_valid                                ),
    .packet_ready           (packet_ready                                ),
    .req_cmd                (req_cmd                                         ),
    .req_id                 (req_id                                          ),
    .req_seq                (req_seq                                         ),
    .req_length             (req_length                                      ),
    .req_crc                (req_crc                                         ),
    .rx_rd_addr             (rx_rd_addr                                      ),
    .rx_rd_data             (rx_rd_data                                      ),
    .result_wr_en           (result_wr_en                                    ),
    .result_wr_addr         (result_wr_addr                                  ),
    .result_wr_data         (result_wr_data                                  ),
    .pixel_mode             (pixel_mode                                      ),
    .pixel_in_data          (pixel_in_data                                   ),
    .pixel_window_data      (pixel_window_data                               ),
    .pixel_in_valid         (pixel_in_valid                                  ),
    .pixel_in_ready         (pixel_in_ready                                  ),
    .pixel_out_data         (pixel_out_data                                  ),
    .pixel_out_valid        (pixel_out_valid                                 ),
    .pixel_out_ready        (pixel_out_ready                                 ),
    .resp_valid             (resp_valid                                  ),
    .resp_ready             (resp_ready                                  ),
    .resp_cmd               (resp_cmd                                    ),
    .resp_id                (resp_id                                     ),
    .resp_seq               (resp_seq                                    ),
    .resp_length            (resp_length                                 ),
    .resp_addr              (resp_addr                                       ),
    .result_rd_data         (result_rd_data                                  ),
    .resp_data              (resp_data                                   ),
    .resp_done              (resp_done                                   ),
    .hog_frame_wr_en        (hog_frame_wr_en                                 ),
    .hog_frame_wr_addr      (hog_frame_wr_addr                               ),
    .hog_frame_wr_data      (hog_frame_wr_data                               ),
    .hog_start_valid        (hog_start_valid                                 ),
    .hog_start_ready        (hog_start_ready                                 ),
    .hog_done_flag          (hog_done_flag                                   ),
    .hog_score_rd_addr      (hog_score_rd_addr                               ),
    .hog_score_rd_data      (hog_score_rd_data                               ),
    .hog_model_id           (hog_model_id                                    ),
    .copy_response          (copy_response                                   )
);
endmodule
