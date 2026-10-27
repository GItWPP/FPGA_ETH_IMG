"""Generate the independent, explicitly named Verilog image algorithm modules."""
from pathlib import Path
import math
from format_hdl_layout import format_source

ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / "rtl"
PARAM = "//********************************************************************//\n//****************** Parameter and Internal Signal *******************//\n//********************************************************************//\n"
MAIN = "//********************************************************************//\n//***************************** Main Code ****************************//\n//********************************************************************//\n"
INST = "//********************************************************************//\n//*************************** Instantiation **************************//\n//********************************************************************//\n"


def instance(module, name, ports):
    return module + "\n" + name + "\n(\n" + ",\n".join(
        f"    .{port:<22}({value:<22})" for port, value in ports) + "\n);\n"


def write(name, description, ports, declarations, body, instances=""):
    intro = ("//--------------------------------------------------------------------------------------------------------\n"
             f"// 模块： {name}\n// Type    : synthesizable\n"
             "// Standard: Verilog 2001 (IEEE1364-2001)\n"
             f"// 功能： {description}\n// 作者： WANG\n// 时间： 26.10.21\n"
             "//--------------------------------------------------------------------------------------------------------\n"
             "`timescale  1ns/1ns\n\n")
    text = (intro + f"module  {name}\n(\n{ports}\n);\n\n" + PARAM + declarations.strip() + "\n\n"
            + MAIN + body.strip() + "\n\n" + (INST + instances if instances else "") + "endmodule\n")
    (RTL / f"{name}.v").write_text(format_source(text), encoding="utf-8")


def ports(window=False):
    return "\n".join([
        "    input   wire             sys_clk     ,",
        "    input   wire             sys_rst_n   ,",
        f"    input   wire    [{'143:0' if window else '15:0'}]  {'window_data' if window else 'in_data':<12},",
        "    input   wire             in_valid    ,",
        "    output  wire             in_ready    ,",
        "",
        "    output  reg     [15:0]   out_data    ,",
        "    output  reg              out_valid   ,",
        "    input   wire             out_ready"])


def elastic(expression):
    return f"""assign in_ready = !out_valid || out_ready;

//反压时保持有效和像素；仅在输入握手时更新输出数据
always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0)
        out_valid <= 1'b0;
    else if(in_ready)
        out_valid <= in_valid;

always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0)
        out_data <= 16'd0;
    else if(in_ready && in_valid)
        out_data <= {expression};
"""


