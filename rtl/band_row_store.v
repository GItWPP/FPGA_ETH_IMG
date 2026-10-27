//--------------------------------------------------------------------------------------------------------
// 模块： band_row_store
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 暗点列表缓存、相邻扫描行聚合及有限长行描述符存储
// 作者： WANG
// 时间： 26.10.21
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  band_row_store
(
    input   wire            sys_clk        ,
    input   wire            sys_rst_n      ,
    input   wire            clear_flag     ,
    input   wire            dot_valid      ,
    input   wire    [8:0]   dot_x          ,
    input   wire    [8:0]   dot_y          ,
    input   wire    [7:0]   dot_contrast   ,
    input   wire            scan_done_flag ,
    output  reg             done_flag      ,
    output  reg             overflow_flag  ,
    output  reg     [11:0]  dot_count      ,
    output  reg     [6:0]   row_count      ,

    input   wire    [10:0]  dot_rd_addr    ,
    output  reg     [25:0]  dot_rd_data    ,
    input   wire    [5:0]   row_rd_addr    ,
    output  reg     [43:0]  row_rd_data
);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//wire  define
wire                    new_row_flag;
wire                    commit_flag;
//reg   define
(* ram_style = "block" *) reg [25:0] dot_mem [0:2047];
(* ram_style = "distributed" *) reg [43:0] row_mem [0:63];
reg            [10:0]   group_start;
reg            [11:0]   group_count;
reg            [20:0]   group_sum_y;
reg            [8:0]    last_y;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
assign new_row_flag = dot_valid && group_count != 12'd0 && {1'b0, dot_y} > {1'b0, last_y} + 10'd5;
assign commit_flag = (new_row_flag || scan_done_flag) && group_count >= 12'd5;

//数据RAM不复位，仅控制计数和有效性复位
always@(posedge sys_clk) begin
    if(dot_valid && dot_count < 12'd2048)
        dot_mem[dot_count[10:0]] <= {dot_contrast, dot_y, dot_x};
    dot_rd_data <= dot_mem[dot_rd_addr];
end

always@(posedge sys_clk) begin
    if(commit_flag && row_count < 7'd64)
        row_mem[row_count[5:0]] <= {group_sum_y, group_count, group_start};
    row_rd_data <= row_mem[row_rd_addr];
end

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        done_flag <= 1'b0;
    else
        done_flag <= scan_done_flag;

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0) begin
        dot_count <= 12'd0;
        row_count <= 7'd0;
        overflow_flag <= 1'b0;
    end else if(clear_flag) begin
        dot_count <= 12'd0;
        row_count <= 7'd0;
        overflow_flag <= 1'b0;
    end else begin
        if(dot_valid) begin
            if(dot_count < 12'd2048)
                dot_count <= dot_count + 1'b1;
            else
                overflow_flag <= 1'b1;
        end
        if(commit_flag) begin
            if(row_count < 7'd64)
                row_count <= row_count + 1'b1;
            else
                overflow_flag <= 1'b1;
        end
    end

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0) begin
        group_start <= 11'd0;
        group_count <= 12'd0;
        group_sum_y <= 21'd0;
        last_y <= 9'd0;
    end else if(clear_flag) begin
        group_start <= 11'd0;
        group_count <= 12'd0;
        group_sum_y <= 21'd0;
        last_y <= 9'd0;
    end else if(dot_valid) begin
        last_y <= dot_y;
        if(group_count == 12'd0 || new_row_flag) begin
            group_start <= dot_count[10:0];
            group_count <= 12'd1;
            group_sum_y <= {12'd0, dot_y};
        end else if(group_count < 12'd2048) begin
            group_count <= group_count + 1'b1;
            group_sum_y <= group_sum_y + {12'd0, dot_y};
        end
    end

endmodule
