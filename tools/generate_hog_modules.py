"""Generate the separate, fixed-point HOG data-path modules."""
from generate_algorithm_modules import write, instance, ROOT, RTL


def memory():
    write("hog_ram", "同步简单双口块RAM，不复位数据存储体", """    input   wire                       sys_clk,
    input   wire                       wr_en,
    input   wire    [ADDR_WIDTH-1:0]   wr_addr,
    input   wire    [DATA_WIDTH-1:0]   wr_data,
    input   wire    [ADDR_WIDTH-1:0]   rd_addr,
    output  reg     [DATA_WIDTH-1:0]   rd_data""", """//reg   define
(* ram_style = "block" *) reg [DATA_WIDTH-1:0] memory [0:DEPTH-1];""", """always@(posedge sys_clk)
    if(wr_en)
        memory[wr_addr] <= wr_data;

//读数据只在上升沿更新，下游WAIT/GET与该延迟对齐
always@(posedge sys_clk)
    rd_data <= memory[rd_addr];""")
    path = RTL / "hog_ram.v"
    source = path.read_text(encoding="utf-8").replace("module  hog_ram\n(", """module  hog_ram
#(
    parameter integer ADDR_WIDTH = 17,
    parameter integer DATA_WIDTH = 8,
    parameter integer DEPTH = 76800
)
(""")
    path.write_text(source, encoding="utf-8")


def gradient():
    write("hog_gradient", "中心差分、L1幅值与九个无符号方向区间，纯整数斜率比较", """    input   wire    [7:0]   pixel_left,
    input   wire    [7:0]   pixel_right,
    input   wire    [7:0]   pixel_up,
    input   wire    [7:0]   pixel_down,
    output  wire    [9:0]   magnitude,
    output  wire    [3:0]   direction""", """//wire  define
wire signed [8:0] gradient_x;
wire signed [8:0] gradient_y;
wire [8:0] absolute_x;
wire [8:0] absolute_y;
wire [20:0] scaled_y;
//reg   define
reg [3:0] base_bin;""", """assign gradient_x = $signed({1'b0, pixel_right}) - $signed({1'b0, pixel_left});
assign gradient_y = $signed({1'b0, pixel_down}) - $signed({1'b0, pixel_up});
assign absolute_x = gradient_x[8] ? -gradient_x : gradient_x;
assign absolute_y = gradient_y[8] ? -gradient_y : gradient_y;
assign magnitude = {1'b0, absolute_x} + {1'b0, absolute_y};
assign scaled_y = {4'd0, absolute_y, 8'd0};
assign direction = (absolute_y == 9'd0) ? 4'd0
                 : ((gradient_x[8] ^ gradient_y[8]) ? 4'd8 - base_bin : base_bin);

//20/40/60/80度的正切阈值采用Q8整数；垂直方向始终映射到第4区间
always@(*) begin
    base_bin = 4'd4;
    if(scaled_y < absolute_x * 21'd93)
        base_bin = 4'd0;
    else if(scaled_y < absolute_x * 21'd215)
        base_bin = 4'd1;
    else if(scaled_y < absolute_x * 21'd443)
        base_bin = 4'd2;
    else if(scaled_y < absolute_x * 21'd1452)
        base_bin = 4'd3;
end""")


def divider():
    write("hog_unsigned_div", "26位无符号恢复除法，固定26拍迭代及输出反压保持", """    input   wire            sys_clk,
    input   wire            sys_rst_n,
    input   wire    [25:0]  numerator,
    input   wire    [16:0]  denominator,
    input   wire            in_valid,
    output  wire            in_ready,
    output  reg     [25:0]  quotient,
    output  reg             out_valid,
    input   wire            out_ready""", """//wire  define
wire accept_flag;
wire [17:0] shifted_remainder;
wire subtract_flag;
wire [25:0] next_quotient;
//reg   define
reg active;
reg [4:0] bit_index;
reg [25:0] dividend;
reg [16:0] divisor;
reg [17:0] remainder;""", """assign in_ready = !active && (!out_valid || out_ready);
assign accept_flag = in_valid && in_ready;
assign shifted_remainder = {remainder[16:0], dividend[25]};
assign subtract_flag = shifted_remainder >= {1'b0, divisor};
assign next_quotient = {quotient[24:0], subtract_flag};

always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0)
        active <= 1'b0;
    else if(accept_flag)
        active <= 1'b1;
    else if(active && bit_index == 5'd25)
        active <= 1'b0;

always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0)
        bit_index <= 5'd0;
    else if(accept_flag)
        bit_index <= 5'd0;
    else if(active && bit_index != 5'd25)
        bit_index <= bit_index + 1'b1;

always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0) begin
        dividend <= 26'd0;
        divisor <= 17'd1;
        remainder <= 18'd0;
    end else if(accept_flag) begin
        dividend <= numerator;
        divisor <= (denominator == 17'd0) ? 17'd1 : denominator;
        remainder <= 18'd0;
    end else if(active) begin
        dividend <= {dividend[24:0], 1'b0};
        remainder <= subtract_flag ? shifted_remainder - {1'b0, divisor} : shifted_remainder;
    end

always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0)
        quotient <= 26'd0;
    else if(accept_flag)
        quotient <= 26'd0;
    else if(active)
        quotient <= next_quotient;

always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0)
        out_valid <= 1'b0;
    else if(active && bit_index == 5'd25)
        out_valid <= 1'b1;
    else if(out_ready)
        out_valid <= 1'b0;""")


