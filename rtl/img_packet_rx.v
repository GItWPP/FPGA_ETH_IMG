//--------------------------------------------------------------------------------------------------------
// 模块： img_packet_rx
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 包头同步、长度检查、CRC16及字节间超时，完整包校验后握手
// 作者： WANG
// 时间： 26.10.21
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  img_packet_rx
#(
    parameter integer MAX_PAYLOAD  = 1024,
    parameter integer TIMEOUT_CLKS = 5_000_000
)
(
    input   wire                   sys_clk                ,
    input   wire                   sys_rst_n              ,
    input   wire                   receive_en             ,   //控制器空闲时允许解析
    input   wire           [7:0]   byte_data              ,
    input   wire                   byte_flag              ,
    input   wire                   byte_error             ,

    output  reg                    buf_wr_en              ,
    output  reg            [9:0]   buf_wr_addr            ,
    output  reg            [7:0]   buf_wr_data            ,
    output  reg                    packet_valid           ,   //完整包校验后保持至握手
    input   wire                   packet_ready           ,
    output  reg            [7:0]   cmd                    ,
    output  reg            [15:0]  transfer_id            ,
    output  reg            [15:0]  seq                    ,
    output  reg            [15:0]  length                 ,
    output  reg            [15:0]  packet_crc
);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//parameter define
localparam [2:0] SYNC    = 3'd0;
localparam [2:0] HEADER  = 3'd1;
localparam [2:0] PAYLOAD = 3'd2;
localparam [2:0] CRC_LO  = 3'd3;
localparam [2:0] CRC_HI  = 3'd4;
localparam [7:0] MAGIC_0 = 8'h55;
localparam [7:0] MAGIC_1 = 8'haa;
localparam [7:0] MAGIC_2 = 8'h5a;
localparam [7:0] MAGIC_3 = 8'ha5;
localparam [7:0] VERSION = 8'd1;

//wire  define
wire                   abort_en;
wire                   consume_en;
wire                   partial_en;
wire                   timeout_end;
wire                   magic_end;
wire                   header_end;
wire                   payload_end;
wire                   crc_match;

//reg   define
reg            [2:0]   state;
reg            [2:0]   next_state;
reg            [1:0]   magic_cnt;
reg            [2:0]   header_cnt;
reg            [9:0]   payload_cnt;
reg            [7:0]   version;
reg            [7:0]   crc_low;
reg            [15:0]  crc;
reg            [31:0]  timeout_cnt;

