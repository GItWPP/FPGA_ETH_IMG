//--------------------------------------------------------------------------------------------------------
// 模块： eth_mac_tx
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： GMII以太网帧、最短帧补零、CRC32及帧间隔生成
// 作者： WANG
// 时间： 26.10.22
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ps

module  eth_mac_tx
(
    input   wire                   tx_clk                 ,
    input   wire                   tx_rst_n               ,
    input   wire                   frame_req_valid        ,
    output  wire                   frame_req_ready        ,
    input   wire           [47:0]  frame_dst_mac          ,
    input   wire           [47:0]  frame_src_mac          ,
    input   wire           [15:0]  frame_eth_type         ,
    input   wire           [15:0]  frame_payload_length   ,
    input   wire                   payload_valid          ,
    output  wire                   payload_ready          ,
    input   wire           [7:0]   payload_data           ,
    input   wire                   payload_last           ,
    output  wire                   tx_busy                ,
    output  reg                    tx_done                ,
    output  reg                    gmii_tx_en             ,
    output  reg                    gmii_tx_er             ,
    output  reg            [7:0]   gmii_txd
);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//

//parameter define
localparam ST_IDLE = 3'd0;
localparam ST_PREAMBLE = 3'd1;
localparam ST_HEADER = 3'd2;
localparam ST_PAYLOAD = 3'd3;
localparam ST_PAD = 3'd4;
localparam ST_FCS = 3'd5;
localparam ST_IFG = 3'd6;
//wire  define
wire           [7:0]   current_header_byte;
wire           [31:0]  fcs_value;
//reg   define
reg            [2:0]   state;
reg            [47:0]  dst_mac_reg;
reg            [47:0]  src_mac_reg;
reg            [15:0]  eth_type_reg;
reg            [15:0]  payload_length_reg;
reg            [3:0]   byte_count;
reg            [15:0]  payload_count;
reg            [15:0]  pad_count;
reg            [1:0]   fcs_count;
reg            [3:0]   ifg_count;
reg            [31:0]  crc_reg;

function [31:0] crc32_byte;
    input   [31:0] crc_in;
    input   [7:0] data_in;
    integer bit_index;
    reg            [31:0]  crc_work;
    begin
        crc_work = crc_in;
        for(bit_index=0; bit_index<8; bit_index=bit_index+1) begin
            if(crc_work[0] ^ data_in[bit_index]) crc_work = (crc_work >> 1) ^ 32'hedb88320;
            else crc_work = crc_work >> 1;
        end
        crc32_byte = crc_work;
    end
endfunction

function [7:0] header_byte;
    input   [3:0] index;
    input   [47:0] dst_mac;
    input   [47:0] src_mac;
    input   [15:0] eth_type;
    begin
        case(index)
            4'd0: header_byte = dst_mac[47:40];
            4'd1: header_byte = dst_mac[39:32];
            4'd2: header_byte = dst_mac[31:24];
            4'd3: header_byte = dst_mac[23:16];
            4'd4: header_byte = dst_mac[15:8];
            4'd5: header_byte = dst_mac[7:0];
            4'd6: header_byte = src_mac[47:40];
            4'd7: header_byte = src_mac[39:32];
            4'd8: header_byte = src_mac[31:24];
            4'd9: header_byte = src_mac[23:16];
            4'd10: header_byte = src_mac[15:8];
            4'd11: header_byte = src_mac[7:0];
            4'd12: header_byte = eth_type[15:8];
            4'd13: header_byte = eth_type[7:0];
            default: header_byte = 8'd0;
        endcase
    end
endfunction

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//

assign current_header_byte = header_byte(byte_count, dst_mac_reg, src_mac_reg, eth_type_reg);
assign fcs_value = ~crc_reg;
assign frame_req_ready = state == ST_IDLE;
assign payload_ready = state == ST_PAYLOAD;
assign tx_busy = state != ST_IDLE;