def cell_histogram():
    write('hog_cell_hist_top', '逐像素中心差分并累计40×30个九方向cell直方图', '''    input   wire            sys_clk,
    input   wire            sys_rst_n,
    input   wire            start_valid,
    output  wire            start_ready,
    output  wire            done_flag,
    output  wire    [16:0]  frame_rd_addr,
    input   wire    [7:0]   frame_rd_data,
    output  wire            hist_wr_en,
    output  wire    [13:0]  hist_wr_addr,
    output  wire    [15:0]  hist_wr_data,
    output  wire    [13:0]  hist_rd_addr,
    input   wire    [15:0]  hist_rd_data''', '''//parameter define
localparam IDLE=4'd0, CLEAR=4'd1, LWAIT=4'd2, LGET=4'd3;
localparam RWAIT=4'd4, RGET=4'd5, UWAIT=4'd6, UGET=4'd7;
localparam DWAIT=4'd8, DGET=4'd9, PREP=4'd10, HWAIT=4'd11;
localparam HGET=4'd12, HWRITE=4'd13, FINISH=4'd14;
//wire  define
wire [9:0] magnitude;
wire [3:0] direction;
wire [16:0] center_addr;
wire last_pixel;
//reg   define
reg [3:0] state;
reg [3:0] next_state;
reg [13:0] clear_addr;
reg [8:0] pixel_x;
reg [7:0] pixel_y;
reg [7:0] pixel_left;
reg [7:0] pixel_right;
reg [7:0] pixel_up;
reg [7:0] pixel_down;
reg [13:0] vote_addr;
reg [9:0] vote_magnitude;
reg [15:0] previous_value;
reg [16:0] neighbor_addr;''', '''assign start_ready = (state == IDLE);
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
        previous_value <= hist_rd_data;''', instance('hog_gradient','hog_gradient_inst',[(p,p) for p in ('pixel_left','pixel_right','pixel_up','pixel_down','magnitude','direction')]))


