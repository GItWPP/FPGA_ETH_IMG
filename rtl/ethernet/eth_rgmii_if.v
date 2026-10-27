//--------------------------------------------------------------------------------------------------------
// 模块： eth_rgmii_if
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： UltraScale+专用DDR输入输出实现RGMII与8位GMII转换
// 作者： WANG
// 时间： 26.10.22
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  eth_rgmii_if
(
    input   wire                   rx_clk                 ,
    input   wire                   eth_rx_ctl             ,
    input   wire           [3:0]   eth_rxd                ,
    output  wire                   gmii_rx_dv             ,
    output  wire                   gmii_rx_er             ,
    output  wire           [7:0]   gmii_rxd               ,
    input   wire                   tx_clk                 ,
    input   wire                   gmii_tx_en             ,
    input   wire                   gmii_tx_er             ,
    input   wire           [7:0]   gmii_txd               ,
    output  wire                   eth_txc                ,
    output  wire                   eth_tx_ctl             ,
    output  wire           [3:0]   eth_txd
);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//wire  define
wire           [4:0]   rx_ddr_input;
wire           [4:0]   rx_rising_data;
wire           [4:0]   rx_falling_data;
wire           [4:0]   tx_rising_data;
wire           [4:0]   tx_falling_data;
wire           [4:0]   tx_ddr_output;
genvar          lane;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
assign rx_ddr_input = {eth_rx_ctl, eth_rxd};
assign gmii_rx_dv = rx_rising_data[4];
assign gmii_rx_er = rx_rising_data[4] ^ rx_falling_data[4];
assign gmii_rxd = {rx_falling_data[3:0], rx_rising_data[3:0]};
assign tx_rising_data = {gmii_tx_en, gmii_txd[3:0]};
assign tx_falling_data = {gmii_tx_en ^ gmii_tx_er, gmii_txd[7:4]};
assign {eth_tx_ctl, eth_txd} = tx_ddr_output;

//********************************************************************//
//*************************** Instantiation **************************//
//********************************************************************//
generate
    for(lane = 0; lane < 5; lane = lane + 1) begin : rgmii_lane
        IDDRE1
        #(
            .DDR_CLK_EDGE       ("SAME_EDGE_PIPELINED"),
            .IS_C_INVERTED      (1'b0                 ),
            .IS_CB_INVERTED     (1'b1                 )
        )
        rx_ddr_inst
        (
            .C                  (rx_clk                ),
            .CB                 (rx_clk                ),
            .D                  (rx_ddr_input[lane]    ),
            .R                  (1'b0                  ),
            .Q1                 (rx_rising_data[lane]  ),
            .Q2                 (rx_falling_data[lane] )
        );

        ODDRE1
        #(
            .SIM_DEVICE         ("ULTRASCALE_PLUS"     ),
            .SRVAL              (1'b0                  )
        )
        tx_ddr_inst
        (
            .C                  (tx_clk                 ),
            .D1                 (tx_rising_data[lane]   ),
            .D2                 (tx_falling_data[lane]  ),
            .SR                 (1'b0                   ),
            .Q                  (tx_ddr_output[lane]    )
        );
    end
endgenerate

//TXC与数据使用同类DDR输出；所需TX时钟偏移由参考板PHY TXDLY提供
ODDRE1
#(
    .SIM_DEVICE         ("ULTRASCALE_PLUS"  ),
    .SRVAL              (1'b0               )
)
tx_clock_ddr_inst
(
    .C                  (tx_clk             ),
    .D1                 (1'b1               ),
    .D2                 (1'b0               ),
    .SR                 (1'b0               ),
    .Q                  (eth_txc            )
);

endmodule