def main():
    write("img_copy_top", "RGB565原图弹性寄存通道", ports(), "//wire  define", elastic("in_data"))
    write("img_invert_top", "RGB565逐位反色，独立有效/就绪握手", ports(), "//wire  define", elastic("~in_data"))
    write("img_rgb565_luma", "RGB565位复制扩展后计算整数加权8位亮度", """    input   wire    [15:0]  in_data,
    output  wire    [7:0]   gray""", """//wire  define
wire    [7:0]   red;
wire    [7:0]   green;
wire    [7:0]   blue;
wire    [15:0]  weighted;""", """assign red = {in_data[15:11], in_data[15:13]};
assign green = {in_data[10:5], in_data[10:9]};
assign blue = {in_data[4:0], in_data[4:2]};
assign weighted = red * 16'd77 + green * 16'd150 + blue * 16'd29;
assign gray = weighted[15:8];""")
    write("img_gray_top", "RGB565灰度化顶层，复用亮度子模块", ports(), "//wire  define\nwire [7:0] gray;",
          elastic("{gray[7:3], gray[7:2], gray[7:3]}"),
          instance("img_rgb565_luma", "img_rgb565_luma_inst", [("in_data", "in_data"), ("gray", "gray")]))
    functions = []
    for bits in (5, 6):
        maximum = (1 << bits) - 1
        cases = "\n".join(f"            {bits}'d{value}: gamma{bits} = {bits}'d{math.isqrt(value * maximum)};"
                          for value in range(maximum + 1))
        functions.append(f"""//gamma=0.5，原生颜色分量的精确整数查找表
function [{bits - 1}:0] gamma{bits};
    input [{bits - 1}:0] value;
    begin
        case(value)
{cases}
            default: gamma{bits} = {bits}'d0;
        endcase
    end
endfunction
""")
    write("img_gamma_top", "固定Gamma暗部提亮，黑白端点保持", ports(), "//wire  define",
          "\n".join(functions) + elastic("{gamma5(in_data[15:11]), gamma6(in_data[10:5]), gamma5(in_data[4:0])}"))

    common_valid = """always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0)
        out_valid <= 1'b0;
    else if(state == RESULT)
        out_valid <= 1'b1;
    else if(out_ready)
        out_valid <= 1'b0;
"""
    declarations = """//parameter define
localparam [1:0] IDLE = 2'd0;
localparam [1:0] LOAD = 2'd1;
localparam [1:0] RESULT = 2'd2;

//wire  define
wire            accept_flag;
wire    [15:0]  sample_pixel;
wire    [11:0]  average_red;
wire    [11:0]  average_green;
wire    [11:0]  average_blue;

//reg   define
reg     [1:0]   state;
reg     [1:0]   next_state;
reg     [143:0] window_reg;
reg     [3:0]   sample_index;
reg     [11:0]  sum_red;
reg     [11:0]  sum_green;
reg     [11:0]  sum_blue;"""
    window_load = """always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0)
        window_reg <= 144'd0;
    else if(accept_flag)
        window_reg <= window_data;

always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0)
        sample_index <= 4'd0;
    else if(accept_flag)
        sample_index <= 4'd0;
    else if(state == LOAD && sample_index != 4'd8)
        sample_index <= sample_index + 1'b1;
"""
    state_load = """assign in_ready = (state == IDLE) && (!out_valid || out_ready);
assign accept_flag = in_valid && in_ready;
assign sample_pixel = window_reg[sample_index * 16 +: 16];

always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0)
        state <= IDLE;
    else
        state <= next_state;

always@(*) begin
    next_state = state;
    case(state)
        IDLE: if(accept_flag) next_state = LOAD;
        LOAD: if(sample_index == 4'd8) next_state = RESULT;
        RESULT: next_state = IDLE;
        default: next_state = IDLE;
    endcase
end
"""
    body = state_load + window_load + """
assign average_red = sum_red / 12'd9;
assign average_green = sum_green / 12'd9;
assign average_blue = sum_blue / 12'd9;

//累加与状态转移独立，三分量分别保持原生RGB565位宽含义
always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0) begin
        sum_red <= 12'd0;
        sum_green <= 12'd0;
        sum_blue <= 12'd0;
    end else if(accept_flag) begin
        sum_red <= 12'd0;
        sum_green <= 12'd0;
        sum_blue <= 12'd0;
    end else if(state == LOAD) begin
        sum_red <= sum_red + {7'd0, sample_pixel[15:11]};
        sum_green <= sum_green + {6'd0, sample_pixel[10:5]};
        sum_blue <= sum_blue + {7'd0, sample_pixel[4:0]};
    end
""" + common_valid + """
always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0)
        out_data <= 16'd0;
    else if(state == RESULT)
        out_data <= {average_red[4:0], average_green[5:0], average_blue[4:0]};
"""
    write("img_mean_top", "彩色3x3均值滤波顶层，九次分时累加", ports(True), declarations, body)

    declarations = declarations.replace("wire    [11:0]  average_red;\nwire    [11:0]  average_green;\nwire    [11:0]  average_blue;", """wire    [7:0]   sample_gray;
wire signed [11:0] gradient_x;
wire signed [11:0] gradient_y;
wire    [11:0]  absolute_x;
wire    [11:0]  absolute_y;
wire    [12:0]  magnitude;
wire    [7:0]   edge_gray;""").replace("reg     [11:0]  sum_red;\nreg     [11:0]  sum_green;\nreg     [11:0]  sum_blue;", "reg [7:0] gray_data [0:8];\ninteger reset_index;")
    body = state_load + window_load + """
//九个样本先转换为亮度，结果阶段计算有符号梯度和饱和幅值
always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0) begin
        for(reset_index = 0; reset_index < 9; reset_index = reset_index + 1)
            gray_data[reset_index] <= 8'd0;
    end else if(state == LOAD)
        gray_data[sample_index] <= sample_gray;

assign gradient_x = -$signed({4'd0, gray_data[0]}) + $signed({4'd0, gray_data[2]})
                  - ($signed({4'd0, gray_data[3]}) <<< 1) + ($signed({4'd0, gray_data[5]}) <<< 1)
                  - $signed({4'd0, gray_data[6]}) + $signed({4'd0, gray_data[8]});
assign gradient_y = -$signed({4'd0, gray_data[0]}) - ($signed({4'd0, gray_data[1]}) <<< 1)
                  - $signed({4'd0, gray_data[2]}) + $signed({4'd0, gray_data[6]})
                  + ($signed({4'd0, gray_data[7]}) <<< 1) + $signed({4'd0, gray_data[8]});
assign absolute_x = gradient_x[11] ? -gradient_x : gradient_x;
assign absolute_y = gradient_y[11] ? -gradient_y : gradient_y;
assign magnitude = {1'b0, absolute_x} + {1'b0, absolute_y};
assign edge_gray = magnitude > 13'd255 ? 8'hff : magnitude[7:0];
""" + common_valid + """
always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0)
        out_data <= 16'd0;
    else if(state == RESULT)
        out_data <= {edge_gray[7:3], edge_gray[7:2], edge_gray[7:3]};
"""
    write("img_sobel_top", "Sobel边缘检测顶层，亮度转换与梯度输出分阶段", ports(True), declarations, body,
          instance("img_rgb565_luma", "img_rgb565_luma_inst", [("in_data", "sample_pixel"), ("gray", "sample_gray")]))

    channel_code, wires = [], []
    for name, high, low, width in (("red", 15, 11, 5), ("green", 10, 5, 6), ("blue", 4, 0, 5)):
        sample = lambda index: f"$signed({{{12-width}'d0, window_data[{index*16+high}:{index*16+low}]}})"
        channel_code.append(f"assign gradient_{name} = ({sample(4)} <<< 2) + {sample(4)}\n"
                            + "".join(f"                        - {sample(index)}" for index in (1, 3, 5, 7)) + ";\n"
                            + f"assign sharp_{name} = (gradient_{name} < 12'sd0) ? {width}'d0\n"
                            + f"                  : ((gradient_{name} > 12'sd{(1<<width)-1}) ? {width}'d{(1<<width)-1} : gradient_{name}[{width-1}:0]);")
        wires += [f"wire signed [11:0] gradient_{name};", f"wire [{width-1}:0] sharp_{name};"]
    write("img_sharpen_top", "彩色十字核3x3锐化，分量独立有符号计算并钳位", ports(True),
          "//wire  define\n" + "\n".join(wires), "\n".join(channel_code) + "\n" + elastic("{sharp_red, sharp_green, sharp_blue}"))
    generate_median(common_valid)
    generate_router()
    print("Generated independent image algorithms and routing top")


