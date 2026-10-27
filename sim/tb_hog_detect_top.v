//--------------------------------------------------------------------------------------------------------
// 模块： tb_hog_detect_top
// Type    : simulation
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 与独立整数参考逐项比较10800个直方图、40716特征和495得分，检查重用清零
// 作者： WANG
// 时间： 26.10.21
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  tb_hog_detect_top
(

);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//wire  define
wire                   start_ready;
wire                   done_flag;
wire           [31:0]  score_rd_data;
//reg   define
reg                    sys_clk;
reg                    sys_rst_n;
reg                    frame_wr_en;
reg            [16:0]  frame_wr_addr;
reg            [7:0]   frame_wr_data;
reg                    start_valid;
reg            [8:0]   score_rd_addr;
reg            [7:0]   frame [0:76799];
reg            [15:0]  golden_hist [0:10799];
reg            [9:0]   golden_feature [0:40715];
reg            [31:0]  golden_score [0:494];
integer i;
integer cycles;
integer hist_writes;
integer feature_writes;
integer score_writes;
integer round_index;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
always #10 sys_clk = ~sys_clk;

//在生产接口写使能处比较，能定位RAM延迟和算法级错位
always@(posedge sys_clk) begin
    if(sys_rst_n && round_index == 0) begin
        if(hog_detect_top_inst.hist_wr_en && hog_detect_top_inst.hog_cell_hist_top_inst.state == 4'd13)
            hist_writes = hist_writes + 1;
        if(hog_detect_top_inst.feature_wr_en) begin
            if(hog_detect_top_inst.feature_wr_data !== golden_feature[hog_detect_top_inst.feature_wr_addr]) begin
                $display("FAIL HOG feature addr=%d actual=%h expected=%h", hog_detect_top_inst.feature_wr_addr, hog_detect_top_inst.feature_wr_data, golden_feature[hog_detect_top_inst.feature_wr_addr]);
                $finish;
            end
            feature_writes = feature_writes + 1;
        end
        if(hog_detect_top_inst.score_wr_en) begin
            if(hog_detect_top_inst.score_wr_data !== golden_score[hog_detect_top_inst.score_wr_addr]) begin
                $display("FAIL HOG score addr=%d actual=%h expected=%h", hog_detect_top_inst.score_wr_addr, hog_detect_top_inst.score_wr_data, golden_score[hog_detect_top_inst.score_wr_addr]);
                $finish;
            end
            score_writes = score_writes + 1;
        end
    end
end

initial begin
    sys_clk = 1'b0;
    sys_rst_n = 1'b0;
    frame_wr_en = 1'b0;
    frame_wr_addr = 17'd0;
    frame_wr_data = 8'd0;
    score_rd_addr = 9'd0;
    start_valid = 1'b0;
    round_index = 0;
    hist_writes = 0;
    feature_writes = 0;
    score_writes = 0;
    $readmemh("../hog_frame.mem", frame);
    $readmemh("../hog_hist_golden.mem", golden_hist);
    $readmemh("../hog_feature_golden.mem", golden_feature);
    $readmemh("../hog_score_golden.mem", golden_score);
    repeat(6) @(negedge sys_clk);
    sys_rst_n = 1'b1;
    for(round_index=0; round_index<2; round_index=round_index+1) begin
        for(i=0; i<76800; i=i+1) begin
            @(negedge sys_clk);
            frame_wr_en = 1'b1;
            frame_wr_addr = i;
            frame_wr_data = (round_index == 0) ? frame[i] : 8'd127;
        end
        @(negedge sys_clk);
        frame_wr_en = 1'b0;
        start_valid = 1'b1;
        @(negedge sys_clk);
        start_valid = 1'b0;
        cycles = 0;
        while(!done_flag && cycles < 10000000) begin
            @(negedge sys_clk);
            cycles = cycles + 1;
        end
        if(!done_flag) begin
            $display("FAIL HOG watchdog state=%d", hog_detect_top_inst.state);
            $finish;
        end
        if(round_index == 0) begin
            for(i=0; i<10800; i=i+1)
                if(hog_detect_top_inst.histogram_ram_inst.memory[i] !== golden_hist[i]) begin
                    $display("FAIL HOG histogram addr=%d", i);
                    $finish;
                end
            if(hist_writes != 76800 || feature_writes != 40716 || score_writes != 495) begin
                $display("FAIL HOG write counts %d %d %d",hist_writes,feature_writes,score_writes);
                $finish;
            end
        end
        for(i=0; i<495; i=i+1) begin
            @(negedge sys_clk);
            score_rd_addr = i;
            repeat(2) @(negedge sys_clk);
            if(score_rd_data !== ((round_index == 0) ? golden_score[i] : hog_detect_top_inst.hog_linear_svm_top_inst.bias)) begin
                $display("FAIL HOG public RAM read round=%d addr=%d",round_index,i);
                $finish;
            end
        end
        $display("HOG round=%d calculation_clocks=%d",round_index,cycles);
        repeat(3) @(negedge sys_clk);
    end
    $display("PASS tb_hog_detect_top: full golden frame and reused uniform frame");
    $finish;
end

//********************************************************************//
//*************************** Instantiation **************************//
//********************************************************************//
hog_detect_top
hog_detect_top_inst
(
    .sys_clk               (sys_clk               ),
    .sys_rst_n             (sys_rst_n             ),
    .frame_wr_en           (frame_wr_en           ),
    .frame_wr_addr         (frame_wr_addr         ),
    .frame_wr_data         (frame_wr_data         ),
    .start_valid           (start_valid           ),
    .start_ready           (start_ready           ),
    .done_flag             (done_flag             ),
    .score_rd_addr         (score_rd_addr         ),
    .score_rd_data         (score_rd_data         ),
    .model_id              (                      )
);
endmodule
