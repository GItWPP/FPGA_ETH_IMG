//--------------------------------------------------------------------------------------------------------
// 模块： eth_img_top
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： ZU4EV千兆以太网图像工作台顶层，时钟、RGMII及处理核心连接
// 作者： WANG
// 时间： 26.10.22
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  eth_img_top
#(
    parameter LOCAL_MAC = 48'h02_55_49_4d_47_04,
    parameter LOCAL_IP = {8'd192,8'd168,8'd1,8'd12},
    parameter LOCAL_PORT = 16'd1234
)
(
    input   wire            sys_rst_n       ,
    input   wire            eth_rxc         ,
    input   wire            eth_rx_ctl      ,
    input   wire    [3:0]   eth_rxd         ,
    output  wire            eth_txc         ,
    output  wire            eth_tx_ctl      ,
    output  wire    [3:0]   eth_txd         ,
    output  wire            eth_rst_n       ,
    output  wire    [3:0]   led_ctrl
);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//wire  define
wire            rx_clk;
wire            tx_clk;
wire            app_clk;
wire            algo_clk;
wire            locked;
wire            logic_rst_n;
wire            gmii_rx_dv;
wire            gmii_rx_er;
wire    [7:0]   gmii_rxd;
wire            gmii_tx_en;
wire            gmii_tx_er;
wire    [7:0]   gmii_txd;
wire            rx_packet_done;
wire            rx_packet_error;
wire            rx_drop_flag;
wire            tx_packet_done;
wire            tx_busy;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
assign eth_rst_n = sys_rst_n;
assign logic_rst_n = sys_rst_n && locked;
assign led_ctrl = {rx_drop_flag | rx_packet_error, tx_busy, locked, rx_packet_done};

//********************************************************************//
//*************************** Instantiation **************************//
//********************************************************************//
BUFG eth_rx_clock_bufg_inst
(
    .I                  (eth_rxc            ),
    .O                  (rx_clk             )
);

clk_wiz_eth clk_wiz_eth_inst
(
    .clk_in1            (rx_clk             ),
    .reset              (!sys_rst_n         ),
    .clk_out1           (tx_clk             ),
    .clk_out2           (algo_clk           ),
    .clk_out3           (app_clk            ),
    .locked             (locked             )
);

eth_rgmii_if eth_rgmii_if_inst
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

eth_image_core
#(
    .LOCAL_MAC          (LOCAL_MAC          ),
    .LOCAL_IP           (LOCAL_IP           ),
    .LOCAL_PORT         (LOCAL_PORT         ),
    .ASYNC_ALGORITHMS   (1                  )
)
eth_image_core_inst
(
    .sys_rst_n          (logic_rst_n        ),
    .gmii_rx_clk        (rx_clk             ),
    .gmii_rx_dv         (gmii_rx_dv         ),
    .gmii_rx_er         (gmii_rx_er         ),
    .gmii_rxd           (gmii_rxd           ),
    .gmii_tx_clk        (tx_clk             ),
    .gmii_tx_en         (gmii_tx_en         ),
    .gmii_tx_er         (gmii_tx_er         ),
    .gmii_txd           (gmii_txd           ),
    .app_clk            (app_clk            ),
    .algo_clk           (algo_clk           ),
    .rx_packet_done     (rx_packet_done     ),
    .rx_packet_error    (rx_packet_error    ),
    .rx_drop_flag       (rx_drop_flag       ),
    .tx_packet_done     (tx_packet_done     ),
    .tx_busy            (tx_busy            )
);

endmodule
