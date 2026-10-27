//--------------------------------------------------------------------------------------------------------
// 模块： img_sort9
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 九个8位样本分时排序并输出中值，可独立复用
// 作者： WANG
// 时间： 26.10.21
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  img_sort9
(
    input   wire                   sys_clk                ,
    input   wire                   sys_rst_n              ,
    input   wire           [71:0]  in_data                ,
    input   wire                   in_valid               ,
    output  wire                   in_ready               ,
    output  reg            [7:0]   out_data               ,
    output  reg                    out_valid              ,
    input   wire                   out_ready
);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//parameter define
localparam [1:0] IDLE = 2'd0;
localparam [1:0] SORT = 2'd1;
localparam [1:0] RESULT = 2'd2;
//wire  define
wire                   accept_flag;
wire                   sort_end;
//reg   define
reg            [1:0]   state;
reg            [1:0]   next_state;
reg            [3:0]   sort_pass;
reg            [3:0]   sort_index;
reg            [7:0]   values [0:8];
integer index;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
assign in_ready = (state == IDLE) && (!out_valid || out_ready);
assign accept_flag = in_valid && in_ready;
assign sort_end = sort_pass == 4'd7 && sort_index == 4'd0;

always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0)
        state <= IDLE;
    else
        state <= next_state;

always@(*) begin
    next_state = state;
    case(state)
        IDLE: if(accept_flag) next_state = SORT;
        SORT: if(sort_end) next_state = RESULT;
        RESULT: next_state = IDLE;
        default: next_state = IDLE;
    endcase
end

always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0) begin
        sort_pass <= 4'd0;
        sort_index <= 4'd0;
    end else if(accept_flag) begin
        sort_pass <= 4'd0;
        sort_index <= 4'd0;
    end else if(state == SORT) begin
        if(sort_index == 4'd7 - sort_pass) begin
            sort_index <= 4'd0;
            if(!sort_end)
                sort_pass <= sort_pass + 1'b1;
        end else
            sort_index <= sort_index + 1'b1;
    end

//每拍一个相邻比较交换；所有数组写入由同一进程负责
always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0) begin
        for(index = 0; index < 9; index = index + 1)
            values[index] <= 8'd0;
    end else if(accept_flag) begin
        for(index = 0; index < 9; index = index + 1)
            values[index] <= in_data[index * 8 +: 8];
    end else if(state == SORT && values[sort_index] > values[sort_index + 1'b1]) begin
        values[sort_index] <= values[sort_index + 1'b1];
        values[sort_index + 1'b1] <= values[sort_index];
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
        out_data <= 8'd0;
    else if(state == RESULT)
        out_data <= values[4];

endmodule