def generate_median(common_valid):
    sort_ports = """    input   wire            sys_clk,
    input   wire            sys_rst_n,
    input   wire    [71:0]  in_data,
    input   wire            in_valid,
    output  wire            in_ready,
    output  reg     [7:0]   out_data,
    output  reg             out_valid,
    input   wire            out_ready"""
    declarations = """//parameter define
localparam [1:0] IDLE = 2'd0;
localparam [1:0] SORT = 2'd1;
localparam [1:0] RESULT = 2'd2;
//wire  define
wire accept_flag;
wire sort_end;
//reg   define
reg [1:0] state;
reg [1:0] next_state;
reg [3:0] sort_pass;
reg [3:0] sort_index;
reg [7:0] values [0:8];
integer index;"""
    body = """assign in_ready = (state == IDLE) && (!out_valid || out_ready);
assign accept_flag = in_valid && in_ready;
assign sort_end = sort_pass == 4'd7 && sort_index == 4'd0;

always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0)
        state <= IDLE;
    else
        state <= next_state;

always@(*) begin
    next_state = state;
    case(state)
        IDLE: if(accept_flag) next_state = SORT;
        SORT: if(sort_end) next_state = RESULT;
        RESULT: next_state = IDLE;
        default: next_state = IDLE;
    endcase
end

always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0) begin
        sort_pass <= 4'd0;
        sort_index <= 4'd0;
    end else if(accept_flag) begin
        sort_pass <= 4'd0;
        sort_index <= 4'd0;
    end else if(state == SORT) begin
        if(sort_index == 4'd7 - sort_pass) begin
            sort_index <= 4'd0;
            if(!sort_end)
                sort_pass <= sort_pass + 1'b1;
        end else
            sort_index <= sort_index + 1'b1;
    end

//每拍一个相邻比较交换；所有数组写入由同一进程负责
always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0) begin
        for(index = 0; index < 9; index = index + 1)
            values[index] <= 8'd0;
    end else if(accept_flag) begin
        for(index = 0; index < 9; index = index + 1)
            values[index] <= in_data[index * 8 +: 8];
    end else if(state == SORT && values[sort_index] > values[sort_index + 1'b1]) begin
        values[sort_index] <= values[sort_index + 1'b1];
        values[sort_index + 1'b1] <= values[sort_index];
    end
""" + common_valid + """
always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0)
        out_data <= 8'd0;
    else if(state == RESULT)
        out_data <= values[4];
"""
    write("img_sort9", "九个8位样本分时排序并输出中值，可独立复用", sort_ports, declarations, body)
    declarations = """//parameter define
localparam [2:0] IDLE = 3'd0;
localparam [2:0] SEND = 3'd1;
localparam [2:0] WAIT_MEDIAN = 3'd2;
localparam [2:0] RESULT = 3'd3;
//wire  define
wire accept_flag;
wire sort_ready;
wire sort_valid;
wire [7:0] sort_data;
wire [71:0] channel_data;
//reg   define
reg [2:0] state;
reg [2:0] next_state;
reg [1:0] channel_index;
reg [143:0] window_reg;
reg [4:0] red;
reg [5:0] green;
reg [4:0] blue;
genvar sample_index;"""
    body = """assign in_ready = (state == IDLE) && (!out_valid || out_ready);
assign accept_flag = in_valid && in_ready;

generate
    for(sample_index = 0; sample_index < 9; sample_index = sample_index + 1) begin: channel_select
        assign channel_data[sample_index * 8 +: 8] = (channel_index == 2'd0)
            ? {3'd0, window_reg[sample_index * 16 + 11 +: 5]}
            : ((channel_index == 2'd1) ? {2'd0, window_reg[sample_index * 16 + 5 +: 6]}
                                      : {3'd0, window_reg[sample_index * 16 +: 5]});
    end
endgenerate

always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0)
        state <= IDLE;
    else
        state <= next_state;

always@(*) begin
    next_state = state;
    case(state)
        IDLE: if(accept_flag) next_state = SEND;
        SEND: if(sort_ready) next_state = WAIT_MEDIAN;
        WAIT_MEDIAN: if(sort_valid) next_state = (channel_index == 2'd2) ? RESULT : SEND;
        RESULT: next_state = IDLE;
        default: next_state = IDLE;
    endcase
end

always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0)
        window_reg <= 144'd0;
    else if(accept_flag)
        window_reg <= window_data;

always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0)
        channel_index <= 2'd0;
    else if(accept_flag)
        channel_index <= 2'd0;
    else if(state == WAIT_MEDIAN && sort_valid && channel_index != 2'd2)
        channel_index <= channel_index + 1'b1;

always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0) begin
        red <= 5'd0;
        green <= 6'd0;
        blue <= 5'd0;
    end else if(state == WAIT_MEDIAN && sort_valid)
        case(channel_index)
            2'd0: red <= sort_data[4:0];
            2'd1: green <= sort_data[5:0];
            2'd2: blue <= sort_data[4:0];
            default: blue <= 5'd0;
        endcase
""" + common_valid + """
always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0)
        out_data <= 16'd0;
    else if(state == RESULT)
        out_data <= {red, green, blue};
"""
    write("img_median_top", "彩色中值滤波顶层，三个分量复用独立排序子模块", ports(True), declarations, body,
          instance("img_sort9", "img_sort9_inst", [("sys_clk", "sys_clk"), ("sys_rst_n", "sys_rst_n"),
                   ("in_data", "channel_data"), ("in_valid", "state == SEND"), ("in_ready", "sort_ready"),
                   ("out_data", "sort_data"), ("out_valid", "sort_valid"), ("out_ready", "state == WAIT_MEDIAN")]))


