//--------------------------------------------------------------------------------------------------------
// 模块： img_packet_tx_fast
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 一拍RAM预取、两字节弹性缓冲及连续字节应用包CRC组装
// 作者： WANG
// 时间： 26.10.22
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  img_packet_tx_fast
(
    input   wire                   sys_clk                ,
    input   wire                   sys_rst_n              ,
    input   wire                   start_valid            ,
    output  wire                   start_ready            ,
    input   wire           [7:0]   cmd                    ,
    input   wire           [15:0]  transfer_id            ,
    input   wire           [15:0]  seq                    ,
    input   wire           [15:0]  length                 ,
    output  wire           [9:0]   payload_addr           ,
    input   wire           [7:0]   payload_data           , //地址后一拍返回
    output  reg            [7:0]   byte_data              ,
    output  wire                   byte_valid             ,
    input   wire                   byte_ready             ,
    output  reg                    done_flag
);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//parameter define
localparam [2:0] IDLE = 3'd0;
localparam [2:0] HEADER = 3'd1;
localparam [2:0] PAYLOAD = 3'd2;
localparam [2:0] CRC_LO = 3'd3;
localparam [2:0] CRC_HI = 3'd4;
localparam [2:0] DRAIN = 3'd5;
localparam [3:0] HEADER_LAST = 4'd11;

//wire  define
wire                   start_accept;
wire                   byte_accept;
wire                   payload_pop;
wire                   issue_en;
wire                   payload_end;
wire           [2:0]   reserved_count;

//reg   define
reg            [2:0]   state;
reg            [2:0]   next_state;
reg            [3:0]   header_cnt;
reg            [9:0]   payload_cnt;
reg            [10:0]  fetch_count;
reg                    pending_valid;
reg            [1:0]   fifo_count;
reg            [7:0]   first_data;
reg            [7:0]   second_data;
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
    reg            [15:0]  work;
    begin
        work = initial_crc ^ {value, 8'd0};
        for(k = 0; k < 8; k = k + 1)
            work = work[15] ? (work << 1) ^ 16'h1021 : work << 1;
        crc_byte = work;
    end
endfunction

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
assign start_ready = (state == IDLE);
assign start_accept = start_valid && start_ready;
assign payload_addr = fetch_count[9:0];
assign byte_valid = (state == HEADER || state == CRC_LO || state == CRC_HI)
                   || (state == PAYLOAD && fifo_count != 2'd0);
assign byte_accept = byte_valid && byte_ready;
assign payload_pop = (state == PAYLOAD) && byte_accept;
assign payload_end = ({6'd0, payload_cnt} + 16'd1 == len_reg);
assign reserved_count = {1'b0, fifo_count} + {2'd0, pending_valid} - {2'd0, payload_pop};
assign issue_en = (state == HEADER || state == PAYLOAD) && {5'd0, fetch_count} < len_reg
                  && reserved_count < 3'd2;

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
            next_state = (len_reg == 16'd0) ? CRC_LO : PAYLOAD;
        PAYLOAD: if(payload_pop && payload_end) next_state = CRC_LO;
        CRC_LO: if(byte_accept) next_state = CRC_HI;
        CRC_HI: if(byte_accept) next_state = DRAIN;
        DRAIN: if(byte_ready) next_state = IDLE;
        default: next_state = IDLE;
    endcase
end

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0) begin
        cmd_reg <= 8'd0;
        id_reg <= 16'd0;
        seq_reg <= 16'd0;
        len_reg <= 16'd0;
    end else if(start_accept) begin
        cmd_reg <= cmd;
        id_reg <= transfer_id;
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
    else if(payload_pop && !payload_end)
        payload_cnt <= payload_cnt + 1'b1;

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        fetch_count <= 11'd0;
    else if(start_accept)
        fetch_count <= 11'd0;
    else if(issue_en)
        fetch_count <= fetch_count + 1'b1;

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        pending_valid <= 1'b0;
    else
        pending_valid <= issue_en;

//在途读取占用一个预留位置，保证突发反压时不会覆盖尚未消费的数据
always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        fifo_count <= 2'd0;
    else if(start_accept)
        fifo_count <= 2'd0;
    else
        fifo_count <= fifo_count + {1'b0, pending_valid} - {1'b0, payload_pop};

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0) begin
        first_data <= 8'd0;
        second_data <= 8'd0;
    end else if(pending_valid) begin
        if(fifo_count == 2'd0 || (payload_pop && fifo_count == 2'd1))
            first_data <= payload_data;
        else if(payload_pop) begin
            first_data <= second_data;
            second_data <= payload_data;
        end else
            second_data <= payload_data;
    end else if(payload_pop)
        first_data <= second_data;

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        crc <= 16'hffff;
    else if(start_accept)
        crc <= 16'hffff;
    else if(byte_accept && ((state == HEADER && header_cnt >= 4'd4) || state == PAYLOAD))
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
            4'd0: byte_data = 8'h55;
            4'd1: byte_data = 8'haa;
            4'd2: byte_data = 8'h5a;
            4'd3: byte_data = 8'ha5;
            4'd4: byte_data = 8'd1;
            4'd5: byte_data = cmd_reg;
            4'd6: byte_data = id_reg[7:0];
            4'd7: byte_data = id_reg[15:8];
            4'd8: byte_data = seq_reg[7:0];
            4'd9: byte_data = seq_reg[15:8];
            4'd10: byte_data = len_reg[7:0];
            4'd11: byte_data = len_reg[15:8];
            default: byte_data = 8'd0;
        endcase
        PAYLOAD: byte_data = first_data;
        CRC_LO: byte_data = crc[7:0];
        CRC_HI: byte_data = crc[15:8];
        default: byte_data = 8'd0;
    endcase
end

endmodule