def block_normalizer():
    write('hog_block_norm_top', '四cell组成block，逐特征恢复除法实现L1定点Q10归一化', '''    input   wire            sys_clk,
    input   wire            sys_rst_n,
    input   wire            start_valid,
    output  wire            start_ready,
    output  wire            done_flag,
    output  wire    [13:0]  hist_rd_addr,
    input   wire    [15:0]  hist_rd_data,
    output  wire            feature_wr_en,
    output  wire    [15:0]  feature_wr_addr,
    output  wire    [9:0]   feature_wr_data''', '''//parameter define
localparam IDLE=3'd0, SUMWAIT=3'd1, SUMGET=3'd2, DIVREQ=3'd3;
localparam DIVWAIT=3'd4, WRITE=3'd5, FINISH=3'd6;
//wire  define
wire div_in_ready;
wire div_out_valid;
wire [25:0] quotient;
wire [25:0] numerator;
wire [16:0] denominator;
//reg   define
reg [2:0] state;
reg [2:0] next_state;
reg [5:0] block_x;
reg [4:0] block_y;
reg [5:0] sample_index;
reg [5:0] value_index;
reg [16:0] block_sum;
reg [15:0] value_cache [0:35];
reg [15:0] feature_addr;
reg [9:0] feature_value;
reg [5:0] cell_x;
reg [4:0] cell_y;
reg [3:0] bin_index;''', '''assign start_ready = (state == IDLE);
assign done_flag = (state == FINISH);
assign hist_rd_addr = (({9'd0, cell_y} * 14'd40) + {8'd0, cell_x}) * 14'd9 + {10'd0, bin_index};
assign numerator = {value_cache[value_index], 10'd0};
assign denominator = block_sum + 1'b1;
assign feature_wr_en = (state == WRITE);
assign feature_wr_addr = feature_addr;
assign feature_wr_data = feature_value;

always@(*) begin
    cell_x = block_x;
    cell_y = block_y;
    bin_index = sample_index[3:0];
    if(sample_index >= 6'd27) begin
        cell_x = block_x + 1'b1;
        cell_y = block_y + 1'b1;
        bin_index = sample_index - 6'd27;
    end else if(sample_index >= 6'd18) begin
        cell_y = block_y + 1'b1;
        bin_index = sample_index - 6'd18;
    end else if(sample_index >= 6'd9) begin
        cell_x = block_x + 1'b1;
        bin_index = sample_index - 6'd9;
    end
end

always@(*) begin
    next_state = state;
    case(state)
        IDLE: if(start_valid) next_state = SUMWAIT;
        SUMWAIT: next_state = SUMGET;
        SUMGET: next_state = (sample_index == 6'd35) ? DIVREQ : SUMWAIT;
        DIVREQ: if(div_in_ready) next_state = DIVWAIT;
        DIVWAIT: if(div_out_valid) next_state = WRITE;
        WRITE: if(value_index == 6'd35)
                   next_state = (block_x == 6'd38 && block_y == 5'd28) ? FINISH : SUMWAIT;
               else next_state = DIVREQ;
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
        block_x <= 6'd0;
        block_y <= 5'd0;
    end else if(state == IDLE) begin
        block_x <= 6'd0;
        block_y <= 5'd0;
    end else if(state == WRITE && value_index == 6'd35) begin
        if(block_x == 6'd38) begin
            block_x <= 6'd0;
            block_y <= block_y + 1'b1;
        end else
            block_x <= block_x + 1'b1;
    end

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0) begin
        sample_index <= 6'd0;
        block_sum <= 17'd0;
    end else if(state == IDLE || (state == WRITE && value_index == 6'd35)) begin
        sample_index <= 6'd0;
        block_sum <= 17'd0;
    end else if(state == SUMGET) begin
        block_sum <= block_sum + {1'b0, hist_rd_data};
        if(sample_index != 6'd35) sample_index <= sample_index + 1'b1;
    end

//36个缓存元素在使用前全部重写，数据阵列不加复位
always@(posedge sys_clk)
    if(state == SUMGET)
        value_cache[sample_index] <= hist_rd_data;

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0) begin
        value_index <= 6'd0;
        feature_addr <= 16'd0;
    end else if(state == IDLE) begin
        value_index <= 6'd0;
        feature_addr <= 16'd0;
    end else if(state == WRITE) begin
        value_index <= (value_index == 6'd35) ? 6'd0 : value_index + 1'b1;
        feature_addr <= feature_addr + 1'b1;
    end

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        feature_value <= 10'd0;
    else if(state == DIVWAIT && div_out_valid)
        feature_value <= quotient[9:0];''', instance('hog_unsigned_div','hog_unsigned_div_inst', [('sys_clk','sys_clk'),('sys_rst_n','sys_rst_n'),('numerator','numerator'),('denominator','denominator'),('in_valid','state == DIVREQ'),('in_ready','div_in_ready'),('quotient','quotient'),('out_valid','div_out_valid'),('out_ready','state == DIVWAIT')]))


