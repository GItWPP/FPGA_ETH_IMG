//--------------------------------------------------------------------------------------------------------
// 模块： eth_image_rx
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 验证每个UDP数据报恰含一个完整图像包，通过后跨域提交
// 作者： WANG
// 时间： 26.10.22
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  eth_image_rx
(
    input   wire                   rx_clk                 ,
    input   wire                   rx_rst_n               ,
    input   wire                   udp_packet_start       ,
    input   wire           [95:0]  udp_peer               ,
    input   wire           [15:0]  udp_length             ,
    input   wire                   udp_byte_valid         ,
    input   wire           [7:0]   udp_byte_data          ,
    input   wire                   udp_byte_last          ,
    input   wire                   udp_packet_done        ,
    input   wire                   udp_packet_error       ,
    output  wire                   rx_drop_flag           ,

    input   wire                   app_clk                ,
    input   wire                   app_rst_n              ,
    output  wire                   app_packet_valid       ,
    input   wire                   app_packet_ready       ,
    output  wire           [95:0]  app_peer               ,
    output  wire                   app_byte_valid         ,
    input   wire                   app_byte_ready         ,
    output  wire           [7:0]   app_byte_data
);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//parameter define
localparam [15:0] MAX_BYTES = 16'd1038;
localparam [15:0] HEADER_BYTES = 16'd14;

//wire  define
wire                   mailbox_ready;
wire                   mailbox_byte_ready;
wire                   packet_accept;
wire                   byte_accept;
wire                   packet_bad;

//reg   define
reg                    selected_en;
reg                    format_error;
reg                    last_seen;
reg            [15:0]  byte_count;
reg            [15:0]  length_reg;
reg            [15:0]  application_length;
reg            [15:0]  crc_reg;
reg            [15:0]  received_crc;

//function define
function [15:0] crc16_byte;
    input [15:0] crc;
    input [7:0] value;
    integer k;
    reg            [15:0]  work;
    begin
        work = crc ^ {value, 8'd0};
        for(k = 0; k < 8; k = k + 1)
            work = work[15] ? (work << 1) ^ 16'h1021 : work << 1;
        crc16_byte = work;
    end
endfunction

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
assign packet_accept = udp_packet_start && mailbox_ready
                      && udp_length >= HEADER_BYTES && udp_length <= MAX_BYTES;
assign byte_accept = selected_en && udp_byte_valid;
assign packet_bad = udp_packet_error || format_error || !last_seen
                   || (byte_count != length_reg)
                   || (application_length > 16'd1024)
                   || (application_length + HEADER_BYTES != length_reg)
                   || (received_crc != crc_reg);

always@(posedge rx_clk or negedge rx_rst_n)
    if(rx_rst_n == 1'b0)
        selected_en <= 1'b0;
    else if(udp_packet_start)
        selected_en <= packet_accept;
    else if(udp_packet_done)
        selected_en <= 1'b0;

always@(posedge rx_clk or negedge rx_rst_n)
    if(rx_rst_n == 1'b0) begin
        byte_count <= 16'd0;
        length_reg <= 16'd0;
    end else if(packet_accept) begin
        byte_count <= 16'd0;
        length_reg <= udp_length;
    end else if(byte_accept && byte_count < 16'hffff)
        byte_count <= byte_count + 1'b1;

//固定位置检查包头，禁止将两个数据报拼成一个应用包
always@(posedge rx_clk or negedge rx_rst_n)
    if(rx_rst_n == 1'b0)
        format_error <= 1'b0;
    else if(packet_accept)
        format_error <= 1'b0;
    else if(byte_accept) begin
        if(!mailbox_byte_ready || byte_count >= length_reg)
            format_error <= 1'b1;
        case(byte_count)
            16'd0: if(udp_byte_data != 8'h55) format_error <= 1'b1;
            16'd1: if(udp_byte_data != 8'haa) format_error <= 1'b1;
            16'd2: if(udp_byte_data != 8'h5a) format_error <= 1'b1;
            16'd3: if(udp_byte_data != 8'ha5) format_error <= 1'b1;
            16'd4: if(udp_byte_data != 8'd1) format_error <= 1'b1;
            default: ;
        endcase
        if(udp_byte_last && byte_count + 16'd1 != length_reg)
            format_error <= 1'b1;
    end

always@(posedge rx_clk or negedge rx_rst_n)
    if(rx_rst_n == 1'b0) begin
        application_length <= 16'd0;
        received_crc <= 16'd0;
    end else if(packet_accept) begin
        application_length <= 16'd0;
        received_crc <= 16'd0;
    end else if(byte_accept) begin
        if(byte_count == 16'd10)
            application_length[7:0] <= udp_byte_data;
        if(byte_count == 16'd11)
            application_length[15:8] <= udp_byte_data;
        if(byte_count + 16'd2 == length_reg)
            received_crc[7:0] <= udp_byte_data;
        if(byte_count + 16'd1 == length_reg)
            received_crc[15:8] <= udp_byte_data;
    end

always@(posedge rx_clk or negedge rx_rst_n)
    if(rx_rst_n == 1'b0)
        crc_reg <= 16'hffff;
    else if(packet_accept)
        crc_reg <= 16'hffff;
    else if(byte_accept && byte_count >= 16'd4 && byte_count + 16'd2 < length_reg)
        crc_reg <= crc16_byte(crc_reg, udp_byte_data);

always@(posedge rx_clk or negedge rx_rst_n)
    if(rx_rst_n == 1'b0)
        last_seen <= 1'b0;
    else if(packet_accept)
        last_seen <= 1'b0;
    else if(byte_accept && udp_byte_last)
        last_seen <= 1'b1;

//********************************************************************//
//*************************** Instantiation **************************//
//********************************************************************//
eth_packet_queue
#(
    .SLOT_BITS              (6)
)
rx_mailbox_inst
(
    .wr_clk                 (rx_clk                                          ),
    .wr_rst_n               (rx_rst_n                                        ),
    .wr_start_valid         (udp_packet_start                                ),
    .wr_start_ready         (mailbox_ready                                   ),
    .wr_length              (udp_length >= HEADER_BYTES ? udp_length : 16'd0 ),
    .wr_peer                (udp_peer                                        ),
    .wr_byte_valid          (byte_accept                                     ),
    .wr_byte_ready          (mailbox_byte_ready                              ),
    .wr_byte_data           (udp_byte_data                                   ),
    .wr_finish_flag         (udp_packet_done && selected_en                  ),
    .wr_abort_en            (packet_bad                                      ),
    .wr_drop_flag           (rx_drop_flag                                    ),
    .rd_clk                 (app_clk                                         ),
    .rd_rst_n               (app_rst_n                                       ),
    .rd_packet_valid        (app_packet_valid                                ),
    .rd_packet_ready        (app_packet_ready                                ),
    .rd_length              (                                                ),
    .rd_peer                (app_peer                                        ),
    .rd_sum                 (                                                ),
    .rd_byte_valid          (app_byte_valid                                  ),
    .rd_byte_ready          (app_byte_ready                                  ),
    .rd_byte_data           (app_byte_data                                   ),
    .rd_byte_last           (                                                )
);

endmodule
