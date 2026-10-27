//--------------------------------------------------------------------------------------------------------
// 模块： img_dual_clock_buffer
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 双时钟1024字节请求或结果缓存，读端固定一周期延迟
// 作者： WANG
// 时间： 26.10.23
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  img_dual_clock_buffer
(
    input   wire                   wr_clk                 ,
    input   wire                   wr_en                  ,
    input   wire           [9:0]   wr_addr                ,
    input   wire           [7:0]   wr_data                ,

    input   wire                   rd_clk                 ,
    input   wire           [9:0]   rd_addr                ,
    output  wire           [7:0]   rd_data
);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
// 固定容量1024字节；数据所有权由外部描述符握手管理

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
// 双时钟RAM不复位数据，读使能由完整结果的有效描述符约束

//********************************************************************//
//*************************** Instantiation **************************//
//********************************************************************//
xpm_memory_sdpram
#(
    .ADDR_WIDTH_A           (10),
    .ADDR_WIDTH_B           (10),
    .AUTO_SLEEP_TIME        (0),
    .BYTE_WRITE_WIDTH_A     (8),
    .CLOCKING_MODE          ("independent_clock"),
    .ECC_MODE               ("no_ecc"),
    .MEMORY_INIT_FILE       ("none"),
    .MEMORY_INIT_PARAM      ("0"),
    .MEMORY_OPTIMIZATION    ("true"),
    .MEMORY_PRIMITIVE       ("block"),
    .MEMORY_SIZE            (8192),
    .MESSAGE_CONTROL        (0),
    .READ_DATA_WIDTH_B      (8),
    .READ_LATENCY_B         (1),
    .READ_RESET_VALUE_B     ("0"),
    .RST_MODE_B             ("SYNC"),
    .SIM_ASSERT_CHK         (1),
    .USE_EMBEDDED_CONSTRAINT (0),
    .USE_MEM_INIT           (0),
    .WAKEUP_TIME            ("disable_sleep"),
    .WRITE_DATA_WIDTH_A     (8),
    .WRITE_MODE_B           ("read_first")
)
packet_ram_inst
(
    .clka                   (wr_clk),
    .ena                    (wr_en),
    .wea                    (wr_en),
    .addra                  (wr_addr),
    .dina                   (wr_data),
    .clkb                   (rd_clk),
    .enb                    (1'b1),
    .addrb                  (rd_addr),
    .doutb                  (rd_data),
    .rstb                   (1'b0),
    .regceb                 (1'b1),
    .sleep                  (1'b0),
    .injectsbiterra         (1'b0),
    .injectdbiterra         (1'b0),
    .sbiterrb               (),
    .dbiterrb               ()
);

endmodule
