//--------------------------------------------------------------------------------------------------------
// 模块： img_byte_uram
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 64位UltraRAM字节写使能封装，对外保持一拍字节读取
// 作者： WANG
// 时间： 26.10.22
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  img_byte_uram
#(
    parameter integer ADDR_WIDTH = 18
)
(
    input   wire                   sys_clk,
    input   wire                   wr_en,
    input   wire [ADDR_WIDTH-1:0]  wr_addr,
    input   wire [7:0]            wr_data,
    input   wire [ADDR_WIDTH-1:0]  rd_addr,
    output  wire [7:0]            rd_data
);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//wire  define
wire [63:0] word_data;
wire [7:0]  byte_enable;
//reg   define
reg  [2:0]  rd_lane;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
assign byte_enable = wr_en ? (8'b00000001 << wr_addr[2:0]) : 8'd0;
assign rd_data = word_data[rd_lane * 8 +: 8];

always@(posedge sys_clk)
    rd_lane <= rd_addr[2:0];

//********************************************************************//
//*************************** Instantiation **************************//
//********************************************************************//
xpm_memory_sdpram
#(
    .ADDR_WIDTH_A          (ADDR_WIDTH-3),
    .ADDR_WIDTH_B          (ADDR_WIDTH-3),
    .AUTO_SLEEP_TIME       (0),
    .BYTE_WRITE_WIDTH_A    (8),
    .CLOCKING_MODE         ("common_clock"),
    .ECC_MODE              ("no_ecc"),
    .MEMORY_INIT_FILE      ("none"),
    .MEMORY_INIT_PARAM     ("0"),
    .MEMORY_OPTIMIZATION   ("true"),
    .MEMORY_PRIMITIVE      ("ultra"),
    .MEMORY_SIZE           (8 * (2 ** ADDR_WIDTH)),
    .READ_DATA_WIDTH_B     (64),
    .READ_LATENCY_B        (1),
    .READ_RESET_VALUE_B    ("0"),
    .RST_MODE_B            ("SYNC"),
    .SIM_ASSERT_CHK        (1),
    .USE_EMBEDDED_CONSTRAINT (0),
    .USE_MEM_INIT          (0),
    .WAKEUP_TIME           ("disable_sleep"),
    .WRITE_DATA_WIDTH_A    (64),
    .WRITE_MODE_B          ("read_first")
)
memory_inst
(
    .clka                  (sys_clk),
    .clkb                  (sys_clk),
    .ena                   (wr_en),
    .enb                   (1'b1),
    .wea                   (byte_enable),
    .addra                 (wr_addr[ADDR_WIDTH-1:3]),
    .addrb                 (rd_addr[ADDR_WIDTH-1:3]),
    .dina                  ({8{wr_data}}),
    .doutb                 (word_data),
    .regceb                (1'b1),
    .rstb                  (1'b0),
    .sleep                 (1'b0),
    .injectsbiterra        (1'b0),
    .injectdbiterra        (1'b0),
    .sbiterrb              (),
    .dbiterrb              ()
);

endmodule
