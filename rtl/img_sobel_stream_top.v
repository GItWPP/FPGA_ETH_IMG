//--------------------------------------------------------------------------------------------------------
// 模块： img_sobel_stream_top
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 两行XPM缓存与全流水Sobel，输入RGB565边界扩展流，输出GRAY8
// 作者： WANG
// 时间： 26.10.23
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module img_sobel_stream_top
(
    input   wire            sys_clk,
    input   wire            sys_rst_n,
    input   wire            frame_start,
    input   wire [15:0]     frame_width,
    input   wire [15:0]     frame_height,
    input   wire            pixel_valid,
    input   wire [15:0]     pixel_data,
    output  reg             gray_valid,
    output  reg  [7:0]      gray_data
);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//wire  define
wire [7:0] red_data;
wire [7:0] green_data;
wire [7:0] blue_data;
wire [7:0] row_data [0:1];
wire [7:0] top_right;
wire [7:0] mid_right;
wire signed [11:0] grad_x;
wire signed [11:0] grad_y;
wire [11:0] abs_x;
wire [11:0] abs_y;
wire [12:0] magnitude;
//reg   define
reg [15:0] pixel_x;
reg [15:0] pixel_y;
reg [15:0] gray_sum;
reg [15:0] x_dly1;
reg [15:0] y_dly1;
reg [15:0] x_dly2;
reg [15:0] y_dly2;
reg [7:0] gray_dly2;
reg valid_dly1;
reg valid_dly2;
reg valid_dly3;
reg signed [11:0] grad_x_reg;
reg signed [11:0] grad_y_reg;
reg [7:0] top_left;
reg [7:0] top_mid;
reg [7:0] mid_left;
reg [7:0] mid_mid;
reg [7:0] bot_left;
reg [7:0] bot_mid;
genvar row_bank;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
assign red_data = {pixel_data[15:11],pixel_data[15:13]};
assign green_data = {pixel_data[10:5],pixel_data[10:9]};
assign blue_data = {pixel_data[4:0],pixel_data[4:2]};
assign mid_right = (y_dly2 == 16'd0) ? gray_dly2 : row_data[!y_dly2[0]];
assign top_right = (y_dly2 < 16'd2) ? mid_right : row_data[y_dly2[0]];
assign grad_x = $signed({4'd0,top_right}) + ($signed({4'd0,mid_right}) <<< 1)
              + $signed({4'd0,gray_dly2}) - $signed({4'd0,top_left})
              - ($signed({4'd0,mid_left}) <<< 1) - $signed({4'd0,bot_left});
assign grad_y = $signed({4'd0,bot_left}) + ($signed({4'd0,bot_mid}) <<< 1)
              + $signed({4'd0,gray_dly2}) - $signed({4'd0,top_left})
              - ($signed({4'd0,top_mid}) <<< 1) - $signed({4'd0,top_right});
assign abs_x = grad_x_reg[11] ? -grad_x_reg : grad_x_reg;
assign abs_y = grad_y_reg[11] ? -grad_y_reg : grad_y_reg;
assign magnitude = {1'b0,abs_x} + {1'b0,abs_y};

//上传包含右边界一列及下边界一行，计数仅在像素有效时推进
always@(posedge sys_clk)
    if(!sys_rst_n || frame_start) begin
        pixel_x <= 16'd0;
        pixel_y <= 16'd0;
    end else if(pixel_valid) begin
        if(pixel_x == frame_width) begin
            pixel_x <= 16'd0;
            pixel_y <= pixel_y + 1'b1;
        end else
            pixel_x <= pixel_x + 1'b1;
    end

//亮度系数与旧Sobel保持一致，最大加权和65280
always@(posedge sys_clk)
    if(pixel_valid) begin
        gray_sum <= red_data * 16'd77 + green_data * 16'd150 + blue_data * 16'd29;
        x_dly1 <= pixel_x;
        y_dly1 <= pixel_y;
    end

always@(posedge sys_clk)
    if(valid_dly1) begin
        gray_dly2 <= gray_sum[15:8];
        x_dly2 <= x_dly1;
        y_dly2 <= y_dly1;
    end

always@(posedge sys_clk)
    if(!sys_rst_n || frame_start) begin
        valid_dly1 <= 1'b0;
        valid_dly2 <= 1'b0;
        valid_dly3 <= 1'b0;
        gray_valid <= 1'b0;
    end else begin
        valid_dly1 <= pixel_valid;
        valid_dly2 <= valid_dly1;
        valid_dly3 <= valid_dly2 && x_dly2 != 16'd0 && y_dly2 != 16'd0
                      && y_dly2 <= frame_height;
        gray_valid <= valid_dly3;
    end

//每行首点初始化横向窗口，实现左边界复制，空拍时保留窗口
always@(posedge sys_clk)
    if(valid_dly2) begin
        top_left <= (x_dly2 == 16'd0) ? top_right : top_mid;
        top_mid <= top_right;
        mid_left <= (x_dly2 == 16'd0) ? mid_right : mid_mid;
        mid_mid <= mid_right;
        bot_left <= (x_dly2 == 16'd0) ? gray_dly2 : bot_mid;
        bot_mid <= gray_dly2;
    end

always@(posedge sys_clk)
    if(valid_dly2) begin
        grad_x_reg <= grad_x;
        grad_y_reg <= grad_y;
    end

always@(posedge sys_clk)
    if(valid_dly3)
        gray_data <= (magnitude > 13'd255) ? 8'd255 : magnitude[7:0];

//********************************************************************//
//*************************** Instantiation **************************//
//********************************************************************//
generate
    for(row_bank = 0; row_bank < 2; row_bank = row_bank + 1) begin : line_buffer
        xpm_memory_sdpram
        #(
            .ADDR_WIDTH_A           (11),
            .ADDR_WIDTH_B           (11),
            .AUTO_SLEEP_TIME        (0),
            .BYTE_WRITE_WIDTH_A     (8),
            .CLOCKING_MODE          ("common_clock"),
            .ECC_MODE               ("no_ecc"),
            .MEMORY_INIT_FILE       ("none"),
            .MEMORY_INIT_PARAM      ("0"),
            .MEMORY_OPTIMIZATION    ("true"),
            .MEMORY_PRIMITIVE       ("block"),
            .MEMORY_SIZE            (16384),
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
        row_ram_inst
        (
            .clka                   (sys_clk),
            .ena                    (valid_dly1),
            .wea                    (y_dly1[0] == row_bank),
            .addra                  (x_dly1[10:0]),
            .dina                   (gray_sum[15:8]),
            .clkb                   (sys_clk),
            .enb                    (valid_dly1),
            .addrb                  (x_dly1[10:0]),
            .doutb                  (row_data[row_bank]),
            .rstb                   (1'b0),
            .regceb                 (1'b1),
            .sleep                  (1'b0),
            .injectsbiterra         (1'b0),
            .injectdbiterra         (1'b0),
            .sbiterrb               (),
            .dbiterrb               ()
        );
    end
endgenerate

endmodule
