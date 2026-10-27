//--------------------------------------------------------------------------------------------------------
// 模块： img_packet_rx_queue
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 完整包双缓冲，解析和命令读取并行，处理完成后释放输入bank
// 作者： WANG
// 时间： 26.10.22
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  img_packet_rx_queue
#(
    parameter integer TIMEOUT_CLKS = 5_000_000
)
(
    input   wire          sys_clk,
    input   wire          sys_rst_n,
    input   wire [7:0]    byte_data,
    input   wire          byte_valid,
    output  wire          byte_ready,
    input   wire [95:0]   byte_peer,
    output  wire          packet_valid,
    input   wire          packet_ready,
    input   wire          packet_release_flag,
    output  wire [7:0]    cmd,
    output  wire [15:0]   transfer_id,
    output  wire [15:0]   seq,
    output  wire [15:0]   length,
    output  wire [15:0]   packet_crc,
    output  wire [95:0]   packet_peer,
    input   wire [9:0]    rd_addr,
    output  wire [7:0]    rd_data
);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//wire  define
wire          parse_valid;
wire          parse_ready;
wire          commit_flag;
wire          wr_en;
wire [9:0]    wr_addr;
wire [7:0]    wr_data;
wire [7:0]    parse_cmd;
wire [15:0]   parse_id;
wire [15:0]   parse_seq;
wire [15:0]   parse_length;
wire [15:0]   parse_crc;
//reg   define
reg           wr_bank;
reg           rd_bank;
reg           delivered;
reg  [1:0]    occupied;
reg  [167:0]  metadata [0:1];
genvar        bank;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
assign parse_ready = !occupied[wr_bank];
assign byte_ready = parse_ready && !parse_valid;
assign commit_flag = parse_valid && parse_ready;
assign packet_valid = occupied[rd_bank] && !delivered;
assign {cmd,transfer_id,seq,length,packet_crc,packet_peer} = metadata[rd_bank];

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        wr_bank <= 1'b0;
    else if(commit_flag)
        wr_bank <= !wr_bank;

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        rd_bank <= 1'b0;
    else if(packet_release_flag)
        rd_bank <= !rd_bank;

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        delivered <= 1'b0;
    else if(packet_release_flag)
        delivered <= 1'b0;
    else if(packet_valid && packet_ready)
        delivered <= 1'b1;

//提交后不再改变元数据，释放前禁止解析器重用该bank
generate
    for(bank = 0; bank < 2; bank = bank + 1) begin : banks
        always@(posedge sys_clk)
            if(sys_rst_n == 1'b0)
                occupied[bank] <= 1'b0;
            else if(commit_flag && wr_bank == bank)
                occupied[bank] <= 1'b1;
            else if(packet_release_flag && rd_bank == bank)
                occupied[bank] <= 1'b0;

        always@(posedge sys_clk)
            if(commit_flag && wr_bank == bank)
                metadata[bank] <= {parse_cmd,parse_id,parse_seq,parse_length,parse_crc,byte_peer};
    end
endgenerate

//********************************************************************//
//*************************** Instantiation **************************//
//********************************************************************//
img_packet_rx
#(
    .TIMEOUT_CLKS       (TIMEOUT_CLKS)
)
parser_inst
(
    .sys_clk           (sys_clk),
    .sys_rst_n         (sys_rst_n),
    .receive_en        (parse_ready),
    .byte_data         (byte_data),
    .byte_flag         (byte_valid && byte_ready),
    .byte_error        (1'b0),
    .buf_wr_en         (wr_en),
    .buf_wr_addr       (wr_addr),
    .buf_wr_data       (wr_data),
    .packet_valid      (parse_valid),
    .packet_ready      (parse_ready),
    .cmd               (parse_cmd),
    .transfer_id       (parse_id),
    .seq               (parse_seq),
    .length            (parse_length),
    .packet_crc        (parse_crc)
);

img_block_buffer
#(
    .ADDR_WIDTH        (11)
)
payload_ram_inst
(
    .sys_clk           (sys_clk),
    .wr_en             (wr_en),
    .wr_addr           ({wr_bank,wr_addr}),
    .wr_data           (wr_data),
    .rd_addr           ({rd_bank,rd_addr}),
    .rd_data           (rd_data)
);

endmodule
