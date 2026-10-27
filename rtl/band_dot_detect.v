//--------------------------------------------------------------------------------------------------------
// 模块： band_dot_detect
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 灰度帧局部对比度检测及9x9最小值抑制，输出暗点坐标
// 作者： WANG
// 时间： 26.10.21
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  band_dot_detect
#(
    parameter integer CONTRAST_MIN = 35
)
(
    input   wire            sys_clk        ,
    input   wire            sys_rst_n      ,
    input   wire            start_valid    ,
    output  wire            start_ready    ,
    input   wire    [9:0]   image_width    ,
    input   wire    [9:0]   image_height   ,
    output  wire    [17:0]  frame_rd_addr  ,
    input   wire    [7:0]   frame_rd_data  ,

    output  wire            dot_valid      ,
    output  wire    [8:0]   dot_x          ,
    output  wire    [8:0]   dot_y          ,
    output  wire    [7:0]   dot_contrast   ,
    output  wire            done_flag
);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//parameter define
localparam [3:0] IDLE = 4'd0;
localparam [3:0] CENTER_WAIT = 4'd1;
localparam [3:0] CENTER_GET = 4'd2;
localparam [3:0] RING_WAIT = 4'd3;
localparam [3:0] RING_GET = 4'd4;
localparam [3:0] CONTRAST_CHECK = 4'd5;
localparam [3:0] MIN_WAIT = 4'd6;
localparam [3:0] MIN_GET = 4'd7;
localparam [3:0] EMIT = 4'd8;
localparam [3:0] ADVANCE = 4'd9;
localparam [3:0] FINISH = 4'd10;
//wire  define
wire                    accept_flag;
wire                    min_reject;
wire                    sample_inside;
wire           [8:0]    sample_x;
wire           [8:0]    sample_y;
//reg   define
reg            [3:0]    state;
reg            [3:0]    next_state;
reg            [9:0]    width_reg;
reg            [9:0]    height_reg;
reg            [8:0]    scan_x;
reg            [8:0]    scan_y;
reg            [7:0]    center_data;
reg            [10:0]   ring_sum;
reg            [2:0]    ring_index;
reg            [6:0]    min_index;
reg signed     [11:0]   offset_x;
reg signed     [11:0]   offset_y;
reg signed     [11:0]   request_x;
reg signed     [11:0]   request_y;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
assign start_ready = (state == IDLE);
assign accept_flag = start_valid && start_ready;
assign done_flag = (state == FINISH);
assign dot_valid = (state == EMIT);
assign dot_x = scan_x;
assign dot_y = scan_y;
assign dot_contrast = ring_sum[10:3] - center_data;
assign sample_inside = request_x >= 12'sd0 && request_y >= 12'sd0
                    && request_x < $signed({2'd0, width_reg})
                    && request_y < $signed({2'd0, height_reg});
assign sample_x = (request_x < 12'sd0) ? 9'd0 :
                  (request_x >= $signed({2'd0, width_reg})) ? width_reg[8:0] - 1'b1 : request_x[8:0];
assign sample_y = (request_y < 12'sd0) ? 9'd0 :
                  (request_y >= $signed({2'd0, height_reg})) ? height_reg[8:0] - 1'b1 : request_y[8:0];
assign frame_rd_addr = {sample_y, sample_x};
assign min_reject = sample_inside && min_index != 7'd40
                 && ((min_index < 7'd40) ? frame_rd_data <= center_data : frame_rd_data < center_data);

//环形采样在边缘复制像素；最小值比较忽略越界位置
always@(*) begin
    offset_x = 12'sd0;
    offset_y = 12'sd0;
    if(state == RING_WAIT || state == RING_GET)
        case(ring_index)
            3'd0: offset_x = -12'sd4;
            3'd1: offset_x = 12'sd4;
            3'd2: offset_y = -12'sd4;
            3'd3: offset_y = 12'sd4;
            3'd4: begin
                offset_x = -12'sd3;
                offset_y = -12'sd3;
            end
            3'd5: begin
                offset_x = 12'sd3;
                offset_y = -12'sd3;
            end
            3'd6: begin
                offset_x = -12'sd3;
                offset_y = 12'sd3;
            end
            default: begin
                offset_x = 12'sd3;
                offset_y = 12'sd3;
            end
        endcase
    else if(state == MIN_WAIT || state == MIN_GET) begin
        offset_x = $signed({5'd0, min_index % 7'd9}) - 12'sd4;
        offset_y = $signed({5'd0, min_index / 7'd9}) - 12'sd4;
    end
    request_x = $signed({3'd0, scan_x}) + offset_x;
    request_y = $signed({3'd0, scan_y}) + offset_y;
end

always@(*) begin
    next_state = state;
    case(state)
        IDLE: if(start_valid) next_state = CENTER_WAIT;
        CENTER_WAIT: next_state = CENTER_GET;
        CENTER_GET: next_state = RING_WAIT;
        RING_WAIT: next_state = RING_GET;
        RING_GET: next_state = (ring_index == 3'd7) ? CONTRAST_CHECK : RING_WAIT;
        CONTRAST_CHECK: next_state = ({3'd0, ring_sum[10:3]} >= {3'd0, center_data} + CONTRAST_MIN) ? MIN_WAIT : ADVANCE;
        MIN_WAIT: next_state = MIN_GET;
        MIN_GET: begin
            if(min_reject)
                next_state = ADVANCE;
            else
                next_state = (min_index == 7'd80) ? EMIT : MIN_WAIT;
        end
        EMIT: next_state = ADVANCE;
        ADVANCE: next_state = ({1'b0, scan_x} + 10'd1 == width_reg &&
                              {1'b0, scan_y} + 10'd1 == height_reg) ? FINISH : CENTER_WAIT;
        FINISH: next_state = IDLE;
        default: next_state = IDLE;
    endcase
end

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        state <= IDLE;
    else
        state <= next_state;

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0) begin
        width_reg <= 10'd512;
        height_reg <= 10'd512;
    end else if(accept_flag) begin
        width_reg <= image_width;
        height_reg <= image_height;
    end

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0) begin
        scan_x <= 9'd0;
        scan_y <= 9'd0;
    end else if(accept_flag) begin
        scan_x <= 9'd0;
        scan_y <= 9'd0;
    end else if(state == ADVANCE) begin
        if({1'b0, scan_x} + 10'd1 == width_reg) begin
            scan_x <= 9'd0;
            scan_y <= scan_y + 1'b1;
        end else
            scan_x <= scan_x + 1'b1;
    end

always@(posedge sys_clk)
    if(state == CENTER_GET)
        center_data <= frame_rd_data;

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0) begin
        ring_index <= 3'd0;
        ring_sum <= 11'd0;
    end else if(state == CENTER_GET) begin
        ring_index <= 3'd0;
        ring_sum <= 11'd0;
    end else if(state == RING_GET) begin
        ring_index <= ring_index + 1'b1;
        ring_sum <= ring_sum + {3'd0, frame_rd_data};
    end

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        min_index <= 7'd0;
    else if(state == CONTRAST_CHECK)
        min_index <= 7'd0;
    else if(state == MIN_GET)
        min_index <= min_index + 1'b1;

endmodule
