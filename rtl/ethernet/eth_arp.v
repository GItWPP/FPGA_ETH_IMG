//--------------------------------------------------------------------------------------------------------
// 模块： eth_arp
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： ARP解析、请求应答及单项地址解析缓存
// 作者： WANG
// 时间： 26.10.22
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ps

module  eth_arp
(
    input   wire                   rx_clk                 ,
    input   wire                   rx_rst_n               ,
    input   wire                   tx_clk                 ,
    input   wire                   tx_rst_n               ,
    input   wire           [47:0]  local_mac              ,
    input   wire           [31:0]  local_ip               ,
    input   wire                   frame_start            ,
    input   wire           [47:0]  frame_dst_mac          ,
    input   wire           [47:0]  frame_src_mac          ,
    input   wire           [15:0]  frame_eth_type         ,
    input   wire                   frame_payload_valid    ,
    input   wire           [7:0]   frame_payload_data     ,
    input   wire                   frame_payload_last     ,
    input   wire                   frame_done             ,
    input   wire                   frame_error            ,
    input   wire                   resolve_req            ,
    input   wire           [31:0]  resolve_ip             ,
    output  reg                    resolve_done           ,
    output  reg                    resolve_failed         ,
    output  reg            [47:0]  resolved_mac           ,
    output  reg                    peer_learn_valid       ,
    output  reg            [47:0]  peer_learn_mac         ,
    output  reg            [31:0]  peer_learn_ip          ,
    output  wire                   tx_frame_req_valid     ,
    input   wire                   tx_frame_req_ready     ,
    output  wire           [47:0]  tx_frame_dst_mac       ,
    output  wire           [47:0]  tx_frame_src_mac       ,
    output  wire           [15:0]  tx_frame_eth_type      ,
    output  wire           [15:0]  tx_frame_payload_length,
    output  wire                   tx_payload_valid       ,
    input   wire                   tx_payload_ready       ,
    output  reg            [7:0]   tx_payload_data        ,
    output  wire                   tx_payload_last
);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//

//wire  define
wire                   rx_mac_match;
wire                   new_reply_event;
wire                   new_peer_event;
//reg   define
reg                    arp_active;
reg                    arp_format_ok;
reg            [5:0]   arp_index;
reg            [15:0]  arp_opcode;
reg            [47:0]  arp_sender_mac;
reg            [31:0]  arp_sender_ip;
reg            [31:0]  arp_target_ip;
reg            [47:0]  reply_mac_hold;
reg            [31:0]  reply_ip_hold;
reg                    reply_toggle_rx;
reg                    peer_toggle_rx;
(* ASYNC_REG = "TRUE" *)
reg            [2:0]   reply_toggle_sync;
(* ASYNC_REG = "TRUE" *)
reg            [2:0]   peer_toggle_sync;
reg            [47:0]  cache_mac;
reg            [31:0]  cache_ip;
reg                    cache_valid;
reg                    resolve_waiting;
reg            [31:0]  resolve_ip_reg;
reg                    tx_pending;
reg                    tx_active;
reg                    tx_is_reply;
reg            [47:0]  tx_target_mac;
reg            [31:0]  tx_target_ip;
reg            [5:0]   tx_index;
//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//

assign rx_mac_match = (frame_dst_mac == local_mac) || (frame_dst_mac == 48'hff_ff_ff_ff_ff_ff);

//arp_active:ARP接收有效窗口及格式校验状态
always@(posedge rx_clk or negedge rx_rst_n) begin
    if(rx_rst_n == 1'b0) begin
        arp_active <= 1'b0;
        arp_format_ok <= 1'b0;
    end else begin
        if(frame_start) begin
            arp_active <= (frame_eth_type == 16'h0806) && rx_mac_match;
            arp_format_ok <= (frame_eth_type == 16'h0806) && rx_mac_match;
        end
        if(frame_payload_valid && arp_active) begin
            case(arp_index)
                6'd0: if(frame_payload_data != 8'h00) begin
                    arp_format_ok <= 1'b0;
                end
                6'd1: if(frame_payload_data != 8'h01) begin
                    arp_format_ok <= 1'b0;
                end
                6'd2: if(frame_payload_data != 8'h08) begin
                    arp_format_ok <= 1'b0;
                end
                6'd3: if(frame_payload_data != 8'h00) begin
                    arp_format_ok <= 1'b0;
                end
                6'd4: if(frame_payload_data != 8'h06) begin
                    arp_format_ok <= 1'b0;
                end
                6'd5: if(frame_payload_data != 8'h04) begin
                    arp_format_ok <= 1'b0;
                end
                default: begin
                end
            endcase
        end
        if(frame_done && arp_active) begin
            arp_active <= 1'b0;
        end
    end
