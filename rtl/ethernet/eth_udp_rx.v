//--------------------------------------------------------------------------------------------------------
// 模块： eth_udp_rx
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： IPv4与UDP地址、长度和校验和检查，拒绝分片与选项
// 作者： WANG
// 时间： 26.10.22
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ps

module  eth_udp_rx
(
    input   wire                   rx_clk                 ,
    input   wire                   rx_rst_n               ,
    input   wire           [47:0]  local_mac              ,
    input   wire           [31:0]  local_ip               ,
    input   wire           [15:0]  local_port             ,
    input   wire                   frame_start            ,
    input   wire           [47:0]  frame_dst_mac          ,
    input   wire           [47:0]  frame_src_mac          ,
    input   wire           [15:0]  frame_eth_type         ,
    input   wire                   frame_payload_valid    ,
    input   wire           [7:0]   frame_payload_data     ,
    input   wire                   frame_payload_last     ,
    input   wire                   frame_done             ,
    input   wire                   frame_error            ,
    output  reg                    udp_packet_start       ,
    output  reg            [47:0]  udp_src_mac            ,
    output  reg            [31:0]  udp_src_ip             ,
    output  reg            [15:0]  udp_src_port           ,
    output  reg            [15:0]  udp_payload_length     ,
    output  reg                    udp_payload_valid      ,
    output  reg            [7:0]   udp_payload_data       ,
    output  reg                    udp_payload_last       ,
    output  reg                    udp_packet_done        ,
    output  reg                    udp_packet_error       ,
    output  reg                    ip_checksum_ok         ,
    output  reg                    udp_checksum_ok
);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//

//wire  define
wire           [31:0]  udp_sum_final;
wire                   mac_match;
//reg   define
reg                    frame_done_dly;
reg                    frame_error_dly;
reg                    frame_active;
reg                    udp_header_seen;
reg                    header_error;
reg            [15:0]  byte_index;
reg            [15:0]  ip_total_length;
reg            [7:0]   fragment_high;
reg            [31:0]  dst_ip_reg;
reg            [15:0]  udp_length;
reg            [15:0]  udp_dst_port;
reg            [15:0]  udp_checksum_field;
reg            [7:0]   ip_high_byte;
reg            [31:0]  ip_sum;
reg            [7:0]   udp_high_byte;
reg            [31:0]  udp_sum;

function [15:0] fold_sum;
    input   [31:0] sum_in;
    reg            [16:0]  fold_once;
    begin
        fold_once = sum_in[31:16] + sum_in[15:0];
        fold_sum = fold_once[15:0] + fold_once[16];
    end
endfunction

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//

