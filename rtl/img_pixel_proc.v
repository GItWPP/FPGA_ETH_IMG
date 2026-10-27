//--------------------------------------------------------------------------------------------------------
// 模块： img_pixel_proc
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 八种独立算法的模式路由与单事务握手仲裁，不包含算法运算
// 作者： WANG
// 时间： 26.10.21
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  img_pixel_proc
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
    input   wire                    out_ready
);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//wire  define
wire           [7:0]    ready_bus;
wire           [7:0]    valid_bus;
wire           [7:0]    output_ready;
wire           [127:0]  result_bus;
wire                    accept_flag;
wire                    slot_available;
//reg   define
reg                     active;
reg            [2:0]    active_mode;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
//模式只在输入握手时锁存，反压期间不受外部mode变化影响
assign slot_available = !active || (out_valid && out_ready);
assign in_ready = slot_available && ready_bus[mode];
assign accept_flag = in_valid && in_ready;
assign out_valid = active && valid_bus[active_mode];
assign out_data = result_bus[active_mode * 16 +: 16];
assign output_ready = active ? ((8'b0000_0001 << active_mode) & {8{out_ready}}) : 8'd0;

always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0)
        active <= 1'b0;
    else if(accept_flag)
        active <= 1'b1;
    else if(out_valid && out_ready)
        active <= 1'b0;

always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0)
        active_mode <= 3'd0;
    else if(accept_flag)
        active_mode <= mode;

//********************************************************************//
//*************************** Instantiation **************************//
//********************************************************************//
img_copy_top
img_copy_top_inst
(
    .sys_clk               (sys_clk               ),
    .sys_rst_n             (sys_rst_n             ),
    .in_data               (in_data               ),
    .in_valid              (in_valid && slot_available && mode == 3'd0),
    .in_ready              (ready_bus[0]          ),
    .out_data              (result_bus[0 +: 16]   ),
    .out_valid             (valid_bus[0]          ),
    .out_ready             (output_ready[0]       )
);

img_gray_top
img_gray_top_inst
(
    .sys_clk               (sys_clk               ),
    .sys_rst_n             (sys_rst_n             ),
    .in_data               (in_data               ),
    .in_valid              (in_valid && slot_available && mode == 3'd1),
    .in_ready              (ready_bus[1]          ),
    .out_data              (result_bus[16 +: 16]  ),
    .out_valid             (valid_bus[1]          ),
    .out_ready             (output_ready[1]       )
);

img_invert_top
img_invert_top_inst
(
    .sys_clk               (sys_clk               ),
    .sys_rst_n             (sys_rst_n             ),
    .in_data               (in_data               ),
    .in_valid              (in_valid && slot_available && mode == 3'd2),
    .in_ready              (ready_bus[2]          ),
    .out_data              (result_bus[32 +: 16]  ),
    .out_valid             (valid_bus[2]          ),
    .out_ready             (output_ready[2]       )
);

img_mean_top
img_mean_top_inst
(
    .sys_clk               (sys_clk               ),
    .sys_rst_n             (sys_rst_n             ),
    .window_data           (window_data           ),
    .in_valid              (in_valid && slot_available && mode == 3'd3),
    .in_ready              (ready_bus[3]          ),
    .out_data              (result_bus[48 +: 16]  ),
    .out_valid             (valid_bus[3]          ),
    .out_ready             (output_ready[3]       )
);

img_median_top
img_median_top_inst
(
    .sys_clk               (sys_clk               ),
    .sys_rst_n             (sys_rst_n             ),
    .window_data           (window_data           ),
    .in_valid              (in_valid && slot_available && mode == 3'd4),
    .in_ready              (ready_bus[4]          ),
    .out_data              (result_bus[64 +: 16]  ),
    .out_valid             (valid_bus[4]          ),
    .out_ready             (output_ready[4]       )
);

img_sobel_top
img_sobel_top_inst
(
    .sys_clk               (sys_clk               ),
    .sys_rst_n             (sys_rst_n             ),
    .window_data           (window_data           ),
    .in_valid              (in_valid && slot_available && mode == 3'd5),
    .in_ready              (ready_bus[5]          ),
    .out_data              (result_bus[80 +: 16]  ),
    .out_valid             (valid_bus[5]          ),
    .out_ready             (output_ready[5]       )
);

img_gamma_top
img_gamma_top_inst
(
    .sys_clk               (sys_clk               ),
    .sys_rst_n             (sys_rst_n             ),
    .in_data               (in_data               ),
    .in_valid              (in_valid && slot_available && mode == 3'd6),
    .in_ready              (ready_bus[6]          ),
    .out_data              (result_bus[96 +: 16]  ),
    .out_valid             (valid_bus[6]          ),
    .out_ready             (output_ready[6]       )
);

img_sharpen_top
img_sharpen_top_inst
(
    .sys_clk               (sys_clk               ),
    .sys_rst_n             (sys_rst_n             ),
    .window_data           (window_data           ),
    .in_valid              (in_valid && slot_available && mode == 3'd7),
    .in_ready              (ready_bus[7]          ),
    .out_data              (result_bus[112 +: 16] ),
    .out_valid             (valid_bus[7]          ),
    .out_ready             (output_ready[7]       )
);
endmodule