def generate_router():
    router_ports = ports().replace("    input   wire    [15:0]  in_data", "    input   wire    [2:0]    mode        ,\n    input   wire    [143:0]  window_data ,\n    input   wire    [15:0]  in_data")
    router_ports = router_ports.replace("output  reg ", "output  wire")
    declarations = """//wire  define
wire [7:0] ready_bus;
wire [7:0] valid_bus;
wire [7:0] output_ready;
wire [127:0] result_bus;
wire accept_flag;
wire slot_available;
//reg   define
reg active;
reg [2:0] active_mode;"""
    body = """//模式只在输入握手时锁存，反压期间不受外部mode变化影响
assign slot_available = !active || (out_valid && out_ready);
assign in_ready = slot_available && ready_bus[mode];
assign accept_flag = in_valid && in_ready;
assign out_valid = active && valid_bus[active_mode];
assign out_data = result_bus[active_mode * 16 +: 16];
assign output_ready = active ? ((8'b0000_0001 << active_mode) & {8{out_ready}}) : 8'd0;

always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0)
        active <= 1'b0;
    else if(accept_flag)
        active <= 1'b1;
    else if(out_valid && out_ready)
        active <= 1'b0;

always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0)
        active_mode <= 3'd0;
    else if(accept_flag)
        active_mode <= mode;
"""
    instances = []
    for mode, algorithm in enumerate(("copy", "gray", "invert", "mean", "median", "sobel", "gamma", "sharpen")):
        module = f"img_{algorithm}_top"
        mapping = [("sys_clk", "sys_clk"), ("sys_rst_n", "sys_rst_n")]
        mapping += [("window_data", "window_data")] if mode in (3, 4, 5, 7) else [("in_data", "in_data")]
        mapping += [("in_valid", f"in_valid && slot_available && mode == 3'd{mode}"),
                    ("in_ready", f"ready_bus[{mode}]"), ("out_data", f"result_bus[{mode * 16} +: 16]"),
                    ("out_valid", f"valid_bus[{mode}]"), ("out_ready", f"output_ready[{mode}]")]
        instances.append(instance(module, f"{module}_inst", mapping))
    write("img_pixel_proc", "八种独立算法的模式路由与单事务握手仲裁，不包含算法运算", router_ports,
          declarations, body, "\n".join(instances))


if __name__ == "__main__":
    main()
