//--------------------------------------------------------------------------------------------------------
// 模块： tb_img_pixel_proc
// Type    : simulation
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 穷举RGB565全部输入的原图/灰度/反色/Gamma，检查反压保持与复位
// 作者： WANG
// 时间： 26.10.21
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  tb_img_pixel_proc();

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//parameter define
localparam integer PIXEL_COUNT = 65536;

//wire  define
wire                     in_ready;
wire                     out_valid;
wire           [15:0]    out_data;

//reg   define
reg                      sys_clk;
reg                      sys_rst_n;
reg                      in_valid;
reg                      out_ready;
reg            [2:0]     mode;
reg            [15:0]    in_data;
reg            [15:0]    gray [0:PIXEL_COUNT-1];
reg            [15:0]    gamma [0:PIXEL_COUNT-1];
reg            [15:0]    wanted;
reg            [15:0]    held;
reg            [8191:0]  vector_dir;
integer         mode_index;
integer         pixel_index;
integer         hold_index;
integer         path_found;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
initial begin
    sys_clk = 1'b0;
    sys_rst_n = 1'b0;
    in_valid = 1'b0;
    out_ready = 1'b1;
    mode = 3'd0;
    in_data = 16'd0;
end

always #10 sys_clk = ~sys_clk;

//Python生成所有灰度参考值；逐像素检查独立于RTL的组合计算
initial begin
    vector_dir = "../vectors";
    path_found = $value$plusargs("VECTOR_DIR=%s", vector_dir);
    $readmemh({vector_dir, "/gray.hex"}, gray);
    $readmemh({vector_dir, "/gamma.hex"}, gamma);
    #100;
    @(negedge sys_clk);
    sys_rst_n = 1'b1;
    for(mode_index = 0; mode_index < 4; mode_index = mode_index + 1) begin
        mode = (mode_index == 3) ? 3'd6 : mode_index[2:0];
        for(pixel_index = 0; pixel_index < PIXEL_COUNT; pixel_index = pixel_index + 1) begin
            @(negedge sys_clk);
            in_data = pixel_index[15:0];
            in_valid = 1'b1;
            @(posedge sys_clk);
            #1;
            case(mode)
                3'd0: wanted = pixel_index[15:0];
                3'd1: wanted = gray[pixel_index];
                3'd2: wanted = ~pixel_index[15:0];
                3'd6: wanted = gamma[pixel_index];
                default: wanted = 16'd0;
            endcase
            if(!out_valid || out_data !== wanted) begin
                $display("FAIL pixel mode=%0d input=%04x actual=%04x wanted=%04x", mode, pixel_index, out_data, wanted);
                $finish;
            end
        end
        @(negedge sys_clk);
        in_valid = 1'b0;
    end

    //反压时上游数据改变，输出仍须保持之前已接收的像素
    @(negedge sys_clk);
    in_valid = 1'b1;
    in_data = 16'h1234;
    mode = 3'd0;
    @(posedge sys_clk);
    #1;
    held = out_data;
    @(negedge sys_clk);
    out_ready = 1'b0;
    in_data = 16'hffff;
    for(hold_index = 0; hold_index < 8; hold_index = hold_index + 1) begin
        @(posedge sys_clk);
        #1;
        if(in_ready || !out_valid || out_data !== held) begin
            $display("FAIL backpressure");
            $finish;
        end
    end
    @(negedge sys_clk);
    sys_rst_n = 1'b0;
    #1;
    if(out_valid) begin
        $display("FAIL reset");
        $finish;
    end
    $display("PASS tb_img_pixel_proc: 262144 pixels including Gamma, backpressure and reset");
    $finish;
end

//********************************************************************//
//*************************** Instantiation **************************//
//********************************************************************//
img_pixel_proc img_pixel_proc_inst
(
    .sys_clk            (sys_clk            ),
    .sys_rst_n          (sys_rst_n          ),
    .mode               (mode               ),
    .in_data            (in_data            ),
    .window_data        (144'd0             ),
    .in_valid           (in_valid           ),
    .in_ready           (in_ready           ),

    .out_data           (out_data           ),
    .out_valid          (out_valid          ),
    .out_ready          (out_ready          )
);

endmodule
