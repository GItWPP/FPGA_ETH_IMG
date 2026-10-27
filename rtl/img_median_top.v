//--------------------------------------------------------------------------------------------------------
// 模块： img_median_top
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 彩色中值滤波顶层，三个分量复用独立排序子模块
// 作者： WANG
// 时间： 26.10.21
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  img_median_top
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
localparam [2:0] IDLE = 3'd0;
localparam [2:0] SEND = 3'd1;
localparam [2:0] WAIT_MEDIAN = 3'd2;
localparam [2:0] RESULT = 3'd3;
//wire  define
wire                    accept_flag;
wire                    sort_ready;
wire                    sort_valid;
wire           [7:0]    sort_data;
wire           [71:0]   channel_data;
//reg   define
reg            [2:0]    state;
reg            [2:0]    next_state;
reg            [1:0]    channel_index;
reg            [143:0]  window_reg;
reg            [4:0]    red;
reg            [5:0]    green;
reg            [4:0]    blue;
genvar sample_index;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
assign in_ready = (state == IDLE) && (!out_valid || out_ready);
assign accept_flag = in_valid && in_ready;

generate
    for(sample_index = 0; sample_index < 9; sample_index = sample_index + 1) begin: channel_select
        assign channel_data[sample_index * 8 +: 8] = (channel_index == 2'd0)
            ? {3'd0, window_reg[sample_index * 16 + 11 +: 5]}
            : ((channel_index == 2'd1) ? {2'd0, window_reg[sample_index * 16 + 5 +: 6]}
                                      : {3'd0, window_reg[sample_index * 16 +: 5]});
    end
endgenerate

always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0)
        state <= IDLE;
    else
        state <= next_state;

always@(*) begin
    next_state = state;
    case(state)
        IDLE: if(accept_flag) next_state = SEND;
        SEND: if(sort_ready) next_state = WAIT_MEDIAN;
        WAIT_MEDIAN: if(sort_valid) next_state = (channel_index == 2'd2) ? RESULT : SEND;
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
        channel_index <= 2'd0;
    else if(accept_flag)
        channel_index <= 2'd0;
    else if(state == WAIT_MEDIAN && sort_valid && channel_index != 2'd2)
        channel_index <= channel_index + 1'b1;

always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0) begin
        red <= 5'd0;
        green <= 6'd0;
        blue <= 5'd0;
    end else if(state == WAIT_MEDIAN && sort_valid)
        case(channel_index)
            2'd0: red <= sort_data[4:0];
            2'd1: green <= sort_data[5:0];
            2'd2: blue <= sort_data[4:0];
            default: blue <= 5'd0;
        endcase
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
        out_data <= {red, green, blue};

//********************************************************************//
//*************************** Instantiation **************************//
//********************************************************************//
img_sort9
img_sort9_inst
(
    .sys_clk               (sys_clk               ),
    .sys_rst_n             (sys_rst_n             ),
    .in_data               (channel_data          ),
    .in_valid              (state == SEND         ),
    .in_ready              (sort_ready            ),
    .out_data              (sort_data             ),
    .out_valid             (sort_valid            ),
    .out_ready             (state == WAIT_MEDIAN  )
);
endmodule
