//--------------------------------------------------------------------------------------------------------
// 模块： img_mean_top
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 彩色3x3均值滤波顶层，九次分时累加
// 作者： WANG
// 时间： 26.10.21
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  img_mean_top
(
    input   wire                    sys_clk                ,
    input   wire                    sys_rst_n              ,
    input   wire           [143:0]  window_data            ,
    input   wire                    in_valid               ,
    output  wire                    in_ready               ,

    output  reg            [15:0]   out_data               ,
    output  reg                     out_valid              ,
    input   wire                    out_ready
);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//parameter define
localparam [1:0] IDLE = 2'd0;
localparam [1:0] LOAD = 2'd1;
localparam [1:0] RESULT = 2'd2;

//wire  define
wire                    accept_flag;
wire           [15:0]   sample_pixel;
wire           [11:0]   average_red;
wire           [11:0]   average_green;
wire           [11:0]   average_blue;

//reg   define
reg            [1:0]    state;
reg            [1:0]    next_state;
reg            [143:0]  window_reg;
reg            [3:0]    sample_index;
reg            [11:0]   sum_red;
reg            [11:0]   sum_green;
reg            [11:0]   sum_blue;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
assign in_ready = (state == IDLE) && (!out_valid || out_ready);
assign accept_flag = in_valid && in_ready;
assign sample_pixel = window_reg[sample_index * 16 +: 16];

always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0)
        state <= IDLE;
    else
        state <= next_state;

always@(*) begin
    next_state = state;
    case(state)
        IDLE: if(accept_flag) next_state = LOAD;
        LOAD: if(sample_index == 4'd8) next_state = RESULT;
        RESULT: next_state = IDLE;
        default: next_state = IDLE;
    endcase
end
always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0)
        window_reg <= 144'd0;
    else if(accept_flag)
        window_reg <= window_data;

always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0)
        sample_index <= 4'd0;
    else if(accept_flag)
        sample_index <= 4'd0;
    else if(state == LOAD && sample_index != 4'd8)
        sample_index <= sample_index + 1'b1;

assign average_red = sum_red / 12'd9;
assign average_green = sum_green / 12'd9;
assign average_blue = sum_blue / 12'd9;

//累加与状态转移独立，三分量分别保持原生RGB565位宽含义
always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0) begin
        sum_red <= 12'd0;
        sum_green <= 12'd0;
        sum_blue <= 12'd0;
    end else if(accept_flag) begin
        sum_red <= 12'd0;
        sum_green <= 12'd0;
        sum_blue <= 12'd0;
    end else if(state == LOAD) begin
        sum_red <= sum_red + {7'd0, sample_pixel[15:11]};
        sum_green <= sum_green + {6'd0, sample_pixel[10:5]};
        sum_blue <= sum_blue + {7'd0, sample_pixel[4:0]};
    end
always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0)
        out_valid <= 1'b0;
    else if(state == RESULT)
        out_valid <= 1'b1;
    else if(out_ready)
        out_valid <= 1'b0;

always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0)
        out_data <= 16'd0;
    else if(state == RESULT)
        out_data <= {average_red[4:0], average_green[5:0], average_blue[4:0]};

endmodule
