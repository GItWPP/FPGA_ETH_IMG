//--------------------------------------------------------------------------------------------------------
// 模块： tb_hog_math
// Type    : simulation
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 穷举所有梯度差分组合及除法边界、随机输入和反压
// 作者： WANG
// 时间： 26.10.21
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  tb_hog_math
(

);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//wire  define
wire           [9:0]   magnitude;
wire           [3:0]   direction;
wire                   in_ready;
wire           [25:0]  quotient;
wire                   out_valid;
//reg   define
reg                    sys_clk;
reg                    sys_rst_n;
reg            [7:0]   pixel_left;
reg            [7:0]   pixel_right;
reg            [7:0]   pixel_up;
reg            [7:0]   pixel_down;
reg            [25:0]  numerator;
reg            [16:0]  denominator;
reg                    in_valid;
reg                    out_ready;
reg            [13:0]  gradient_golden [0:261120];
reg            [25:0]  expected_quotient;
integer gx;
integer gy;
integer index;
integer count;
integer delay;
integer seed;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
always #10 sys_clk = ~sys_clk;

initial begin
    sys_clk = 1'b0;
    sys_rst_n = 1'b0;
    pixel_left = 8'd0;
    pixel_right = 8'd0;
    pixel_up = 8'd0;
    pixel_down = 8'd0;
    numerator = 26'd0;
    denominator = 17'd1;
    in_valid = 1'b0;
    out_ready = 1'b0;
    seed = 20261021;
    index = 0;
    $readmemh("../hog_gradient_golden.mem",gradient_golden);
    for(gx=-255; gx<=255; gx=gx+1)
        for(gy=-255; gy<=255; gy=gy+1) begin
            pixel_left = (gx < 0) ? -gx : 0;
            pixel_right = (gx < 0) ? 0 : gx;
            pixel_up = (gy < 0) ? -gy : 0;
            pixel_down = (gy < 0) ? 0 : gy;
            #1;
            if({direction,magnitude} !== gradient_golden[index]) begin
                $display("FAIL gradient gx=%d gy=%d",gx,gy);
                $finish;
            end
            index = index + 1;
        end
    repeat(6) @(negedge sys_clk);
    sys_rst_n = 1'b1;
    for(count=0; count<512; count=count+1) begin
        @(negedge sys_clk);
        numerator = $random(seed);
        denominator = $random(seed);
        if(count == 0) denominator = 17'd0;
        if(count == 1) denominator = 17'd1;
        if(count == 2) begin
            numerator = 26'h3ffffff;
            denominator = 17'h1ffff;
        end
        expected_quotient = numerator / ((denominator == 0) ? 17'd1 : denominator);
        in_valid = 1'b1;
        if(!in_ready) begin
            $display("FAIL divider input not ready");
            $finish;
        end
        @(negedge sys_clk);
        in_valid = 1'b0;
        delay = 0;
        while(!out_valid && delay < 30) begin
            @(negedge sys_clk);
            delay = delay + 1;
        end
        if(!out_valid || quotient !== expected_quotient) begin
            $display("FAIL divider count=%d actual=%d expected=%d",count,quotient,expected_quotient);
            $finish;
        end
        repeat(3) begin
            @(negedge sys_clk);
            if(!out_valid || quotient !== expected_quotient || in_ready) begin
                $display("FAIL divider backpressure hold");
                $finish;
            end
        end
        out_ready = 1'b1;
        @(negedge sys_clk);
        out_ready = 1'b0;
    end
    $display("PASS tb_hog_math: 261121 gradients, 512 divisions and output stalls");
    $finish;
end

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

hog_unsigned_div
hog_unsigned_div_inst
(
    .sys_clk               (sys_clk               ),
    .sys_rst_n             (sys_rst_n             ),
    .numerator             (numerator             ),
    .denominator           (denominator           ),
    .in_valid              (in_valid              ),
    .in_ready              (in_ready              ),
    .quotient              (quotient              ),
    .out_valid             (out_valid             ),
    .out_ready             (out_ready             )
);
endmodule