//state:协议阶段转移，与计数器和数据通路分离
always@(posedge tx_clk or negedge tx_rst_n) begin
    if(tx_rst_n == 1'b0) begin
        state <= ST_IDLE;
    end else begin
        case(state)
            ST_IDLE: begin
                if(frame_req_valid) begin
                    state <= ST_PREAMBLE;
                end
            end
            ST_PREAMBLE: begin
                if(byte_count == 4'd7) begin
                    state <= ST_HEADER;
                end
            end
            ST_HEADER: begin
                if(byte_count == 4'd13) begin
                    if(payload_length_reg != 16'd0) begin
                        state <= ST_PAYLOAD;
                    end else begin
                        state <= ST_PAD;
                    end
                end
            end
            ST_PAYLOAD: begin
                if(payload_valid) begin
                    if(payload_count == payload_length_reg - 1'b1) begin
                        if(payload_length_reg < 16'd46) begin
                            state <= ST_PAD;
                        end else begin
                            state <= ST_FCS;
                        end
                    end
                end else begin
                    state <= ST_IFG;
                end
            end
            ST_PAD: begin
                if(pad_count == 16'd46 - payload_length_reg - 1'b1) begin
                    state <= ST_FCS;
                end
            end
            ST_FCS: begin
                if(fcs_count == 2'd3) begin
                    state <= ST_IFG;
                end
            end
            ST_IFG: begin
                if(ifg_count == 4'd11) begin
                    state <= ST_IDLE;
                end
            end
            default: state <= ST_IDLE;
        endcase
    end
end

//byte_count:前导码和MAC报头发送字节计数
always@(posedge tx_clk or negedge tx_rst_n) begin
    if(tx_rst_n == 1'b0) begin
        byte_count <= 4'd0;
    end else begin
        case(state)
            ST_IDLE: begin
                if(frame_req_valid) begin
                    byte_count <= 4'd0;
                end
            end
            ST_PREAMBLE: begin
                if(byte_count == 4'd7) begin
                    byte_count <= 4'd0;
                end else begin
                    byte_count <= byte_count + 1'b1;
                end
            end
            ST_HEADER: begin
                if(byte_count == 4'd13) begin
                    byte_count <= 4'd0;
                end else begin
                    byte_count <= byte_count + 1'b1;
                end
            end
            default: begin
            end
        endcase
    end
end

//payload_count:仅在负载握手成功时累计发送长度
always@(posedge tx_clk or negedge tx_rst_n) begin
    if(tx_rst_n == 1'b0) begin
        payload_count <= 16'd0;
    end else begin
        case(state)
            ST_IDLE: begin
                if(frame_req_valid) begin
                    payload_count <= 16'd0;
                end
            end
            ST_PAYLOAD: begin
                if(payload_valid) begin
                    if(payload_count == payload_length_reg - 1'b1) begin
                        payload_count <= 16'd0;
                    end else begin
                        payload_count <= payload_count + 1'b1;
                    end
                end
            end
            default: begin
            end
        endcase
    end
end

//pad_count:最短帧补零字节计数
always@(posedge tx_clk or negedge tx_rst_n) begin
    if(tx_rst_n == 1'b0) begin
        pad_count <= 16'd0;
    end else begin
        case(state)
            ST_IDLE: begin
                if(frame_req_valid) begin
                    pad_count <= 16'd0;
                end
            end
            ST_HEADER: begin
                if(byte_count == 4'd13) begin
                    if(!(payload_length_reg != 16'd0)) begin
                        pad_count <= 16'd0;
                    end
                end
            end
            ST_PAYLOAD: begin
                if(payload_valid) begin
                    if(payload_count == payload_length_reg - 1'b1) begin
                        if(payload_length_reg < 16'd46) begin
                            pad_count <= 16'd0;
                        end
                    end
                end
            end
            ST_PAD: begin
                if(!(pad_count == 16'd46 - payload_length_reg - 1'b1)) begin
                    pad_count <= pad_count + 1'b1;
                end
            end
            default: begin
            end
        endcase
    end
end

//fcs_count:四字节FCS发送位置
always@(posedge tx_clk or negedge tx_rst_n) begin
    if(tx_rst_n == 1'b0) begin
        fcs_count <= 2'd0;
    end else begin
        case(state)
            ST_PAYLOAD: begin
                if(payload_valid) begin
                    if(payload_count == payload_length_reg - 1'b1) begin
                        if(!(payload_length_reg < 16'd46)) begin
                            fcs_count <= 2'd0;
                        end
                    end
                end
            end
            ST_PAD: begin
                if(pad_count == 16'd46 - payload_length_reg - 1'b1) begin
                    fcs_count <= 2'd0;
                end
            end
            ST_FCS: begin
                if(!(fcs_count == 2'd3)) begin
                    fcs_count <= fcs_count + 1'b1;
                end
            end
            default: begin
            end
        endcase
    end
end

//ifg_count:保证十二字节发送帧间隔
always@(posedge tx_clk or negedge tx_rst_n) begin
    if(tx_rst_n == 1'b0) begin
        ifg_count <= 4'd0;
    end else begin
        case(state)
            ST_PAYLOAD: begin
                if(!payload_valid) begin
                    ifg_count <= 4'd0;
                end
            end
            ST_FCS: begin
                if(fcs_count == 2'd3) begin
                    ifg_count <= 4'd0;
                end
            end
            ST_IFG: begin
                if(!(ifg_count == 4'd11)) begin
                    ifg_count <= ifg_count + 1'b1;
                end
            end
            default: begin
            end
        endcase
    end
end

//crc_reg:逐字节累计以太网CRC32
always@(posedge tx_clk or negedge tx_rst_n) begin
    if(tx_rst_n == 1'b0) begin
        crc_reg <= 32'hffff_ffff;
    end else begin
        case(state)
            ST_IDLE: begin
                if(frame_req_valid) begin
                    crc_reg <= 32'hffff_ffff;
                end
            end
            ST_HEADER: begin
                crc_reg <= crc32_byte(crc_reg, current_header_byte);
            end
            ST_PAYLOAD: begin
                if(payload_valid) begin
                    crc_reg <= crc32_byte(crc_reg, payload_data);
                end
            end
            ST_PAD: begin
                crc_reg <= crc32_byte(crc_reg, 8'd0);
            end
            default: begin
            end
        endcase
    end
end

//dst_mac_reg:发送请求握手时锁存整帧元数据
always@(posedge tx_clk or negedge tx_rst_n) begin
    if(tx_rst_n == 1'b0) begin
        dst_mac_reg <= 48'd0;
        src_mac_reg <= 48'd0;
        eth_type_reg <= 16'd0;
        payload_length_reg <= 16'd0;
    end else begin
        case(state)
            ST_IDLE: begin
                if(frame_req_valid) begin
                    dst_mac_reg <= frame_dst_mac;
                    src_mac_reg <= frame_src_mac;
                    eth_type_reg <= frame_eth_type;
                    payload_length_reg <= frame_payload_length;
                end
            end
            default: begin
            end
        endcase
    end
end

//gmii_tx_en:按发送阶段更新GMII输出寄存器
always@(posedge tx_clk or negedge tx_rst_n) begin
    if(tx_rst_n == 1'b0) begin
        gmii_tx_en <= 1'b0;
        gmii_tx_er <= 1'b0;
        gmii_txd <= 8'd0;
    end else begin
        gmii_tx_er <= 1'b0;
        case(state)
            ST_IDLE: begin
                gmii_tx_en <= 1'b0;
                gmii_txd <= 8'd0;
            end
            ST_PREAMBLE: begin
                gmii_tx_en <= 1'b1;
                gmii_txd <= (byte_count == 4'd7)? 8'hd5 : 8'h55;
            end
            ST_HEADER: begin
                gmii_tx_en <= 1'b1;
                gmii_txd <= current_header_byte;
            end
            ST_PAYLOAD: begin
                if(payload_valid) begin
                    gmii_tx_en <= 1'b1;
                    gmii_txd <= payload_data;
                    if(payload_count == payload_length_reg - 1'b1) begin
                        if(!payload_last) begin
                            gmii_tx_er <= 1'b1;
                        end
                    end else begin
                        if(payload_last) begin
                            gmii_tx_er <= 1'b1;
                        end
                    end
                end else begin
                    gmii_tx_en <= 1'b0;
                    gmii_tx_er <= 1'b1;
                end
            end
            ST_PAD: begin
                gmii_tx_en <= 1'b1;
                gmii_txd <= 8'd0;
            end
            ST_FCS: begin
                gmii_tx_en <= 1'b1;
                case(fcs_count)
                    2'd0: gmii_txd <= fcs_value[7:0];
                    2'd1: gmii_txd <= fcs_value[15:8];
                    2'd2: gmii_txd <= fcs_value[23:16];
                    2'd3: gmii_txd <= fcs_value[31:24];
                    default: begin
                    end
                endcase
            end
            ST_IFG: begin
                gmii_tx_en <= 1'b0;
                gmii_txd <= 8'd0;
            end
            default: begin
            end
        endcase
    end
end

//tx_done:发送完成单周期事件
always@(posedge tx_clk or negedge tx_rst_n) begin
    if(tx_rst_n == 1'b0) begin
        tx_done <= 1'b0;
    end else begin
        tx_done <= 1'b0;
        case(state)
            ST_FCS: begin
                if(fcs_count == 2'd3) begin
                    tx_done <= 1'b1;
                end
            end
            default: begin
            end
        endcase
    end
end

endmodule
