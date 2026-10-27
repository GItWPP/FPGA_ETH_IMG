//--------------------------------------------------------------------------------------------------------
// 模块： eth_udp_tx
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： IPv4与UDP报头、非零UDP校验和及负载握手生成
// 作者： WANG
// 时间： 26.10.22
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ps

module  eth_udp_tx
(
    input   wire                   tx_clk                 ,
    input   wire                   tx_rst_n               ,
    input   wire           [47:0]  local_mac              ,
    input   wire           [31:0]  local_ip               ,
    input   wire           [15:0]  local_port             ,
    input   wire           [47:0]  dst_mac                ,
    input   wire           [31:0]  dst_ip                 ,
    input   wire           [15:0]  dst_port               ,
    input   wire                   udp_req_valid          ,
    output  wire                   udp_req_ready          ,
    input   wire           [15:0]  udp_payload_length     ,
    input   wire           [31:0]  udp_payload_sum        ,
    input   wire                   udp_payload_valid      ,
    output  wire                   udp_payload_ready      ,
    input   wire           [7:0]   udp_payload_data       ,
    input   wire                   udp_payload_last       ,
    output  wire                   frame_req_valid        ,
    input   wire                   frame_req_ready        ,
    output  wire           [47:0]  frame_dst_mac          ,
    output  wire           [47:0]  frame_src_mac          ,
    output  wire           [15:0]  frame_eth_type         ,
    output  wire           [15:0]  frame_payload_length   ,
    output  wire                   frame_payload_valid    ,
    input   wire                   frame_payload_ready    ,
    output  reg            [7:0]   frame_payload_data     ,
    output  wire                   frame_payload_last     ,
    output  wire                   tx_busy                ,
    output  reg                    tx_done
);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//

//parameter define
localparam ST_IDLE = 3'd0;
localparam ST_REQUEST = 3'd1;
localparam ST_IP = 3'd2;
localparam ST_UDP = 3'd3;
localparam ST_PAYLOAD = 3'd4;
//reg   define
reg            [2:0]   state;
reg            [4:0]   header_index;
reg            [15:0]  payload_count;
reg            [15:0]  payload_length_reg;
reg            [15:0]  udp_length_reg;
reg            [15:0]  ip_total_length_reg;
reg            [15:0]  ip_id_reg;
reg            [15:0]  ip_checksum_reg;
reg            [15:0]  udp_checksum_reg;
reg            [47:0]  dst_mac_reg;
reg            [31:0]  dst_ip_reg;
reg            [15:0]  dst_port_reg;

function [15:0] fold_sum;
    input   [31:0] sum_in;
    reg            [16:0]  fold_once;
    begin
        fold_once = sum_in[31:16] + sum_in[15:0];
        fold_sum = fold_once[15:0] + fold_once[16];
    end
endfunction

function [15:0] make_ip_checksum;
    input   [15:0] total_length;
    input   [15:0] identification;
    input   [31:0] source_ip;
    input   [31:0] destination_ip;
    reg            [31:0]  sum;
    begin
        sum = 16'h4500 + total_length + identification + 16'h4000 + 16'h4011 + source_ip[31:16] + source_ip[15:0] + destination_ip[31:16] + destination_ip[15:0];
        make_ip_checksum = ~fold_sum(sum);
    end
endfunction

