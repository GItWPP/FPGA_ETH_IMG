//--------------------------------------------------------------------------------------------------------
// 模块： hog_cell_hist_top
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 逐像素中心差分并累计40×30个九方向cell直方图
// 作者： WANG
// 时间： 26.10.21
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  hog_cell_hist_top
(
    input   wire                   sys_clk                ,
    input   wire                   sys_rst_n              ,
    input   wire                   start_valid            ,
    output  wire                   start_ready            ,
    output  wire                   done_flag              ,
    output  wire           [16:0]  frame_rd_addr          ,
    input   wire           [7:0]   frame_rd_data          ,
    output  wire                   hist_wr_en             ,
    output  wire           [13:0]  hist_wr_addr           ,
    output  wire           [15:0]  hist_wr_data           ,
    output  wire           [13:0]  hist_rd_addr           ,
    input   wire           [15:0]  hist_rd_data
);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//parameter define
localparam [3:0] IDLE             = 4'd0;
localparam [3:0] CLEAR            = 4'd1;
localparam [3:0] LWAIT            = 4'd2;
localparam [3:0] LGET             = 4'd3;
localparam [3:0] RWAIT            = 4'd4;
localparam [3:0] RGET             = 4'd5;
localparam [3:0] UWAIT            = 4'd6;
localparam [3:0] UGET             = 4'd7;
localparam [3:0] DWAIT            = 4'd8;
localparam [3:0] DGET             = 4'd9;
localparam [3:0] PREP             = 4'd10;
localparam [3:0] HWAIT            = 4'd11;
localparam [3:0] HGET             = 4'd12;
localparam [3:0] HWRITE           = 4'd13;
localparam [3:0] FINISH           = 4'd14;
//wire  define
wire           [9:0]   magnitude;
wire           [3:0]   direction;
wire           [16:0]  center_addr;
wire                   last_pixel;
//reg   define
reg            [3:0]   state;
reg            [3:0]   next_state;
reg            [13:0]  clear_addr;
reg            [8:0]   pixel_x;
reg            [7:0]   pixel_y;
reg            [7:0]   pixel_left;
reg            [7:0]   pixel_right;
reg            [7:0]   pixel_up;
reg            [7:0]   pixel_down;
reg            [13:0]  vote_addr;
reg            [9:0]   vote_magnitude;
reg            [15:0]  previous_value;
reg            [16:0]  neighbor_addr;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
assign start_ready = (state == IDLE);
assign done_flag = (state == FINISH);
assign center_addr = {9'd0, pixel_y} * 17'd320 + {8'd0, pixel_x};
assign frame_rd_addr = neighbor_addr;
assign hist_rd_addr = vote_addr;
assign hist_wr_en = (state == CLEAR || state == HWRITE);
assign hist_wr_addr = (state == CLEAR) ? clear_addr : vote_addr;
assign hist_wr_data = (state == CLEAR) ? 16'd0 : previous_value + {6'd0, vote_magnitude};
assign last_pixel = (pixel_x == 9'd319 && pixel_y == 8'd239);

always@(*) begin
    neighbor_addr = center_addr;
    case(state)
        LWAIT, LGET: neighbor_addr = (pixel_x == 9'd0) ? center_addr : center_addr - 1'b1;
        RWAIT, RGET: neighbor_addr = (pixel_x == 9'd319) ? center_addr : center_addr + 1'b1;
        UWAIT, UGET: neighbor_addr = (pixel_y == 8'd0) ? center_addr : center_addr - 17'd320;
        DWAIT, DGET: neighbor_addr = (pixel_y == 8'd239) ? center_addr : center_addr + 17'd320;
        default: neighbor_addr = center_addr;
    endcase
end

always@(*) begin
    next_state = state;
    case(state)
        IDLE: if(start_valid) next_state = CLEAR;
        CLEAR: if(clear_addr == 14'd10799) next_state = LWAIT;
        LWAIT: next_state = LGET;
        LGET: next_state = RWAIT;
        RWAIT: next_state = RGET;
        RGET: next_state = UWAIT;
        UWAIT: next_state = UGET;
        UGET: next_state = DWAIT;
        DWAIT: next_state = DGET;
        DGET: next_state = PREP;
        PREP: next_state = HWAIT;
        HWAIT: next_state = HGET;
        HGET: next_state = HWRITE;
        HWRITE: next_state = last_pixel ? FINISH : LWAIT;
        FINISH: next_state = IDLE;
        default: next_state = IDLE;
    endcase
end

//同步复位控制RAM地址和写使能，不复位任何存储单元
always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        state <= IDLE;
    else
        state <= next_state;

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        clear_addr <= 14'd0;
    else if(state == IDLE)
        clear_addr <= 14'd0;
    else if(state == CLEAR && clear_addr != 14'd10799)
        clear_addr <= clear_addr + 1'b1;

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0) begin
        pixel_x <= 9'd0;
        pixel_y <= 8'd0;
    end else if(state == IDLE) begin
        pixel_x <= 9'd0;
        pixel_y <= 8'd0;
    end else if(state == HWRITE) begin
        if(pixel_x == 9'd319) begin
            pixel_x <= 9'd0;
            pixel_y <= pixel_y + 1'b1;
        end else
            pixel_x <= pixel_x + 1'b1;
    end

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0) begin
        pixel_left <= 8'd0;
        pixel_right <= 8'd0;
        pixel_up <= 8'd0;
        pixel_down <= 8'd0;
    end else begin
        if(state == LGET) pixel_left <= frame_rd_data;
        if(state == RGET) pixel_right <= frame_rd_data;
        if(state == UGET) pixel_up <= frame_rd_data;
        if(state == DGET) pixel_down <= frame_rd_data;
    end

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0) begin
        vote_addr <= 14'd0;
        vote_magnitude <= 10'd0;
    end else if(state == PREP) begin
        vote_addr <= (({9'd0, pixel_y[7:3]} * 14'd40) + {8'd0, pixel_x[8:3]}) * 14'd9 + {10'd0, direction};
        vote_magnitude <= magnitude;
    end

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        previous_value <= 16'd0;
    else if(state == HGET)
        previous_value <= hist_rd_data;

//********************************************************************//
//*************************** Instantiation **************************//
//********************************************************************//
hog_gradient
hog_gradient_inst
(
    .pixel_left            (pixel_left            ),
    .pixel_right           (pixel_right           ),
    .pixel_up              (pixel_up              ),
    .pixel_down            (pixel_down            ),
    .magnitude             (magnitude             ),
    .direction             (direction             )
);
endmodule
