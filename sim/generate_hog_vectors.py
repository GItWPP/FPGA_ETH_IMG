"""Independent scalar golden data and a full-frame HOG hardware testbench."""
from pathlib import Path
import sys
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from hog_reference import cell_histograms, block_features, svm_scores, nms
from hog_model import WEIGHTS, BIAS
from generate_algorithm_modules import write, RTL, PARAM, MAIN, INST, instance
from hog_client import prepare_hog
from project_paths import user_test_image
from PIL import Image

def main():
    with Image.open(user_test_image('hog_validation_scene.png')) as image:
        gray,_=prepare_hog(image)
    (ROOT/'sim/hog_frame.mem').write_text(''.join(f'{value:02x}\n' for value in gray),encoding='ascii')
    hist=cell_histograms(gray,320,240)
    feat=block_features(hist,40,30)
    scores=svm_scores(feat,WEIGHTS,BIAS)
    for name,values,digits in [('hist',hist,4),('feature',feat,3),('score',scores,8)]:
        (ROOT/f'sim/hog_{name}_golden.mem').write_text(''.join(f'{v&((1<<(digits*4))-1):0{digits}x}\n' for v in values))
    print('Golden scores:',len(scores),'boxes:',nms(scores),flush=True)
    ports=[('sys_clk','sys_clk'),('sys_rst_n','sys_rst_n'),('frame_wr_en','frame_wr_en'),('frame_wr_addr','frame_wr_addr'),('frame_wr_data','frame_wr_data'),('start_valid','start_valid'),('start_ready','start_ready'),('done_flag','done_flag'),('score_rd_addr','score_rd_addr'),('score_rd_data','score_rd_data'),('model_id','')]
    write('tb_hog_detect_top','与独立整数参考逐项比较10800个直方图、40716特征和495得分，检查重用清零', '', '''//wire  define
wire start_ready;
wire done_flag;
wire [31:0] score_rd_data;
//reg   define
reg sys_clk;
reg sys_rst_n;
reg frame_wr_en;
reg [16:0] frame_wr_addr;
reg [7:0] frame_wr_data;
reg start_valid;
reg [8:0] score_rd_addr;
reg [7:0] frame [0:76799];
reg [15:0] golden_hist [0:10799];
reg [9:0] golden_feature [0:40715];
reg [31:0] golden_score [0:494];
integer i;
integer cycles;
integer hist_writes;
integer feature_writes;
integer score_writes;
integer round_index;''', '''always #10 sys_clk = ~sys_clk;

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
end''',instance('hog_detect_top','hog_detect_top_inst',ports))
    source=(RTL/'tb_hog_detect_top.v').read_text(encoding='utf-8').replace('Type    : synthesizable','Type    : simulation')
    (ROOT/'sim/tb_hog_detect_top.v').write_text(source,encoding='utf-8')
    (RTL/'tb_hog_detect_top.v').unlink()

if __name__=='__main__': main()