def linear_svm():
    write('hog_linear_svm_top','遍历495个单尺度窗口，以3780维定点特征及已训练权重计算线性SVM', '''    input   wire            sys_clk,
    input   wire            sys_rst_n,
    input   wire            start_valid,
    output  wire            start_ready,
    output  wire            done_flag,
    output  wire    [15:0]  feature_rd_addr,
    input   wire    [9:0]   feature_rd_data,
    output  wire            score_wr_en,
    output  wire    [8:0]   score_wr_addr,
    output  wire    [31:0]  score_wr_data,
    output  wire    [31:0]  model_id''', '''//parameter define
localparam IDLE=3'd0, WAIT=3'd1, GET=3'd2, MAC=3'd3, STORE=3'd4, FINISH=3'd5;
//wire  define
wire signed [15:0] weight_rd_data;
wire signed [31:0] bias;
wire last_term;
wire signed [47:0] extended_product;
wire signed [47:0] extended_bias;
//reg   define
reg [2:0] state;
reg [2:0] next_state;
reg [5:0] window_x;
reg [3:0] window_y;
reg [2:0] block_x;
reg [3:0] block_y;
reg [5:0] component_index;
reg [11:0] weight_rd_addr;
reg [8:0] score_index;
reg signed [26:0] product;
reg signed [47:0] accumulator;''', '''assign start_ready = (state == IDLE);
assign done_flag = (state == FINISH);
assign feature_rd_addr = (({12'd0, window_y} + {12'd0, block_y}) * 16'd39
                       + {10'd0, window_x} + {13'd0, block_x}) * 16'd36 + {10'd0, component_index};
assign score_wr_en = (state == STORE);
assign score_wr_addr = score_index;
assign score_wr_data = (accumulator > 48'sd2147483647) ? 32'h7fffffff
                     : (accumulator < -48'sd2147483648) ? 32'h80000000 : accumulator[31:0];
assign last_term = (block_x == 3'd6 && block_y == 4'd14 && component_index == 6'd35);
assign extended_product = {{21{product[26]}}, product};
assign extended_bias = {{16{bias[31]}}, bias};

always@(*) begin
    next_state = state;
    case(state)
        IDLE: if(start_valid) next_state = WAIT;
        WAIT: next_state = GET;
        GET: next_state = MAC;
        MAC: next_state = last_term ? STORE : WAIT;
        STORE: next_state = (score_index == 9'd494) ? FINISH : WAIT;
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
        component_index <= 6'd0;
        block_x <= 3'd0;
        block_y <= 4'd0;
        weight_rd_addr <= 12'd0;
    end else if(state == IDLE || state == STORE) begin
        component_index <= 6'd0;
        block_x <= 3'd0;
        block_y <= 4'd0;
        weight_rd_addr <= 12'd0;
    end else if(state == MAC && !last_term) begin
        weight_rd_addr <= weight_rd_addr + 1'b1;
        if(component_index == 6'd35) begin
            component_index <= 6'd0;
            if(block_x == 3'd6) begin
                block_x <= 3'd0;
                block_y <= block_y + 1'b1;
            end else
                block_x <= block_x + 1'b1;
        end else
            component_index <= component_index + 1'b1;
    end

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0) begin
        window_x <= 6'd0;
        window_y <= 4'd0;
        score_index <= 9'd0;
    end else if(state == IDLE) begin
        window_x <= 6'd0;
        window_y <= 4'd0;
        score_index <= 9'd0;
    end else if(state == STORE) begin
        score_index <= score_index + 1'b1;
        if(window_x == 6'd32) begin
            window_x <= 6'd0;
            window_y <= window_y + 1'b1;
        end else
            window_x <= window_x + 1'b1;
    end

//GET捕获同步RAM/ROM数据，下一拍MAC使用该乘积，避免读延迟错位
always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        product <= 27'sd0;
    else if(state == GET)
        product <= $signed({1'b0, feature_rd_data}) * weight_rd_data;

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        accumulator <= 48'sd0;
    else if(state == IDLE || state == STORE)
        accumulator <= extended_bias;
    else if(state == MAC)
        accumulator <= accumulator + extended_product;''', instance('hog_svm_model','hog_svm_model_inst',[(p,p) for p in ('sys_clk','weight_rd_addr','weight_rd_data','bias','model_id')]))


def ram_instance(name,aw,dw,depth,ports):
    return ('hog_ram\n#(\n'+',\n'.join(f'    .{p:<22}({v})' for p,v in [('ADDR_WIDTH',aw),('DATA_WIDTH',dw),('DEPTH',depth)])+'\n)\n'+name+'\n(\n'+',\n'.join(f'    .{p:<22}({v})' for p,v in [('sys_clk','sys_clk')]+ports)+'\n);\n')


