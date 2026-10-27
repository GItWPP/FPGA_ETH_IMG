//--------------------------------------------------------------------------------------------------------
// 模块： img_process_top
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 图像处理系统顶层，独立图像算法选择器及HOG检测算法互连
// 作者： WANG
// 时间： 26.10.21
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  img_process_top
(
    input   wire                    sys_clk                ,
    input   wire                    sys_rst_n              ,
    input   wire           [2:0]    mode                   ,
    input   wire           [143:0]  window_data            ,
    input   wire           [15:0]   in_data                ,
    input   wire                    in_valid               ,
    output  wire                    in_ready               ,

    output  wire           [15:0]   out_data               ,
    output  wire                    out_valid              ,
    input   wire                    out_ready              ,
    input   wire                    hog_frame_wr_en        ,
    input   wire           [16:0]   hog_frame_wr_addr      ,
    input   wire           [7:0]    hog_frame_wr_data      ,
    input   wire                    hog_start_valid        ,
    output  wire                    hog_start_ready        ,
    output  wire                    hog_done_flag          ,
    input   wire           [8:0]    hog_score_rd_addr      ,
    output  wire           [31:0]   hog_score_rd_data      ,
    output  wire           [31:0]   hog_model_id
);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//wire  define

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
//各算法在子模块内完成，顶层保持纯互连结构

//********************************************************************//
//*************************** Instantiation **************************//
//********************************************************************//
img_pixel_proc
img_pixel_proc_inst
(
    .sys_clk               (sys_clk               ),
    .sys_rst_n             (sys_rst_n             ),
    .mode                  (mode                  ),
    .window_data           (window_data           ),
    .in_data               (in_data               ),
    .in_valid              (in_valid              ),
    .in_ready              (in_ready              ),
    .out_data              (out_data              ),
    .out_valid             (out_valid             ),
    .out_ready             (out_ready             )
);

hog_detect_top
hog_detect_top_inst
(
    .sys_clk               (sys_clk               ),
    .sys_rst_n             (sys_rst_n             ),
    .frame_wr_en           (hog_frame_wr_en       ),
    .frame_wr_addr         (hog_frame_wr_addr     ),
    .frame_wr_data         (hog_frame_wr_data     ),
    .start_valid           (hog_start_valid       ),
    .start_ready           (hog_start_ready       ),
    .done_flag             (hog_done_flag         ),
    .score_rd_addr         (hog_score_rd_addr     ),
    .score_rd_data         (hog_score_rd_data     ),
    .model_id              (hog_model_id          )
);
endmodule
