//--------------------------------------------------------------------------------------------------------
// 模块： band_grid_track
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 最长数据带选择、双同步行点距估计、逐行相位拟合及二进制采样
// 作者： WANG
// 时间： 26.10.21
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  band_grid_track
(
    input   wire            sys_clk        ,
    input   wire            sys_rst_n      ,
    input   wire            start_flag     ,
    input   wire    [9:0]   image_width    ,
    input   wire    [6:0]   stored_rows    ,
    input   wire            overflow_flag  ,
    output  wire    [5:0]   row_rd_addr    ,
    input   wire    [43:0]  row_rd_data    ,
    output  wire    [10:0]  dot_rd_addr    ,
    input   wire    [25:0]  dot_rd_data    ,

    output  wire            result_wr_en   ,
    output  wire    [11:0]  result_wr_addr ,
    output  wire    [31:0]  result_wr_data ,
    output  reg     [15:0]  result_count   ,
    output  reg     [7:0]   result_rows    ,
    output  reg     [15:0]  pitch_q8       ,
    output  reg     [7:0]   result_status  ,
    output  wire            done_flag
);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//parameter define
localparam [5:0] IDLE = 6'd0;
localparam [5:0] META_WAIT = 6'd1;
localparam [5:0] META_GET = 6'd2;
localparam [5:0] YDIV_REQ = 6'd3;
localparam [5:0] YDIV_WAIT = 6'd4;
localparam [5:0] SELECT_BAND = 6'd5;
localparam [5:0] SYNC_INIT = 6'd6;
localparam [5:0] SYNC_WAIT = 6'd7;
localparam [5:0] SYNC_GET = 6'd8;
localparam [5:0] SYNC_END = 6'd9;
localparam [5:0] PDIV_REQ = 6'd10;
localparam [5:0] PDIV_WAIT = 6'd11;
localparam [5:0] PHASE_CLEAR = 6'd12;
localparam [5:0] PHASE_INIT = 6'd13;
localparam [5:0] PHASE_WAIT = 6'd14;
localparam [5:0] PHASE_GET = 6'd15;
localparam [5:0] PHASE_MOD = 6'd16;
localparam [5:0] PHASE_ADD = 6'd17;
localparam [5:0] HIST_INIT = 6'd18;
localparam [5:0] HIST_SCAN = 6'd19;
localparam [5:0] REF_INIT = 6'd20;
localparam [5:0] REF_WAIT = 6'd21;
localparam [5:0] REF_GET = 6'd22;
localparam [5:0] REF_MOD = 6'd23;
localparam [5:0] REF_ADD = 6'd24;
localparam [5:0] RDIV_REQ = 6'd25;
localparam [5:0] RDIV_WAIT = 6'd26;
localparam [5:0] CELL_INIT = 6'd27;
localparam [5:0] CELL_WAIT = 6'd28;
localparam [5:0] CELL_GET = 6'd29;
localparam [5:0] CELL_EVAL = 6'd30;
localparam [5:0] CELL_WRITE = 6'd31;
localparam [5:0] CELL_ADVANCE = 6'd32;
localparam [5:0] ROW_END = 6'd33;
localparam [5:0] FINISH = 6'd34;
//wire  define
wire                    point_y_ok;
wire                    last_point;
wire                    break_segment;
wire           [6:0]    candidate_length;
wire                    div_in_valid;
wire                    div_in_ready;
wire                    div_out_valid;
wire           [25:0]   div_quotient;
wire signed    [18:0]   raw_delta;
wire signed    [18:0]   point_x_q8;
wire signed    [18:0]   point_distance;
wire signed    [10:0]   rounded_x;
wire                    cell_inside;
wire                    cell_accept;
wire                    partial_flag;
wire                    sync_flag;
wire                    low_flag;
wire           [8:0]    clipped_x;
wire signed    [18:0]   next_grid_x;
wire signed    [18:0]   final_grid_x;
wire                    sync_bad;
//reg   define
reg            [5:0]    state;
reg            [5:0]    next_state;
reg            [9:0]    width_reg;
reg            [6:0]    rows_reg;
reg            [5:0]    row_index;
reg            [5:0]    relative_row;
reg            [11:0]   dot_index;
reg            [20:0]   meta_sum_y;
reg            [11:0]   meta_count;
reg            [10:0]   meta_start;
reg            [10:0]   row_start [0:63];
reg            [11:0]   row_points [0:63];
reg            [8:0]    row_y [0:63];
reg            [8:0]    previous_y;
reg            [5:0]    segment_first;
reg            [6:0]    segment_length;
reg            [5:0]    best_first;
reg            [6:0]    best_length;
reg            [5:0]    band_first;
reg            [6:0]    band_length;
reg                     sync_second;
reg            [11:0]   sync_points;
reg            [8:0]    min_x;
reg            [8:0]    max_x;
reg            [10:0]   span_sum;
reg            [12:0]   interval_sum;
reg            [4:0]    hist_index;
reg            [11:0]   phase_hist [0:31];
reg            [11:0]   hist_max;
reg            [4:0]    best_bin;
reg            [17:0]   remainder_reg;
reg                     point_inside;
reg            [11:0]   valid_points;
reg signed     [23:0]   residual_sum;
reg            [11:0]   inlier_count;
reg            [15:0]   phase_base;
reg signed     [18:0]   adjusted_delta;
reg signed     [18:0]   adjusted_phase;
reg            [15:0]   normalized_phase;
reg signed     [18:0]   grid_x;
reg                     cell_match;
reg            [7:0]    match_contrast;
reg            [7:0]    row_cell_count;
reg            [7:0]    row_one_count;
reg            [25:0]   div_numerator;
reg            [16:0]   div_denominator;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
assign row_rd_addr = row_index;
assign dot_rd_addr = row_start[row_index] + dot_index[10:0];
assign point_y_ok = {1'b0, dot_rd_data[17:9]} + 10'd3 >= {1'b0, row_y[row_index]}
                && {1'b0, dot_rd_data[17:9]} <= {1'b0, row_y[row_index]} + 10'd3;
assign last_point = dot_index + 12'd1 == row_points[row_index];
assign break_segment = row_index == 6'd0 || {1'b0, div_quotient[8:0]} > {1'b0, previous_y} + 10'd24;
assign candidate_length = break_segment ? 7'd1 : segment_length + 1'b1;
assign div_in_valid = state == YDIV_REQ || state == PDIV_REQ || (state == RDIV_REQ && inlier_count != 12'd0);
assign raw_delta = $signed({1'b0, remainder_reg}) - $signed({3'd0, phase_base});
assign point_x_q8 = $signed({2'd0, dot_rd_data[8:0], 8'd0});
assign point_distance = point_x_q8 - grid_x;
assign rounded_x = (grid_x + 19'sd128) >>> 8;
assign cell_inside = rounded_x >= 11'sd0 && rounded_x < $signed({1'b0, width_reg});
assign cell_accept = cell_inside || (cell_match && rounded_x >= -11'sd3 && rounded_x <= $signed({1'b0, width_reg}) + 11'sd2);
assign partial_flag = rounded_x < 11'sd3 || rounded_x > $signed({1'b0, width_reg}) - 11'sd4;
assign sync_flag = {1'b0, relative_row} + 7'd2 >= band_length;
assign low_flag = partial_flag || ({2'd0, inlier_count} << 2) < ({2'd0, valid_points} * 14'd3)
               || (cell_match && match_contrast < 8'd45);
assign clipped_x = (rounded_x < 11'sd0) ? 9'd0 :
                   (rounded_x >= $signed({1'b0, width_reg})) ? width_reg[8:0] - 1'b1 : rounded_x[8:0];
assign next_grid_x = grid_x + $signed({3'd0, pitch_q8});
assign final_grid_x = $signed({1'b0, width_reg, 8'd0}) + 19'sd512;
assign sync_bad = sync_flag && ({4'd0, row_one_count} * 12'd10 < {4'd0, row_cell_count} * 12'd9);
assign result_wr_en = state == CELL_WRITE;
assign result_wr_addr = result_count[11:0];
assign result_wr_data = {4'd0, relative_row, low_flag, partial_flag, sync_flag, cell_match, row_y[row_index], clipped_x};
assign done_flag = state == FINISH;

//定点相位残差做圆周展开，除法仅在每行拟合结束时迭代一次
always@(*) begin
    adjusted_delta = raw_delta;
    if(raw_delta > $signed({4'd0, pitch_q8[15:1]}))
        adjusted_delta = raw_delta - $signed({3'd0, pitch_q8});
    else if(raw_delta < -$signed({4'd0, pitch_q8[15:1]}))
        adjusted_delta = raw_delta + $signed({3'd0, pitch_q8});
    adjusted_phase = $signed({3'd0, phase_base});
    if(residual_sum[23])
        adjusted_phase = adjusted_phase - $signed({3'd0, div_quotient[15:0]});
    else
        adjusted_phase = adjusted_phase + $signed({3'd0, div_quotient[15:0]});
    if(adjusted_phase < 19'sd0)
        normalized_phase = adjusted_phase + $signed({3'd0, pitch_q8});
    else if(adjusted_phase >= $signed({3'd0, pitch_q8}))
        normalized_phase = adjusted_phase - $signed({3'd0, pitch_q8});
    else
        normalized_phase = adjusted_phase[15:0];
end

always@(*) begin
    div_numerator = {5'd0, meta_sum_y};
    div_denominator = {5'd0, meta_count};
    if(state == PDIV_REQ) begin
        div_numerator = {7'd0, span_sum, 8'd0};
        div_denominator = {4'd0, interval_sum};
    end else if(state == RDIV_REQ) begin
        div_numerator = residual_sum[23] ? {2'd0, -residual_sum} : {2'd0, residual_sum};
        div_denominator = {5'd0, inlier_count};
    end
end

always@(*) begin
    next_state = state;
    case(state)
        IDLE: if(start_flag) next_state = (overflow_flag || stored_rows < 7'd4) ? FINISH : META_WAIT;
        META_WAIT: next_state = META_GET;
        META_GET: next_state = YDIV_REQ;
        YDIV_REQ: if(div_in_ready) next_state = YDIV_WAIT;
        YDIV_WAIT: if(div_out_valid) next_state = ({1'b0, row_index} + 7'd1 == rows_reg) ? SELECT_BAND : META_WAIT;
        SELECT_BAND: next_state = (best_length < 7'd4) ? FINISH : SYNC_INIT;
        SYNC_INIT: next_state = SYNC_WAIT;
        SYNC_WAIT: next_state = SYNC_GET;
        SYNC_GET: next_state = last_point ? SYNC_END : SYNC_WAIT;
        SYNC_END: next_state = (sync_points < 12'd8) ? FINISH : (sync_second ? PDIV_REQ : SYNC_INIT);
        PDIV_REQ: if(div_in_ready) next_state = PDIV_WAIT;
        PDIV_WAIT: if(div_out_valid) next_state = (div_quotient < 26'd2048 || div_quotient > 26'd8192) ? FINISH : PHASE_CLEAR;
        PHASE_CLEAR: if(hist_index == 5'd31) next_state = PHASE_INIT;
        PHASE_INIT: next_state = PHASE_WAIT;
        PHASE_WAIT: next_state = PHASE_GET;
        PHASE_GET: next_state = point_y_ok ? PHASE_MOD : PHASE_ADD;
        PHASE_MOD: if(remainder_reg < {2'd0, pitch_q8}) next_state = PHASE_ADD;
        PHASE_ADD: next_state = last_point ? HIST_INIT : PHASE_WAIT;
        HIST_INIT: next_state = HIST_SCAN;
        HIST_SCAN: if(hist_index == 5'd31) next_state = REF_INIT;
        REF_INIT: next_state = REF_WAIT;
        REF_WAIT: next_state = REF_GET;
        REF_GET: next_state = point_y_ok ? REF_MOD : REF_ADD;
        REF_MOD: if(remainder_reg < {2'd0, pitch_q8}) next_state = REF_ADD;
        REF_ADD: next_state = last_point ? RDIV_REQ : REF_WAIT;
        RDIV_REQ: begin
            if(inlier_count == 12'd0) next_state = FINISH;
            else if(div_in_ready) next_state = RDIV_WAIT;
        end
        RDIV_WAIT: if(div_out_valid) next_state = CELL_INIT;
        CELL_INIT: next_state = CELL_WAIT;
        CELL_WAIT: next_state = CELL_GET;
        CELL_GET: next_state = last_point ? CELL_EVAL : CELL_WAIT;
        CELL_EVAL: begin
            if(cell_accept && result_count >= 16'd4096) next_state = FINISH;
            else next_state = cell_accept ? CELL_WRITE : CELL_ADVANCE;
        end
        CELL_WRITE: next_state = CELL_ADVANCE;
        CELL_ADVANCE: next_state = (next_grid_x > final_grid_x) ? ROW_END : CELL_INIT;
        ROW_END: next_state = (sync_bad || {1'b0, relative_row} + 7'd1 == band_length) ? FINISH : PHASE_CLEAR;
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
        rows_reg <= 7'd0;
        result_count <= 16'd0;
        result_rows <= 8'd0;
        pitch_q8 <= 16'd0;
        result_status <= 8'd0;
    end else begin
        if(state == IDLE && start_flag) begin
            width_reg <= image_width;
            rows_reg <= stored_rows;
            result_count <= 16'd0;
            result_rows <= 8'd0;
            pitch_q8 <= 16'd0;
            result_status <= overflow_flag ? 8'd3 : (stored_rows < 7'd4 ? 8'd1 : 8'd0);
        end else if(state == SELECT_BAND) begin
            result_rows <= {1'b0, best_length};
            if(best_length < 7'd4) result_status <= 8'd1;
        end else if(state == SYNC_END && sync_points < 12'd8)
            result_status <= 8'd2;
        else if(state == PDIV_WAIT && div_out_valid) begin
            pitch_q8 <= div_quotient[15:0];
            if(div_quotient < 26'd2048 || div_quotient > 26'd8192) result_status <= 8'd4;
        end else if(state == RDIV_REQ && inlier_count == 12'd0)
            result_status <= 8'd5;
        else if(state == CELL_EVAL && cell_accept && result_count >= 16'd4096)
            result_status <= 8'd3;
        else if(state == CELL_WRITE)
            result_count <= result_count + 1'b1;
        else if(state == ROW_END && sync_bad)
            result_status <= 8'd2;
    end

//行描述符和均值坐标只在对应除法完成后提交
always@(posedge sys_clk)
    if(state == META_GET) begin
        meta_start <= row_rd_data[10:0];
        meta_count <= row_rd_data[22:11];
        meta_sum_y <= row_rd_data[43:23];
    end

always@(posedge sys_clk)
    if(state == YDIV_WAIT && div_out_valid) begin
        row_start[row_index] <= meta_start;
        row_points[row_index] <= meta_count;
        row_y[row_index] <= div_quotient[8:0];
    end

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0) begin
        previous_y <= 9'd0;
        segment_first <= 6'd0;
        segment_length <= 7'd0;
        best_first <= 6'd0;
        best_length <= 7'd0;
        band_first <= 6'd0;
        band_length <= 7'd0;
    end else if(state == IDLE && start_flag) begin
        previous_y <= 9'd0;
        segment_first <= 6'd0;
        segment_length <= 7'd0;
        best_first <= 6'd0;
        best_length <= 7'd0;
    end else if(state == YDIV_WAIT && div_out_valid) begin
        previous_y <= div_quotient[8:0];
        segment_length <= candidate_length;
        if(break_segment) segment_first <= row_index;
        if(candidate_length > best_length) begin
            best_length <= candidate_length;
            best_first <= break_segment ? row_index : segment_first;
        end
    end else if(state == SELECT_BAND) begin
        band_first <= best_first;
        band_length <= best_length;
    end

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0) begin
        row_index <= 6'd0;
        relative_row <= 6'd0;
        sync_second <= 1'b0;
    end else if(state == IDLE && start_flag) begin
        row_index <= 6'd0;
        relative_row <= 6'd0;
        sync_second <= 1'b0;
    end else if(state == YDIV_WAIT && div_out_valid)
        row_index <= row_index + 1'b1;
    else if(state == SELECT_BAND)
        row_index <= best_first + best_length[5:0] - 6'd2;
    else if(state == SYNC_END && !sync_second) begin
        row_index <= row_index + 1'b1;
        sync_second <= 1'b1;
    end else if(state == PDIV_WAIT && div_out_valid) begin
        row_index <= band_first;
        relative_row <= 6'd0;
    end else if(state == ROW_END) begin
        row_index <= row_index + 1'b1;
        relative_row <= relative_row + 1'b1;
    end

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0) begin
        span_sum <= 11'd0;
        interval_sum <= 13'd0;
        sync_points <= 12'd0;
        min_x <= 9'd511;
        max_x <= 9'd0;
    end else if(state == SELECT_BAND) begin
        span_sum <= 11'd0;
        interval_sum <= 13'd0;
    end else if(state == SYNC_INIT) begin
        sync_points <= 12'd0;
        min_x <= 9'd511;
        max_x <= 9'd0;
    end else if(state == SYNC_GET && point_y_ok) begin
        sync_points <= sync_points + 1'b1;
        if(dot_rd_data[8:0] < min_x) min_x <= dot_rd_data[8:0];
        if(dot_rd_data[8:0] > max_x) max_x <= dot_rd_data[8:0];
    end else if(state == SYNC_END) begin
        span_sum <= span_sum + {2'd0, max_x} - {2'd0, min_x};
        interval_sum <= interval_sum + {1'b0, sync_points} - 13'd1;
    end

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        dot_index <= 12'd0;
    else if(state == SYNC_INIT || state == PHASE_INIT || state == REF_INIT || state == CELL_INIT)
        dot_index <= 12'd0;
    else if(state == SYNC_GET || state == PHASE_ADD || state == REF_ADD || state == CELL_GET)
        dot_index <= dot_index + 1'b1;

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0) begin
        remainder_reg <= 18'd0;
        point_inside <= 1'b0;
    end else if(state == PHASE_GET || state == REF_GET) begin
        remainder_reg <= {1'b0, dot_rd_data[8:0], 8'd0};
        point_inside <= point_y_ok;
    end else if((state == PHASE_MOD || state == REF_MOD) && remainder_reg >= {2'd0, pitch_q8})
        remainder_reg <= remainder_reg - {2'd0, pitch_q8};

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        hist_index <= 5'd0;
    else if(state == PDIV_WAIT || state == ROW_END || state == HIST_INIT)
        hist_index <= 5'd0;
    else if(state == PHASE_CLEAR || state == HIST_SCAN)
        hist_index <= hist_index + 1'b1;

always@(posedge sys_clk)
    if(state == PHASE_CLEAR)
        phase_hist[hist_index] <= 12'd0;
    else if(state == PHASE_ADD && point_inside)
        phase_hist[remainder_reg[12:8]] <= phase_hist[remainder_reg[12:8]] + 1'b1;

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0) begin
        hist_max <= 12'd0;
        best_bin <= 5'd0;
        phase_base <= 16'd0;
        valid_points <= 12'd0;
    end else if(state == PHASE_INIT)
        valid_points <= 12'd0;
    else if(state == PHASE_ADD && point_inside)
        valid_points <= valid_points + 1'b1;
    else if(state == HIST_INIT) begin
        hist_max <= 12'd0;
        best_bin <= 5'd0;
    end else if(state == HIST_SCAN && phase_hist[hist_index] > hist_max) begin
        hist_max <= phase_hist[hist_index];
        best_bin <= hist_index;
    end else if(state == REF_INIT)
        phase_base <= {3'd0, best_bin, 8'd0};

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0) begin
        residual_sum <= 24'sd0;
        inlier_count <= 12'd0;
    end else if(state == REF_INIT) begin
        residual_sum <= 24'sd0;
        inlier_count <= 12'd0;
    end else if(state == REF_ADD && point_inside && adjusted_delta >= -19'sd768 && adjusted_delta <= 19'sd768) begin
        residual_sum <= residual_sum + {{5{adjusted_delta[18]}}, adjusted_delta};
        inlier_count <= inlier_count + 1'b1;
    end

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        grid_x <= 19'sd0;
    else if(state == RDIV_WAIT && div_out_valid)
        grid_x <= $signed({3'd0, normalized_phase}) - $signed({3'd0, pitch_q8});
    else if(state == CELL_ADVANCE)
        grid_x <= next_grid_x;

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0) begin
        cell_match <= 1'b0;
        match_contrast <= 8'd0;
    end else if(state == CELL_INIT) begin
        cell_match <= 1'b0;
        match_contrast <= 8'd0;
    end else if(state == CELL_GET && point_y_ok && point_distance >= -19'sd768 && point_distance <= 19'sd768) begin
        cell_match <= 1'b1;
        if(dot_rd_data[25:18] > match_contrast) match_contrast <= dot_rd_data[25:18];
    end

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0) begin
        row_cell_count <= 8'd0;
        row_one_count <= 8'd0;
    end else if(state == PHASE_INIT) begin
        row_cell_count <= 8'd0;
        row_one_count <= 8'd0;
    end else if(state == CELL_WRITE) begin
        row_cell_count <= row_cell_count + 1'b1;
        if(cell_match) row_one_count <= row_one_count + 1'b1;
    end

//********************************************************************//
//*************************** Instantiation **************************//
//********************************************************************//
band_unsigned_div
band_unsigned_div_inst
(
    .sys_clk        (sys_clk        ),
    .sys_rst_n      (sys_rst_n      ),
    .numerator      (div_numerator  ),
    .denominator    (div_denominator),
    .in_valid       (div_in_valid   ),
    .in_ready       (div_in_ready   ),
    .quotient       (div_quotient   ),
    .out_valid      (div_out_valid  ),
    .out_ready      (1'b1           )
);

endmodule
