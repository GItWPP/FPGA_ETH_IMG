//--------------------------------------------------------------------------------------------------------
// 模块： uart_rx
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 分数计时的8N1接收，确认起始位并检查停止位
// 作者： WANG
// 时间： 26.10.21
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  uart_rx
#(
    parameter integer CLK_HZ   = 50_000_000,
    parameter integer UART_BPS = 1_500_000
)
(
    input   wire                   sys_clk                ,   //系统时钟
    input   wire                   sys_rst_n              ,   //低有效复位
    input   wire                   rx                     ,   //异步串口输入

    output  reg            [7:0]   data                   ,   //接收字节
    output  reg                    data_flag              ,   //接收完成脉冲
    output  reg                    error_flag             //停止位错误脉冲
);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//parameter define
localparam [1:0] IDLE  = 2'd0;
localparam [1:0] START = 2'd1;
localparam [1:0] BITS  = 2'd2;
localparam [1:0] STOP  = 2'd3;

//wire  define
wire                   start_nedge;
wire                   bit_tick;

//reg   define
(* ASYNC_REG = "TRUE" *) reg rx_meta;
(* ASYNC_REG = "TRUE" *) reg rx_sync;
reg                    rx_dly;
reg            [1:0]   state;
reg            [1:0]   next_state;
reg            [31:0]  phase;
reg            [2:0]   bit_cnt;
reg            [7:0]   shift_data;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
assign start_nedge = rx_dly && !rx_sync;
assign bit_tick    = (phase >= CLK_HZ - UART_BPS);

//rx_meta,rx_sync:两级同步；rx_dly用于检测同步后的起始下降沿
always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0) begin
        rx_meta <= 1'b1;
        rx_sync <= 1'b1;
        rx_dly  <= 1'b1;
    end else begin
        rx_meta <= rx;
        rx_sync <= rx_meta;
        rx_dly  <= rx_sync;
    end

//state:状态寄存器与采样、计数逻辑分离
always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0)
        state <= IDLE;
    else
        state <= next_state;

always@(*) begin
    next_state = state;
    case(state)
        IDLE:  if(start_nedge) next_state = START;
        START: if(bit_tick) next_state = rx_sync ? IDLE : BITS;
        BITS:  if(bit_tick && bit_cnt == 3'd7) next_state = STOP;
        STOP:  if(bit_tick) next_state = IDLE;
        default: next_state = IDLE;
    endcase
end

//phase:起始沿后等待半位，其后保留33/34周期分数余量
always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0)
        phase <= 32'd0;
    else if(state == IDLE) begin
        if(start_nedge)
            phase <= CLK_HZ / 2;
    end else if(bit_tick)
        phase <= phase + UART_BPS - CLK_HZ;
    else
        phase <= phase + UART_BPS;

//bit_cnt:数据位中心采样位置
always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0)
        bit_cnt <= 3'd0;
    else if(state == START && bit_tick && !rx_sync)
        bit_cnt <= 3'd0;
    else if(state == BITS && bit_tick && bit_cnt != 3'd7)
        bit_cnt <= bit_cnt + 1'b1;

always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0)
        shift_data <= 8'd0;
    else if(state == BITS && bit_tick)
        shift_data[bit_cnt] <= rx_sync;

//data与完成脉冲在合法停止位的采样边沿对齐
always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0) begin
        data       <= 8'd0;
        data_flag  <= 1'b0;
        error_flag <= 1'b0;
    end else begin
        data_flag  <= (state == STOP && bit_tick && rx_sync);
        error_flag <= (state == STOP && bit_tick && !rx_sync);
        if(state == STOP && bit_tick && rx_sync)
            data <= shift_data;
    end

endmodule