//function define
function [15:0] crc_byte;
    input [15:0] initial_crc;
    input [7:0] value;
    integer k;
    reg            [15:0]  c;
    begin
        c = initial_crc ^ {value, 8'h00};
        for(k = 0; k < 8; k = k + 1)
            c = c[15] ? (c << 1) ^ 16'h1021 : c << 1;
        crc_byte = c;
    end
endfunction

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
assign abort_en    = !receive_en || byte_error;
assign consume_en  = !abort_en && !packet_valid && byte_flag;
assign partial_en  = (state != SYNC || magic_cnt != 2'd0);
assign timeout_end = !packet_valid && !byte_flag && partial_en
                   && (timeout_cnt == TIMEOUT_CLKS - 1);
assign magic_end   = (magic_cnt == 2'd3 && byte_data == MAGIC_3);
assign header_end  = (header_cnt == 3'd7);
assign payload_end = ({6'd0, payload_cnt} + 16'd1 == length);
assign crc_match   = ({byte_data, crc_low} == crc);

//BRAM地址和使能采用同步复位，防止复位沿异步改变存储器控制
always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        state <= SYNC;
    else
        state <= next_state;

always@(*) begin
    next_state = state;
    if(abort_en || timeout_end)
        next_state = SYNC;
    else if(consume_en)
        case(state)
            SYNC: if(magic_end) next_state = HEADER;
            HEADER: if(header_end) begin
                if({byte_data, length[7:0]} > MAX_PAYLOAD || version != VERSION)
                    next_state = SYNC;
                else if({byte_data, length[7:0]} == 16'd0)
                    next_state = CRC_LO;
                else
                    next_state = PAYLOAD;
            end
            PAYLOAD: if(payload_end) next_state = CRC_LO;
            CRC_LO: next_state = CRC_HI;
            CRC_HI: next_state = SYNC;
            default: next_state = SYNC;
        endcase
end

//magic_cnt:逐字节匹配包头，允许55重复出现时重新同步
always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        magic_cnt <= 2'd0;
    else if(abort_en || timeout_end)
        magic_cnt <= 2'd0;
    else if(consume_en && state == SYNC)
        case(magic_cnt)
            2'd0: magic_cnt <= (byte_data == MAGIC_0) ? 2'd1 : 2'd0;
            2'd1: if(byte_data == MAGIC_1) magic_cnt <= 2'd2;
                  else magic_cnt <= (byte_data == MAGIC_0) ? 2'd1 : 2'd0;
            2'd2: if(byte_data == MAGIC_2) magic_cnt <= 2'd3;
                  else magic_cnt <= (byte_data == MAGIC_0) ? 2'd1 : 2'd0;
            2'd3: magic_cnt <= (byte_data == MAGIC_0) ? 2'd1 : 2'd0;
            default: magic_cnt <= 2'd0;
        endcase

//timeout_cnt:按相邻字节间隔计时，已完成包等待握手时不计时
always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        timeout_cnt <= 32'd0;
    else if(abort_en || consume_en || timeout_end)
        timeout_cnt <= 32'd0;
    else if(!packet_valid) begin
        if(partial_en)
            timeout_cnt <= timeout_cnt + 1'b1;
        else
            timeout_cnt <= 32'd0;
    end

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        header_cnt <= 3'd0;
    else if(consume_en && state == SYNC && magic_end)
        header_cnt <= 3'd0;
    else if(consume_en && state == HEADER)
        header_cnt <= header_cnt + 1'b1;

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        payload_cnt <= 10'd0;
    else if(consume_en && state == HEADER && header_end)
        payload_cnt <= 10'd0;
    else if(consume_en && state == PAYLOAD && !payload_end)
        payload_cnt <= payload_cnt + 1'b1;

//协议字段与图像缓存分别写入，字段仅在HEADER状态更新
always@(posedge sys_clk)
    if(sys_rst_n == 1'b0) begin
        version     <= 8'd0;
        cmd         <= 8'd0;
        transfer_id <= 16'd0;
        seq         <= 16'd0;
        length      <= 16'd0;
    end else if(consume_en && state == HEADER)
        case(header_cnt)
            3'd0: version             <= byte_data;
            3'd1: cmd                 <= byte_data;
            3'd2: transfer_id[7:0]    <= byte_data;
            3'd3: transfer_id[15:8]   <= byte_data;
            3'd4: seq[7:0]            <= byte_data;
            3'd5: seq[15:8]           <= byte_data;
            3'd6: length[7:0]         <= byte_data;
            3'd7: length[15:8]        <= byte_data;
            default: version         <= 8'd0;
        endcase

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0) begin
        buf_wr_en   <= 1'b0;
        buf_wr_addr <= 10'd0;
        buf_wr_data <= 8'd0;
    end else begin
        buf_wr_en <= consume_en && state == PAYLOAD;
        if(consume_en && state == PAYLOAD) begin
            buf_wr_addr <= payload_cnt;
            buf_wr_data <= byte_data;
        end
    end

//crc:仅对VERSION至PAYLOAD累计，不包含MAGIC和接收到的CRC字段
always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        crc <= 16'hffff;
    else if(consume_en) begin
        if(state == SYNC && magic_end)
            crc <= 16'hffff;
        else if(state == HEADER || state == PAYLOAD)
            crc <= crc_byte(crc, byte_data);
    end

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        crc_low <= 8'd0;
    else if(consume_en && state == CRC_LO)
        crc_low <= byte_data;

//packet_valid:完整校验通过后保持，控制器握手后撤销
always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        packet_valid <= 1'b0;
    else if(abort_en)
        packet_valid <= 1'b0;
    else if(packet_valid && packet_ready)
        packet_valid <= 1'b0;
    else if(consume_en && state == CRC_HI && crc_match)
        packet_valid <= 1'b1;

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        packet_crc <= 16'd0;
    else if(consume_en && state == CRC_HI && crc_match)
        packet_crc <= crc;

endmodule