assign udp_sum_final = udp_sum + ((byte_index[0])? { 16'd0, udp_high_byte, frame_payload_data } : { 16'd0, frame_payload_data, 8'd0 }) + { 16'd0, udp_src_ip[31:16] } + { 16'd0, udp_src_ip[15:0] } + { 16'd0, dst_ip_reg[31:16] } + { 16'd0, dst_ip_reg[15:0] } + 32'h0011 + { 16'd0, udp_length };

//frame_done_dly:包结束延后一拍，等待末字节校验结果稳定
always@(posedge rx_clk or negedge rx_rst_n) if(rx_rst_n == 1'b0) begin
    frame_done_dly <= 1'b0;
    frame_error_dly <= 1'b0;
end else begin
    frame_done_dly <= frame_done;
    frame_error_dly <= frame_error;
end

assign mac_match = (frame_dst_mac == local_mac) || (frame_dst_mac == 48'hff_ff_ff_ff_ff_ff);

//frame_active:限定当前接收帧属于本协议
always@(posedge rx_clk or negedge rx_rst_n) begin
    if(rx_rst_n == 1'b0) begin
        frame_active <= 1'b0;
    end else begin
        if(frame_start) begin
            frame_active <= (frame_eth_type == 16'h0800) && mac_match;
        end
        if(frame_done_dly && frame_active) begin
            frame_active <= 1'b0;
        end
    end
end

//header_error:累计报头格式错误及UDP报头完成状态
always@(posedge rx_clk or negedge rx_rst_n) begin
    if(rx_rst_n == 1'b0) begin
        udp_header_seen <= 1'b0;
        header_error <= 1'b0;
    end else begin
        if(frame_start) begin
            udp_header_seen <= 1'b0;
            header_error <= (frame_eth_type != 16'h0800) || !mac_match;
        end
        if(frame_payload_valid && frame_active) begin
            case(byte_index)
                16'd0: begin
                    if(frame_payload_data != 8'h45) begin
                        header_error <= 1'b1;
                    end
                end
                16'd3: begin
                    if({ ip_total_length[15:8], frame_payload_data } < 16'd28) begin
                        header_error <= 1'b1;
                    end
                end
                16'd6: begin
                    if((frame_payload_data & 8'h3f) != 8'd0) begin
                        header_error <= 1'b1;
                    end
                end
                16'd7: begin
                    if((frame_payload_data != 8'd0) || fragment_high[5]) begin
                        header_error <= 1'b1;
                    end
                end
                16'd9: begin
                    if(frame_payload_data != 8'h11) begin
                        header_error <= 1'b1;
                    end
                end
                16'd19: begin
                    if({ dst_ip_reg[31:8], frame_payload_data } != local_ip) begin
                        header_error <= 1'b1;
                    end
                end
                16'd23: begin
                    if({ udp_dst_port[15:8], frame_payload_data } != local_port) begin
                        header_error <= 1'b1;
                    end
                end
                16'd25: begin
                    if(({ udp_length[15:8], frame_payload_data } < 16'd8) || ({ udp_length[15:8], frame_payload_data } > ip_total_length - 16'd20)) begin
                        header_error <= 1'b1;
                    end
                end
                16'd27: begin
                    udp_header_seen <= 1'b1;
                end
                default: begin
                end
            endcase
        end
    end
end

//byte_index:逐字节定位IPv4和UDP字段
always@(posedge rx_clk or negedge rx_rst_n) begin
    if(rx_rst_n == 1'b0) begin
        byte_index <= 16'd0;
    end else begin
        if(frame_start) begin
            byte_index <= 16'd0;
        end
        if(frame_payload_valid && frame_active) begin
            byte_index <= byte_index + 1'b1;
        end
    end
end

//ip_total_length:保存IPv4长度、分片标记和目标地址
always@(posedge rx_clk or negedge rx_rst_n) begin
    if(rx_rst_n == 1'b0) begin
        ip_total_length <= 16'd0;
        fragment_high <= 8'd0;
        dst_ip_reg <= 32'd0;
    end else begin
        if(frame_start) begin
            ip_total_length <= 16'd0;
            fragment_high <= 8'd0;
            dst_ip_reg <= 32'd0;
        end
        if(frame_payload_valid && frame_active) begin
            case(byte_index)
                16'd2: ip_total_length[15:8] <= frame_payload_data;
                16'd3: begin
                    ip_total_length[7:0] <= frame_payload_data;
                end
                16'd6: begin
                    fragment_high <= frame_payload_data;
                end
                16'd16: dst_ip_reg[31:24] <= frame_payload_data;
                16'd17: dst_ip_reg[23:16] <= frame_payload_data;
                16'd18: dst_ip_reg[15:8] <= frame_payload_data;
                16'd19: begin
                    dst_ip_reg[7:0] <= frame_payload_data;
                end
                default: begin
                end
            endcase
        end
    end
end

//udp_length:保存UDP长度、目标端口和校验和字段
always@(posedge rx_clk or negedge rx_rst_n) begin
    if(rx_rst_n == 1'b0) begin
        udp_length <= 16'd0;
        udp_dst_port <= 16'd0;
        udp_checksum_field <= 16'd0;
    end else begin
        if(frame_start) begin
            udp_length <= 16'd0;
            udp_checksum_field <= 16'd0;
            udp_dst_port <= 16'd0;
        end
        if(frame_payload_valid && frame_active) begin
            case(byte_index)
                16'd22: udp_dst_port[15:8] <= frame_payload_data;
                16'd23: begin
                    udp_dst_port[7:0] <= frame_payload_data;
                end
                16'd24: udp_length[15:8] <= frame_payload_data;
                16'd25: begin
                    udp_length[7:0] <= frame_payload_data;
                end
                16'd26: udp_checksum_field[15:8] <= frame_payload_data;
                16'd27: begin
                    udp_checksum_field[7:0] <= frame_payload_data;
                end
                default: begin
                end
            endcase
        end
    end
end

//udp_src_mac:锁存当前数据报源端点和应用长度
always@(posedge rx_clk or negedge rx_rst_n) begin
    if(rx_rst_n == 1'b0) begin
        udp_src_mac <= 48'd0;
        udp_src_ip <= 32'd0;
        udp_src_port <= 16'd0;
        udp_payload_length <= 16'd0;
    end else begin
        if(frame_start) begin
            udp_src_mac <= frame_src_mac;
            udp_src_ip <= 32'd0;
            udp_src_port <= 16'd0;
            udp_payload_length <= 16'd0;
        end
        if(frame_payload_valid && frame_active) begin
            case(byte_index)
                16'd12: udp_src_ip[31:24] <= frame_payload_data;
                16'd13: udp_src_ip[23:16] <= frame_payload_data;
                16'd14: udp_src_ip[15:8] <= frame_payload_data;
                16'd15: udp_src_ip[7:0] <= frame_payload_data;
                16'd20: udp_src_port[15:8] <= frame_payload_data;
                16'd21: udp_src_port[7:0] <= frame_payload_data;
                16'd25: begin
                    if(({ udp_length[15:8], frame_payload_data } < 16'd8) || ({ udp_length[15:8], frame_payload_data } > ip_total_length - 16'd20)) begin
                        udp_payload_length <= 16'd0;
                    end else begin
                        udp_payload_length <= { udp_length[15:8], frame_payload_data } - 16'd8;
                    end
                end
                default: begin
                end
            endcase
        end
    end
end

//ip_high_byte:按网络字节序配对并累计IPv4反码和
always@(posedge rx_clk or negedge rx_rst_n) begin
    if(rx_rst_n == 1'b0) begin
        ip_high_byte <= 8'd0;
        ip_sum <= 32'd0;
    end else begin
        if(frame_start) begin
            ip_sum <= 32'd0;
        end
        if(frame_payload_valid && frame_active) begin
            if(byte_index < 16'd20) begin
                if(!byte_index[0]) begin
                    ip_high_byte <= frame_payload_data;
                end else begin
                    ip_sum <= ip_sum + { ip_high_byte, frame_payload_data };
                end
            end
        end
    end
end

//udp_high_byte:按网络字节序配对并累计UDP反码和
always@(posedge rx_clk or negedge rx_rst_n) begin
    if(rx_rst_n == 1'b0) begin
        udp_high_byte <= 8'd0;
        udp_sum <= 32'd0;
    end else begin
        if(frame_start) begin
            udp_sum <= 32'd0;
        end
        if(frame_payload_valid && frame_active) begin
            if((byte_index >= 16'd20) && ((byte_index < 16'd28) || (byte_index < 16'd20 + udp_length))) begin
                if(!byte_index[0]) begin
                    udp_high_byte <= frame_payload_data;
                end else begin
                    udp_sum <= udp_sum + { udp_high_byte, frame_payload_data };
                end
            end
        end
    end
end

//ip_checksum_ok:在IPv4报头末字节判定报头校验
always@(posedge rx_clk or negedge rx_rst_n) begin
    if(rx_rst_n == 1'b0) begin
        ip_checksum_ok <= 1'b0;
    end else begin
        if(frame_start) begin
            ip_checksum_ok <= 1'b0;
        end
        if(frame_payload_valid && frame_active) begin
            if(byte_index < 16'd20) begin
                if(byte_index[0]) begin
                    if(byte_index == 16'd19) begin
                        ip_checksum_ok <= fold_sum((ip_sum + { 16'd0, ip_high_byte, frame_payload_data })) == 16'hffff;
                    end
                end
            end
        end
    end
end

//udp_checksum_ok:包含奇数字节补零及伪首部的UDP校验结果
always@(posedge rx_clk or negedge rx_rst_n) begin
    if(rx_rst_n == 1'b0) begin
        udp_checksum_ok <= 1'b0;
    end else begin
        if(frame_start) begin
            udp_checksum_ok <= 1'b0;
        end
        if(frame_payload_valid && frame_active) begin
            if((byte_index >= 16'd20) && ((byte_index < 16'd28) || (byte_index < 16'd20 + udp_length))) begin
                if((udp_length >= 16'd8) && (byte_index == 16'd20 + udp_length - 1'b1)) begin
                    if(udp_checksum_field == 16'd0) begin
                        udp_checksum_ok <= 1'b1;
                    end else begin
                        udp_checksum_ok <= fold_sum(udp_sum_final) == 16'hffff;
                    end
                end
            end
        end
    end
end

//udp_packet_start:UDP报头完成后的单周期起始事件
always@(posedge rx_clk or negedge rx_rst_n) begin
    if(rx_rst_n == 1'b0) begin
        udp_packet_start <= 1'b0;
    end else begin
        udp_packet_start <= 1'b0;
        if(frame_payload_valid && frame_active) begin
            case(byte_index)
                16'd27: begin
                    udp_packet_start <= 1'b1;
                end
                default: begin
                end
            endcase
        end
    end
end

//udp_payload_valid:截取UDP应用负载并对齐末字节标志
always@(posedge rx_clk or negedge rx_rst_n) begin
    if(rx_rst_n == 1'b0) begin
        udp_payload_valid <= 1'b0;
        udp_payload_data <= 8'd0;
        udp_payload_last <= 1'b0;
    end else begin
        udp_payload_valid <= 1'b0;
        udp_payload_last <= 1'b0;
        if(frame_payload_valid && frame_active) begin
            if((byte_index >= 16'd28) && (byte_index < 16'd20 + udp_length)) begin
                udp_payload_valid <= 1'b1;
                udp_payload_data <= frame_payload_data;
                if(byte_index == 16'd20 + udp_length - 1'b1) begin
                    udp_payload_last <= 1'b1;
                end
            end
        end
    end
end

//udp_packet_done:末字节校验完成后提交或拒绝整包
always@(posedge rx_clk or negedge rx_rst_n) begin
    if(rx_rst_n == 1'b0) begin
        udp_packet_done <= 1'b0;
        udp_packet_error <= 1'b0;
    end else begin
        udp_packet_done <= 1'b0;
        udp_packet_error <= 1'b0;
        if(frame_done_dly && frame_active) begin
            udp_packet_done <= 1'b1;
            udp_packet_error <= frame_error_dly || header_error || !udp_header_seen || !ip_checksum_ok || !udp_checksum_ok;
        end
    end
end

endmodule
