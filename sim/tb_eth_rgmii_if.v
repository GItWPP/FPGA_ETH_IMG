//--------------------------------------------------------------------------------------------------------
// 模块： tb_eth_rgmii_if
// Type    : simulation
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 使用官方DDR原语模型验证RGMII半字节顺序及EN/ER控制编码
// 作者： WANG
// 时间： 26.10.22
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  tb_eth_rgmii_if();

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//parameter define
localparam integer BYTE_COUNT = 32;

//wire  define
wire            gmii_rx_dv;
wire            gmii_rx_er;
wire    [7:0]   gmii_rxd;
wire            eth_txc;
wire            eth_tx_ctl;
wire    [3:0]   eth_txd;

//reg   define
reg             rx_clk = 1'b0;
reg             tx_clk = 1'b0;
reg             eth_rx_ctl = 1'b0;
reg     [3:0]   eth_rxd = 4'd0;
reg             gmii_tx_en = 1'b0;
reg             gmii_tx_er = 1'b0;
reg     [7:0]   gmii_txd = 8'd0;
reg             rx_done = 1'b0;
reg             tx_done = 1'b0;
integer         rx_index = 0;
integer         send_index;
integer         tx_index;
reg     [7:0]   rx_value;
reg     [7:0]   expected_rx;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
always #4 rx_clk = ~rx_clk;
always #4 tx_clk = ~tx_clk;

always@(negedge rx_clk) begin
    #1;
    if(gmii_rx_dv === 1'b1) begin
        expected_rx = (rx_index * 7 + 18) & 255;
        if(gmii_rxd !== expected_rx || gmii_rx_er !== ((rx_index % 7) == 3))
            $fatal(1, "RGMII RX byte/error mismatch index=%d got=%h",rx_index,gmii_rxd);
        rx_index = rx_index + 1;
    end
end

initial begin
    #240;
    @(negedge rx_clk);
    #1;
    for(send_index = 0; send_index < BYTE_COUNT; send_index = send_index + 1) begin
        rx_value = (send_index * 7 + 18) & 255;
        eth_rx_ctl = 1'b1;
        eth_rxd = rx_value[3:0];
        @(posedge rx_clk);
        #1;
        eth_rx_ctl = 1'b1 ^ ((send_index % 7) == 3);
        eth_rxd = rx_value[7:4];
        @(negedge rx_clk);
        #1;
    end
    eth_rx_ctl = 1'b0;
    eth_rxd = 4'd0;
    repeat(6) @(negedge rx_clk);
    if(rx_index != BYTE_COUNT)
        $fatal(1, "RGMII RX byte count mismatch %d",rx_index);
    rx_done = 1'b1;
end

initial begin
    #240;
    @(negedge tx_clk);
    #1;
    for(tx_index = 0; tx_index < BYTE_COUNT; tx_index = tx_index + 1) begin
        gmii_txd = (tx_index * 13 + 92) & 255;
        gmii_tx_en = 1'b1;
        gmii_tx_er = ((tx_index % 5) == 2);
        @(posedge tx_clk);
        #1;
        if(eth_txc !== 1'b1 || eth_txd !== gmii_txd[3:0] || eth_tx_ctl !== gmii_tx_en)
            $fatal(1, "RGMII TX rising-edge mismatch %d",tx_index);
        @(negedge tx_clk);
        #1;
        if(eth_txc !== 1'b0 || eth_txd !== gmii_txd[7:4] || eth_tx_ctl !== (gmii_tx_en ^ gmii_tx_er))
            $fatal(1, "RGMII TX falling-edge mismatch %d",tx_index);
    end
    gmii_tx_en = 1'b0;
    gmii_tx_er = 1'b0;
    tx_done = 1'b1;
end

initial begin
    wait(rx_done && tx_done);
    $display("PASS tb_eth_rgmii_if: 32 RX/TX bytes, nibble order, RX_ER, TX_ER and forwarded clock");
    $finish;
end

initial begin
    #10000;
    $fatal(1, "RGMII simulation timeout");
end

//********************************************************************//
//*************************** Instantiation **************************//
//********************************************************************//
eth_rgmii_if dut
(
    .rx_clk             (rx_clk             ),
    .eth_rx_ctl         (eth_rx_ctl         ),
    .eth_rxd            (eth_rxd            ),
    .gmii_rx_dv         (gmii_rx_dv         ),
    .gmii_rx_er         (gmii_rx_er         ),
    .gmii_rxd           (gmii_rxd           ),
    .tx_clk             (tx_clk             ),
    .gmii_tx_en         (gmii_tx_en         ),
    .gmii_tx_er         (gmii_tx_er         ),
    .gmii_txd           (gmii_txd           ),
    .eth_txc            (eth_txc            ),
    .eth_tx_ctl         (eth_tx_ctl         ),
    .eth_txd            (eth_txd            )
);

endmodule