function [15:0] make_udp_checksum;
    input   [15:0] udp_length;
    input   [31:0] payload_sum;
    input   [31:0] source_ip;
    input   [31:0] destination_ip;
    input   [15:0] source_port;
    input   [15:0] destination_port;
    reg            [31:0]  sum;
    reg            [15:0]  checksum_work;
    begin
        sum = payload_sum + source_ip[31:16] + source_ip[15:0] + destination_ip[31:16] + destination_ip[15:0] + 16'h0011 + udp_length + source_port + destination_port + udp_length;
        checksum_work = ~fold_sum(sum);
        make_udp_checksum = (checksum_work == 16'h0000)? 16'hffff : checksum_work;
    end
endfunction

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//

assign udp_req_ready = state == ST_IDLE;
assign udp_payload_ready = (state == ST_PAYLOAD) && frame_payload_ready;
assign frame_req_valid = state == ST_REQUEST;
assign frame_dst_mac = dst_mac_reg;
assign frame_src_mac = local_mac;
assign frame_eth_type = 16'h0800;
assign frame_payload_length = ip_total_length_reg;
assign frame_payload_valid = (state == ST_IP) || (state == ST_UDP) || (state == ST_PAYLOAD) && udp_payload_valid;
assign frame_payload_last = (state == ST_PAYLOAD) && udp_payload_last;
assign tx_busy = state != ST_IDLE;

always@(*) begin
    frame_payload_data = 8'd0;
    if(state == ST_IP) begin
        case(header_index)
            5'd0: frame_payload_data = 8'h45;
            5'd1: frame_payload_data = 8'h00;
            5'd2: frame_payload_data = ip_total_length_reg[15:8];
            5'd3: frame_payload_data = ip_total_length_reg[7:0];
            5'd4: frame_payload_data = ip_id_reg[15:8];
            5'd5: frame_payload_data = ip_id_reg[7:0];
            5'd6: frame_payload_data = 8'h40;
            5'd7: frame_payload_data = 8'h00;
            5'd8: frame_payload_data = 8'h40;
            5'd9: frame_payload_data = 8'h11;
            5'd10: frame_payload_data = ip_checksum_reg[15:8];
            5'd11: frame_payload_data = ip_checksum_reg[7:0];
            5'd12: frame_payload_data = local_ip[31:24];
            5'd13: frame_payload_data = local_ip[23:16];
            5'd14: frame_payload_data = local_ip[15:8];
            5'd15: frame_payload_data = local_ip[7:0];
            5'd16: frame_payload_data = dst_ip_reg[31:24];
            5'd17: frame_payload_data = dst_ip_reg[23:16];
            5'd18: frame_payload_data = dst_ip_reg[15:8];
            5'd19: frame_payload_data = dst_ip_reg[7:0];
            default: frame_payload_data = 8'd0;
        endcase
    end else if(state == ST_UDP) begin
        case(header_index[3:0])
            4'd0: frame_payload_data = local_port[15:8];
            4'd1: frame_payload_data = local_port[7:0];
            4'd2: frame_payload_data = dst_port_reg[15:8];
            4'd3: frame_payload_data = dst_port_reg[7:0];
            4'd4: frame_payload_data = udp_length_reg[15:8];
            4'd5: frame_payload_data = udp_length_reg[7:0];
            4'd6: frame_payload_data = udp_checksum_reg[15:8];
            4'd7: frame_payload_data = udp_checksum_reg[7:0];
            default: frame_payload_data = 8'd0;
        endcase
    end else if(state == ST_PAYLOAD) begin
        frame_payload_data = udp_payload_data;
    end
end

//state:协议阶段转移，与计数器和数据通路分离
always@(posedge tx_clk or negedge tx_rst_n) begin
    if(tx_rst_n == 1'b0) begin
        state <= ST_IDLE;
    end else begin
        case(state)
            ST_IDLE: begin
                if(udp_req_valid) begin
                    state <= ST_REQUEST;
                end
            end
            ST_REQUEST: begin
                if(frame_req_ready) begin
                    state <= ST_IP;
                end
            end
            ST_IP: begin
                if(frame_payload_ready) begin
                    if(header_index == 5'd19) begin
                        state <= ST_UDP;
                    end
                end
            end
            ST_UDP: begin
                if(frame_payload_ready) begin
                    if(header_index == 5'd7) begin
                        state <= ST_PAYLOAD;
                    end
                end
            end
            ST_PAYLOAD: begin
                if(udp_payload_valid && frame_payload_ready) begin
                    if(udp_payload_last || (payload_count == payload_length_reg - 1'b1)) begin
                        state <= ST_IDLE;
                    end
                end
            end
            default: state <= ST_IDLE;
        endcase
    end
end

//header_index:IPv4和UDP报头发送位置
always@(posedge tx_clk or negedge tx_rst_n) begin
    if(tx_rst_n == 1'b0) begin
        header_index <= 5'd0;
    end else begin
        case(state)
            ST_REQUEST: begin
                if(frame_req_ready) begin
                    header_index <= 5'd0;
                end
            end
            ST_IP: begin
                if(frame_payload_ready) begin
                    if(header_index == 5'd19) begin
                        header_index <= 5'd0;
                    end else begin
                        header_index <= header_index + 1'b1;
                    end
                end
            end
            ST_UDP: begin
                if(frame_payload_ready) begin
                    if(header_index == 5'd7) begin
                        header_index <= 5'd0;
                    end else begin
                        header_index <= header_index + 1'b1;
                    end
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
            ST_UDP: begin
                if(frame_payload_ready) begin
                    if(header_index == 5'd7) begin
                        payload_count <= 16'd0;
                    end
                end
            end
            ST_PAYLOAD: begin
                if(udp_payload_valid && frame_payload_ready) begin
                    if(udp_payload_last || (payload_count == payload_length_reg - 1'b1)) begin
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

//ip_id_reg:每个已发送数据报递增IPv4标识
always@(posedge tx_clk or negedge tx_rst_n) begin
    if(tx_rst_n == 1'b0) begin
        ip_id_reg <= 16'd0;
    end else begin
        case(state)
            ST_PAYLOAD: begin
                if(udp_payload_valid && frame_payload_ready) begin
                    if(udp_payload_last || (payload_count == payload_length_reg - 1'b1)) begin
                        ip_id_reg <= ip_id_reg + 1'b1;
                    end
                end
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
            ST_PAYLOAD: begin
                if(udp_payload_valid && frame_payload_ready) begin
                    if(udp_payload_last || (payload_count == payload_length_reg - 1'b1)) begin
                        tx_done <= 1'b1;
                    end
                end
            end
            default: begin
            end
        endcase
    end
end

//dst_mac_reg:发送请求握手时锁存整帧元数据
always@(posedge tx_clk or negedge tx_rst_n) begin
    if(tx_rst_n == 1'b0) begin
        payload_length_reg <= 16'd0;
        udp_length_reg <= 16'd0;
        ip_total_length_reg <= 16'd0;
        ip_checksum_reg <= 16'd0;
        udp_checksum_reg <= 16'd0;
        dst_mac_reg <= 48'd0;
        dst_ip_reg <= 32'd0;
        dst_port_reg <= 16'd0;
    end else begin
        case(state)
            ST_IDLE: begin
                if(udp_req_valid) begin
                    payload_length_reg <= udp_payload_length;
                    udp_length_reg <= udp_payload_length + 16'd8;
                    ip_total_length_reg <= udp_payload_length + 16'd28;
                    dst_mac_reg <= dst_mac;
                    dst_ip_reg <= dst_ip;
                    dst_port_reg <= dst_port;
                    ip_checksum_reg <= make_ip_checksum((udp_payload_length + 16'd28), ip_id_reg, local_ip, dst_ip);
                    udp_checksum_reg <= make_udp_checksum((udp_payload_length + 16'd8), udp_payload_sum, local_ip, dst_ip, local_port, dst_port);
                end
            end
            default: begin
            end
        endcase
    end
end

endmodule