def detection_top():
    instances=[]
    instances.append(ram_instance('frame_ram_inst',17,8,76800,[('wr_en','frame_wr_en && start_ready'),('wr_addr','frame_wr_addr'),('wr_data','frame_wr_data'),('rd_addr','frame_rd_addr'),('rd_data','frame_rd_data')]))
    instances.append(ram_instance('histogram_ram_inst',14,16,10800,[('wr_en','hist_wr_en'),('wr_addr','hist_wr_addr'),('wr_data','hist_wr_data'),('rd_addr','hist_phase ? cell_rd_addr : norm_rd_addr'),('rd_data','hist_rd_data')]))
    instances.append(ram_instance('feature_ram_inst',16,10,40716,[('wr_en','feature_wr_en'),('wr_addr','feature_wr_addr'),('wr_data','feature_wr_data'),('rd_addr','feature_rd_addr'),('rd_data','feature_rd_data')]))
    instances.append(ram_instance('score_ram_inst',9,32,495,[('wr_en','score_wr_en'),('wr_addr','score_wr_addr'),('wr_data','score_wr_data'),('rd_addr','score_rd_addr'),('rd_data','score_rd_data')]))
    instances.append(instance('hog_cell_hist_top','hog_cell_hist_top_inst',[('sys_clk','sys_clk'),('sys_rst_n','sys_rst_n'),('start_valid','state == HIST_REQ'),('start_ready','hist_ready'),('done_flag','hist_done')]+[(p,p) for p in ('frame_rd_addr','frame_rd_data','hist_wr_en','hist_wr_addr','hist_wr_data')]+[('hist_rd_addr','cell_rd_addr'),('hist_rd_data','hist_rd_data')]))
    instances.append(instance('hog_block_norm_top','hog_block_norm_top_inst',[('sys_clk','sys_clk'),('sys_rst_n','sys_rst_n'),('start_valid','state == NORM_REQ'),('start_ready','norm_ready'),('done_flag','norm_done'),('hist_rd_addr','norm_rd_addr'),('hist_rd_data','hist_rd_data')]+[(p,p) for p in ('feature_wr_en','feature_wr_addr','feature_wr_data')]))
    instances.append(instance('hog_linear_svm_top','hog_linear_svm_top_inst',[('sys_clk','sys_clk'),('sys_rst_n','sys_rst_n'),('start_valid','state == SVM_REQ'),('start_ready','svm_ready'),('done_flag','svm_done')]+[(p,p) for p in ('feature_rd_addr','feature_rd_data','score_wr_en','score_wr_addr','score_wr_data','model_id')]))
    write('hog_detect_top','单尺度HOG检测算法顶层，仅连接分阶段计算引擎和帧/直方图/特征/得分RAM', '''    input   wire            sys_clk,
    input   wire            sys_rst_n,
    input   wire            frame_wr_en,
    input   wire    [16:0]  frame_wr_addr,
    input   wire    [7:0]   frame_wr_data,
    input   wire            start_valid,
    output  wire            start_ready,
    output  wire            done_flag,
    input   wire    [8:0]   score_rd_addr,
    output  wire    [31:0]  score_rd_data,
    output  wire    [31:0]  model_id''', '''//parameter define
localparam IDLE=3'd0, HIST_REQ=3'd1, HIST_WAIT=3'd2, NORM_REQ=3'd3;
localparam NORM_WAIT=3'd4, SVM_REQ=3'd5, SVM_WAIT=3'd6, FINISH=3'd7;
//wire  define
wire hist_ready;
wire hist_done;
wire norm_ready;
wire norm_done;
wire svm_ready;
wire svm_done;
wire hist_phase;
wire [16:0] frame_rd_addr;
wire [7:0] frame_rd_data;
wire hist_wr_en;
wire [13:0] hist_wr_addr;
wire [15:0] hist_wr_data;
wire [13:0] cell_rd_addr;
wire [13:0] norm_rd_addr;
wire [15:0] hist_rd_data;
wire feature_wr_en;
wire [15:0] feature_wr_addr;
wire [9:0] feature_wr_data;
wire [15:0] feature_rd_addr;
wire [9:0] feature_rd_data;
wire score_wr_en;
wire [8:0] score_wr_addr;
wire [31:0] score_wr_data;
//reg   define
reg [2:0] state;
reg [2:0] next_state;''', '''assign start_ready = (state == IDLE);
assign done_flag = (state == FINISH);
assign hist_phase = (state == HIST_REQ || state == HIST_WAIT);

always@(*) begin
    next_state = state;
    case(state)
        IDLE: if(start_valid) next_state = HIST_REQ;
        HIST_REQ: if(hist_ready) next_state = HIST_WAIT;
        HIST_WAIT: if(hist_done) next_state = NORM_REQ;
        NORM_REQ: if(norm_ready) next_state = NORM_WAIT;
        NORM_WAIT: if(norm_done) next_state = SVM_REQ;
        SVM_REQ: if(svm_ready) next_state = SVM_WAIT;
        SVM_WAIT: if(svm_done) next_state = FINISH;
        FINISH: next_state = IDLE;
        default: next_state = IDLE;
    endcase
end

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        state <= IDLE;
    else
        state <= next_state;''','\n'.join(instances))


def main():
    memory()
    gradient()
    divider()
    cell_histogram()
    block_normalizer()
    linear_svm()
    detection_top()
    print("Generated independent HOG stages")


if __name__ == "__main__":
    main()
