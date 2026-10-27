//--------------------------------------------------------------------------------------------------------
// 模块： img_packet_tx
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 从同步块缓存读取应答并添加包头与CRC，等待末停止位完成
// 作者： WANG
// 时间： 26.10.21
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  img_packet_tx
(
    input   wire                   sys_clk                ,
    input   wire                   sys_rst_n              ,
    input   wire                   start_valid            ,
    output  wire                   start_ready            ,
    input   wire           [7:0]   cmd                    ,
    input   wire           [15:0]  transfer_id            ,
    input   wire           [15:0]  seq                    ,
    input   wire           [15:0]  length                 ,

    output  wire           [9:0]   payload_addr           ,   //同步RAM读地址
    input   wire           [7:0]   payload_data           ,
    output  reg            [7:0]   byte_data              ,
    output  wire                   byte_valid             ,
    input   wire                   byte_ready             ,
    output  reg                    done_flag              //末字节停止位发送完成
);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//parameter define
localparam [2:0] IDLE     = 3'd0;
localparam [2:0] HEADER   = 3'd1;
localparam [2:0] PAY_ADDR = 3'd2;
localparam [2:0] PAY_WAIT = 3'd3;
localparam [2:0] PAY_SEND = 3'd4;
localparam [2:0] CRC_LO   = 3'd5;
localparam [2:0] CRC_HI   = 3'd6;
localparam [2:0] DRAIN    = 3'd7;
localparam [3:0] HEADER_LAST = 4'd11;

//wire  define
wire                   start_accept;
wire                   byte_accept;
wire                   payload_end;

//reg   define
reg            [2:0]   state;
reg            [2:0]   next_state;
reg            [3:0]   header_cnt;
reg            [9:0]   payload_cnt;
reg            [7:0]   cmd_reg;
reg            [15:0]  id_reg;
reg            [15:0]  seq_reg;
reg            [15:0]  len_reg;
reg            [15:0]  crc;

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
assign start_ready  = (state == IDLE);
assign start_accept = start_valid && start_ready;
assign payload_addr = payload_cnt;
assign byte_valid   = (state == HEADER || state == PAY_SEND || state == CRC_LO || state == CRC_HI);
assign byte_accept  = byte_valid && byte_ready;
assign payload_end  = ({6'd0, payload_cnt} + 16'd1 == len_reg);

//同步复位使BRAM读地址只在时钟边沿变化
always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        state <= IDLE;
    else
        state <= next_state;

always@(*) begin
    next_state = state;
    case(state)
        IDLE: if(start_accept) next_state = HEADER;
        HEADER: if(byte_accept && header_cnt == HEADER_LAST)
            next_state = (len_reg == 16'd0) ? CRC_LO : PAY_ADDR;
        PAY_ADDR: next_state = PAY_WAIT;
        PAY_WAIT: next_state = PAY_SEND;
        PAY_SEND: if(byte_accept) next_state = payload_end ? CRC_LO : PAY_ADDR;
        CRC_LO: if(byte_accept) next_state = CRC_HI;
        CRC_HI: if(byte_accept) next_state = DRAIN;
        DRAIN: if(byte_ready) next_state = IDLE;
        default: next_state = IDLE;
    endcase
end

//应答字段在开始握手时一次锁存
always@(posedge sys_clk)
    if(sys_rst_n == 1'b0) begin
        cmd_reg <= 8'd0;
        id_reg  <= 16'd0;
        seq_reg <= 16'd0;
        len_reg <= 16'd0;
    end else if(start_accept) begin
        cmd_reg <= cmd;
        id_reg  <= transfer_id;
        seq_reg <= seq;
        len_reg <= length;
    end

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        header_cnt <= 4'd0;
    else if(start_accept)
        header_cnt <= 4'd0;
    else if(state == HEADER && byte_accept && header_cnt != HEADER_LAST)
        header_cnt <= header_cnt + 1'b1;

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        payload_cnt <= 10'd0;
    else if(start_accept)
        payload_cnt <= 10'd0;
    else if(state == PAY_SEND && byte_accept && !payload_end)
        payload_cnt <= payload_cnt + 1'b1;

//串口反压期间保持状态、地址和输出字节，握手成功后才累计CRC
always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        crc <= 16'hffff;
    else if(start_accept)
        crc <= 16'hffff;
    else if(byte_accept && ((state == HEADER && header_cnt >= 4'd4) || state == PAY_SEND))
        crc <= crc_byte(crc, byte_data);

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        done_flag <= 1'b0;
    else
        done_flag <= (state == DRAIN && byte_ready);

always@(*) begin
    byte_data = 8'd0;
    case(state)
        HEADER: case(header_cnt)
            4'd0:  byte_data = 8'h55;
            4'd1:  byte_data = 8'haa;
            4'd2:  byte_data = 8'h5a;
            4'd3:  byte_data = 8'ha5;
            4'd4:  byte_data = 8'd1;
            4'd5:  byte_data = cmd_reg;
            4'd6:  byte_data = id_reg[7:0];
            4'd7:  byte_data = id_reg[15:8];
            4'd8:  byte_data = seq_reg[7:0];
            4'd9:  byte_data = seq_reg[15:8];
            4'd10: byte_data = len_reg[7:0];
            4'd11: byte_data = len_reg[15:8];
            default: byte_data = 8'd0;
        endcase
        PAY_SEND: byte_data = payload_data;
        CRC_LO:   byte_data = crc[7:0];
        CRC_HI:   byte_data = crc[15:8];
        default:  byte_data = 8'd0;
    endcase
end

endmodule
