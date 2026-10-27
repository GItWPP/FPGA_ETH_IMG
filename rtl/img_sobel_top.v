//--------------------------------------------------------------------------------------------------------
// 模块： img_sobel_top
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： Sobel边缘检测顶层，亮度转换与梯度输出分阶段
// 作者： WANG
// 时间： 26.10.21
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  img_sobel_top
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
wire           [7:0]    sample_gray;
wire    signed [11:0]   gradient_x;
wire    signed [11:0]   gradient_y;
wire           [11:0]   absolute_x;
wire           [11:0]   absolute_y;
wire           [12:0]   magnitude;
wire           [7:0]    edge_gray;

//reg   define
reg            [1:0]    state;
reg            [1:0]    next_state;
reg            [143:0]  window_reg;
reg            [3:0]    sample_index;
reg            [7:0]    gray_data [0:8];
integer reset_index;

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

//九个样本先转换为亮度，结果阶段计算有符号梯度和饱和幅值
always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0) begin
        for(reset_index = 0; reset_index < 9; reset_index = reset_index + 1)
            gray_data[reset_index] <= 8'd0;
    end else if(state == LOAD)
        gray_data[sample_index] <= sample_gray;

assign gradient_x = -$signed({4'd0, gray_data[0]}) + $signed({4'd0, gray_data[2]})
                  - ($signed({4'd0, gray_data[3]}) <<< 1) + ($signed({4'd0, gray_data[5]}) <<< 1)
                  - $signed({4'd0, gray_data[6]}) + $signed({4'd0, gray_data[8]});
assign gradient_y = -$signed({4'd0, gray_data[0]}) - ($signed({4'd0, gray_data[1]}) <<< 1)
                  - $signed({4'd0, gray_data[2]}) + $signed({4'd0, gray_data[6]})
                  + ($signed({4'd0, gray_data[7]}) <<< 1) + $signed({4'd0, gray_data[8]});
assign absolute_x = gradient_x[11] ? -gradient_x : gradient_x;
assign absolute_y = gradient_y[11] ? -gradient_y : gradient_y;
assign magnitude = {1'b0, absolute_x} + {1'b0, absolute_y};
assign edge_gray = magnitude > 13'd255 ? 8'hff : magnitude[7:0];
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
        out_data <= {edge_gray[7:3], edge_gray[7:2], edge_gray[7:3]};

//********************************************************************//
//*************************** Instantiation **************************//
//********************************************************************//
img_rgb565_luma
img_rgb565_luma_inst
(
    .in_data               (sample_pixel          ),
    .gray                  (sample_gray           )
);
endmodule
