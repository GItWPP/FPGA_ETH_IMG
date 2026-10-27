//--------------------------------------------------------------------------------------------------------
// 模块： img_async_fifo
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 采用XPM异步FIFO传递完整描述符，复位忙期间禁止握手
// 作者： WANG
// 时间： 26.10.23
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  img_async_fifo
#(
    parameter integer DATA_WIDTH = 72
)
(
    input   wire                             wr_clk                 ,
    input   wire                             wr_rst_n               ,
    input   wire           [DATA_WIDTH-1:0]  wr_data                ,
    input   wire                             wr_valid               ,
    output  wire                             wr_ready               ,

    input   wire                             rd_clk                 ,
    input   wire                             rd_rst_n               ,
    output  wire           [DATA_WIDTH-1:0]  rd_data                ,
    output  wire                             rd_valid               ,
    input   wire                             rd_ready
);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//wire  define
wire                             fifo_full;
wire                             fifo_empty;
wire                             wr_reset_busy;
wire                             rd_reset_busy;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
assign wr_ready = wr_rst_n && !wr_reset_busy && !fifo_full;
assign rd_valid = rd_rst_n && !rd_reset_busy && !fifo_empty;

//********************************************************************//
//*************************** Instantiation **************************//
//********************************************************************//
xpm_fifo_async
#(
    .CDC_SYNC_STAGES         (3),
    .DOUT_RESET_VALUE        ("0"),
    .ECC_MODE               ("no_ecc"),
    .FIFO_MEMORY_TYPE       ("distributed"),
    .FIFO_READ_LATENCY      (0),
    .FIFO_WRITE_DEPTH       (16),
    .FULL_RESET_VALUE       (0),
    .PROG_EMPTY_THRESH      (5),
    .PROG_FULL_THRESH       (11),
    .RD_DATA_COUNT_WIDTH    (5),
    .READ_DATA_WIDTH        (DATA_WIDTH),
    .READ_MODE              ("fwft"),
    .RELATED_CLOCKS         (0),
    .SIM_ASSERT_CHK         (1),
    .USE_ADV_FEATURES       ("0000"),
    .WAKEUP_TIME            (0),
    .WRITE_DATA_WIDTH       (DATA_WIDTH),
    .WR_DATA_COUNT_WIDTH    (5)
)
descriptor_fifo_inst
(
    .rst                    (!wr_rst_n),
    .wr_clk                 (wr_clk),
    .wr_en                  (wr_valid && wr_ready),
    .din                    (wr_data),
    .full                   (fifo_full),
    .wr_rst_busy            (wr_reset_busy),
    .rd_clk                 (rd_clk),
    .rd_en                  (rd_valid && rd_ready),
    .dout                   (rd_data),
    .empty                  (fifo_empty),
    .rd_rst_busy            (rd_reset_busy),
    .sleep                  (1'b0),
    .injectsbiterr          (1'b0),
    .injectdbiterr          (1'b0),
    .almost_empty           (),
    .almost_full            (),
    .data_valid             (),
    .dbiterr                (),
    .overflow               (),
    .prog_empty             (),
    .prog_full              (),
    .rd_data_count          (),
    .sbiterr                (),
    .underflow              (),
    .wr_ack                 (),
    .wr_data_count          ()
);

endmodule
