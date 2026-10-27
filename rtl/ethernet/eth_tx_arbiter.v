//--------------------------------------------------------------------------------------------------------
// 模块： eth_tx_arbiter
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： ARP优先的整帧仲裁，帧内保持发送源不变
// 作者： WANG
// 时间： 26.10.22
//--------------------------------------------------------------------------------------------------------
`timescale 1ns/1ps

// Frame-level arbiter. ARP has priority when the MAC becomes available; the
// selected source remains locked through its final payload byte.
module  eth_tx_arbiter
(
    input   wire                   clk                    ,
    input   wire                   rst_n                  ,
    input   wire                   arp_req_valid          ,
    output  wire                   arp_req_ready          ,
    input   wire           [47:0]  arp_dst_mac            ,
    input   wire           [47:0]  arp_src_mac            ,
    input   wire           [15:0]  arp_eth_type           ,
    input   wire           [15:0]  arp_payload_length     ,
    input   wire                   arp_payload_valid      ,
    output  wire                   arp_payload_ready      ,
    input   wire           [7:0]   arp_payload_data       ,
    input   wire                   arp_payload_last       ,
    input   wire                   udp_req_valid          ,
    output  wire                   udp_req_ready          ,
    input   wire           [47:0]  udp_dst_mac            ,
    input   wire           [47:0]  udp_src_mac            ,
    input   wire           [15:0]  udp_eth_type           ,
    input   wire           [15:0]  udp_payload_length     ,
    input   wire                   udp_payload_valid      ,
    output  wire                   udp_payload_ready      ,
    input   wire           [7:0]   udp_payload_data       ,
    input   wire                   udp_payload_last       ,
    output  wire                   mac_req_valid          ,
    input   wire                   mac_req_ready          ,
    output  wire           [47:0]  mac_dst_mac            ,
    output  wire           [47:0]  mac_src_mac            ,
    output  wire           [15:0]  mac_eth_type           ,
    output  wire           [15:0]  mac_payload_length     ,
    output  wire                   mac_payload_valid      ,
    input   wire                   mac_payload_ready      ,
    output  wire           [7:0]   mac_payload_data       ,
    output  wire                   mac_payload_last
);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//

//wire/reg define
reg            [1:0]   owner;
wire                   choose_arp;
wire                   choose_udp;



localparam OWNER_IDLE = 2'd0;
localparam OWNER_ARP  = 2'd1;
localparam OWNER_UDP  = 2'd2;


//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
assign choose_arp = (owner == OWNER_IDLE) && arp_req_valid;
assign choose_udp = (owner == OWNER_IDLE) && !arp_req_valid && udp_req_valid;

assign mac_req_valid = choose_arp || choose_udp;
assign mac_dst_mac = (owner == OWNER_ARP || choose_arp) ? arp_dst_mac : udp_dst_mac;
assign mac_src_mac = (owner == OWNER_ARP || choose_arp) ? arp_src_mac : udp_src_mac;
assign mac_eth_type = (owner == OWNER_ARP || choose_arp) ? arp_eth_type : udp_eth_type;
assign mac_payload_length = (owner == OWNER_ARP || choose_arp) ?
                            arp_payload_length : udp_payload_length;

assign arp_req_ready = choose_arp && mac_req_ready;
assign udp_req_ready = choose_udp && mac_req_ready;

assign mac_payload_valid = (owner == OWNER_ARP) ? arp_payload_valid :
                           (owner == OWNER_UDP) ? udp_payload_valid : 1'b0;
assign mac_payload_data = (owner == OWNER_ARP) ? arp_payload_data :
                          (owner == OWNER_UDP) ? udp_payload_data : 8'd0;
assign mac_payload_last = (owner == OWNER_ARP) ? arp_payload_last :
                          (owner == OWNER_UDP) ? udp_payload_last : 1'b0;
assign arp_payload_ready = (owner == OWNER_ARP) && mac_payload_ready;
assign udp_payload_ready = (owner == OWNER_UDP) && mac_payload_ready;

always@(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        owner <= OWNER_IDLE;
    end else begin
        if (owner == OWNER_IDLE) begin
            if (choose_arp && mac_req_ready)
                owner <= OWNER_ARP;
            else if (choose_udp && mac_req_ready)
                owner <= OWNER_UDP;
        end else if (owner == OWNER_ARP) begin
            if (arp_payload_valid && mac_payload_ready && arp_payload_last)
                owner <= OWNER_IDLE;
        end else if (owner == OWNER_UDP) begin
            if (udp_payload_valid && mac_payload_ready && udp_payload_last)
                owner <= OWNER_IDLE;
        end else begin
            owner <= OWNER_IDLE;
        end
    end
end

endmodule