end

//arp_index:ARP字段字节位置
always@(posedge rx_clk or negedge rx_rst_n) begin
    if(rx_rst_n == 1'b0) begin
        arp_index <= 6'd0;
    end else begin
        if(frame_start) begin
            arp_index <= 6'd0;
        end
        if(frame_payload_valid && arp_active) begin
            arp_index <= arp_index + 1'b1;
        end
    end
end

//arp_opcode:按ARP格式锁存操作码和地址字段
always@(posedge rx_clk or negedge rx_rst_n) begin
    if(rx_rst_n == 1'b0) begin
        arp_opcode <= 16'd0;
        arp_sender_mac <= 48'd0;
        arp_sender_ip <= 32'd0;
        arp_target_ip <= 32'd0;
    end else begin
        if(frame_start) begin
            arp_opcode <= 16'd0;
            arp_sender_mac <= 48'd0;
            arp_sender_ip <= 32'd0;
            arp_target_ip <= 32'd0;
        end
        if(frame_payload_valid && arp_active) begin
            case(arp_index)
                6'd6: arp_opcode[15:8] <= frame_payload_data;
                6'd7: arp_opcode[7:0] <= frame_payload_data;
                6'd8: arp_sender_mac[47:40] <= frame_payload_data;
                6'd9: arp_sender_mac[39:32] <= frame_payload_data;
                6'd10: arp_sender_mac[31:24] <= frame_payload_data;
                6'd11: arp_sender_mac[23:16] <= frame_payload_data;
                6'd12: arp_sender_mac[15:8] <= frame_payload_data;
                6'd13: arp_sender_mac[7:0] <= frame_payload_data;
                6'd14: arp_sender_ip[31:24] <= frame_payload_data;
                6'd15: arp_sender_ip[23:16] <= frame_payload_data;
                6'd16: arp_sender_ip[15:8] <= frame_payload_data;
                6'd17: arp_sender_ip[7:0] <= frame_payload_data;
                6'd24: arp_target_ip[31:24] <= frame_payload_data;
                6'd25: arp_target_ip[23:16] <= frame_payload_data;
                6'd26: arp_target_ip[15:8] <= frame_payload_data;
                6'd27: arp_target_ip[7:0] <= frame_payload_data;
                default: begin
                end
            endcase
        end
    end
end

//reply_mac_hold:完整ARP请求通过FCS后保持应答端点并翻转事件
always@(posedge rx_clk or negedge rx_rst_n) begin
    if(rx_rst_n == 1'b0) begin
        reply_mac_hold <= 48'd0;
        reply_ip_hold <= 32'd0;
        reply_toggle_rx <= 1'b0;
    end else begin
        if(frame_done && arp_active) begin
            if(!frame_error && arp_format_ok && (arp_index >= 6'd28)) begin
                if((arp_opcode == 16'h0001) && (arp_target_ip == local_ip)) begin
                    reply_mac_hold <= arp_sender_mac;
                    reply_ip_hold <= arp_sender_ip;
                    reply_toggle_rx <= ~reply_toggle_rx;
                end
            end
        end
    end
end

//peer_learn_mac:仅从完整有效ARP帧更新学习结果
always@(posedge rx_clk or negedge rx_rst_n) begin
    if(rx_rst_n == 1'b0) begin
        peer_toggle_rx <= 1'b0;
        peer_learn_valid <= 1'b0;
        peer_learn_mac <= 48'd0;
        peer_learn_ip <= 32'd0;
    end else begin
        peer_learn_valid <= 1'b0;
        if(frame_done && arp_active) begin
            if(!frame_error && arp_format_ok && (arp_index >= 6'd28)) begin
                peer_learn_valid <= 1'b1;
                peer_learn_mac <= arp_sender_mac;
                peer_learn_ip <= arp_sender_ip;
                peer_toggle_rx <= ~peer_toggle_rx;
            end
        end
    end
end

assign new_reply_event = reply_toggle_sync[2] ^ reply_toggle_sync[1];
assign new_peer_event = peer_toggle_sync[2] ^ peer_toggle_sync[1];
assign tx_frame_req_valid = tx_pending && !tx_active;
assign tx_frame_dst_mac = (tx_is_reply)? tx_target_mac : 48'hff_ff_ff_ff_ff_ff;
assign tx_frame_src_mac = local_mac;
assign tx_frame_eth_type = 16'h0806;
assign tx_frame_payload_length = 16'd28;
assign tx_payload_valid = tx_active;
assign tx_payload_last = tx_active && (tx_index == 6'd27);

always@(*) begin
    case(tx_index)
        6'd0: tx_payload_data = 8'h00;
        6'd1: tx_payload_data = 8'h01;
        6'd2: tx_payload_data = 8'h08;
        6'd3: tx_payload_data = 8'h00;
        6'd4: tx_payload_data = 8'h06;
        6'd5: tx_payload_data = 8'h04;
        6'd6: tx_payload_data = 8'h00;
        6'd7: tx_payload_data = (tx_is_reply)? 8'h02 : 8'h01;
        6'd8: tx_payload_data = local_mac[47:40];
        6'd9: tx_payload_data = local_mac[39:32];
        6'd10: tx_payload_data = local_mac[31:24];
        6'd11: tx_payload_data = local_mac[23:16];
        6'd12: tx_payload_data = local_mac[15:8];
        6'd13: tx_payload_data = local_mac[7:0];
        6'd14: tx_payload_data = local_ip[31:24];
        6'd15: tx_payload_data = local_ip[23:16];
        6'd16: tx_payload_data = local_ip[15:8];
        6'd17: tx_payload_data = local_ip[7:0];
        6'd18: tx_payload_data = (tx_is_reply)? tx_target_mac[47:40] : 8'h00;
        6'd19: tx_payload_data = (tx_is_reply)? tx_target_mac[39:32] : 8'h00;
        6'd20: tx_payload_data = (tx_is_reply)? tx_target_mac[31:24] : 8'h00;
        6'd21: tx_payload_data = (tx_is_reply)? tx_target_mac[23:16] : 8'h00;
        6'd22: tx_payload_data = (tx_is_reply)? tx_target_mac[15:8] : 8'h00;
        6'd23: tx_payload_data = (tx_is_reply)? tx_target_mac[7:0] : 8'h00;
        6'd24: tx_payload_data = tx_target_ip[31:24];
        6'd25: tx_payload_data = tx_target_ip[23:16];
        6'd26: tx_payload_data = tx_target_ip[15:8];
        6'd27: tx_payload_data = tx_target_ip[7:0];
        default: tx_payload_data = 8'd0;
    endcase
end

//reply_toggle_sync:三级同步ARP应答事件
always@(posedge tx_clk or negedge tx_rst_n) begin
    if(tx_rst_n == 1'b0) begin
        reply_toggle_sync <= 3'd0;
    end else begin
        reply_toggle_sync <= { reply_toggle_sync[1:0], reply_toggle_rx };
    end
end

//peer_toggle_sync:三级同步ARP学习事件
always@(posedge tx_clk or negedge tx_rst_n) begin
    if(tx_rst_n == 1'b0) begin
        peer_toggle_sync <= 3'd0;
    end else begin
        peer_toggle_sync <= { peer_toggle_sync[1:0], peer_toggle_rx };
    end
end

//cache_mac:在学习事件到达后更新单项地址缓存
always@(posedge tx_clk or negedge tx_rst_n) begin
    if(tx_rst_n == 1'b0) begin
        cache_mac <= 48'd0;
        cache_ip <= 32'd0;
        cache_valid <= 1'b0;
    end else begin
        if(new_peer_event) begin
            cache_mac <= peer_learn_mac;
            cache_ip <= peer_learn_ip;
            cache_valid <= 1'b1;
        end
    end
end

//resolve_waiting:地址解析等待、命中和失败结果
always@(posedge tx_clk or negedge tx_rst_n) begin
    if(tx_rst_n == 1'b0) begin
        resolve_waiting <= 1'b0;
        resolve_ip_reg <= 32'd0;
        resolve_done <= 1'b0;
        resolve_failed <= 1'b0;
        resolved_mac <= 48'd0;
    end else begin
        resolve_done <= 1'b0;
        resolve_failed <= 1'b0;
        if(new_peer_event) begin
            if(resolve_waiting && (peer_learn_ip == resolve_ip_reg)) begin
                resolved_mac <= peer_learn_mac;
                resolve_done <= 1'b1;
                resolve_waiting <= 1'b0;
            end
        end
        if(resolve_req && !resolve_waiting) begin
            if(cache_valid && (cache_ip == resolve_ip)) begin
                resolved_mac <= cache_mac;
                resolve_done <= 1'b1;
            end else begin
                if(!tx_pending && !tx_active) begin
                    resolve_waiting <= 1'b1;
                    resolve_ip_reg <= resolve_ip;
                end else begin
                    resolve_failed <= 1'b1;
                end
            end
        end
    end
end

//tx_pending:ARP待发送和负载发送窗口状态
always@(posedge tx_clk or negedge tx_rst_n) begin
    if(tx_rst_n == 1'b0) begin
        tx_pending <= 1'b0;
        tx_active <= 1'b0;
        tx_is_reply <= 1'b0;
    end else begin
        if(resolve_req && !resolve_waiting) begin
            if(!(cache_valid && (cache_ip == resolve_ip))) begin
                if(!tx_pending && !tx_active) begin
                    tx_pending <= 1'b1;
                    tx_is_reply <= 1'b0;
                end
            end
        end
        if(new_reply_event && !tx_pending && !tx_active) begin
            tx_pending <= 1'b1;
            tx_is_reply <= 1'b1;
        end
        if(tx_frame_req_valid && tx_frame_req_ready) begin
            tx_pending <= 1'b0;
            tx_active <= 1'b1;
        end
        if(tx_payload_valid && tx_payload_ready) begin
            if(tx_payload_last) begin
                tx_active <= 1'b0;
            end
        end
    end
end

//tx_target_mac:应答或解析请求开始时锁存目标端点
always@(posedge tx_clk or negedge tx_rst_n) begin
    if(tx_rst_n == 1'b0) begin
        tx_target_mac <= 48'd0;
        tx_target_ip <= 32'd0;
    end else begin
        if(resolve_req && !resolve_waiting) begin
            if(!(cache_valid && (cache_ip == resolve_ip))) begin
                if(!tx_pending && !tx_active) begin
                    tx_target_mac <= 48'd0;
                    tx_target_ip <= resolve_ip;
                end
            end
        end
        if(new_reply_event && !tx_pending && !tx_active) begin
            tx_target_mac <= reply_mac_hold;
            tx_target_ip <= reply_ip_hold;
        end
    end
end

//tx_index:仅在ARP负载握手成功时递增字段位置
always@(posedge tx_clk or negedge tx_rst_n) begin
    if(tx_rst_n == 1'b0) begin
        tx_index <= 6'd0;
    end else begin
        if(tx_frame_req_valid && tx_frame_req_ready) begin
            tx_index <= 6'd0;
        end
        if(tx_payload_valid && tx_payload_ready) begin
            if(tx_payload_last) begin
                tx_index <= 6'd0;
            end else begin
                tx_index <= tx_index + 1'b1;
            end
        end
    end
end

endmodule
