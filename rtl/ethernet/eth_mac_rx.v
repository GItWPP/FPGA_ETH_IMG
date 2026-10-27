//--------------------------------------------------------------------------------------------------------
// 模块： eth_mac_rx
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： GMII前导码和以太网帧解析、尾部FCS剥离与CRC32校验
// 作者： WANG
// 时间： 26.10.22
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ps

module  eth_mac_rx
(
    input   wire                   rx_clk                 ,
    input   wire                   rx_rst_n               ,
    input   wire                   gmii_rx_dv             ,
    input   wire                   gmii_rx_er             ,
    input   wire           [7:0]   gmii_rxd               ,
    output  reg                    frame_start            ,
    output  reg            [47:0]  frame_dst_mac          ,
    output  reg            [47:0]  frame_src_mac          ,
    output  reg            [15:0]  frame_eth_type         ,
    output  reg                    payload_valid          ,
    output  reg            [7:0]   payload_data           ,
    output  reg                    payload_last           ,
    output  reg                    frame_done             ,
    output  reg                    frame_error
);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//

//parameter define
localparam ST_IDLE = 2'd0;
localparam ST_PREAMBLE = 2'd1;
localparam ST_HEADER = 2'd2;
localparam ST_DATA = 2'd3;
//wire  define
wire           [31:0]  crc_with_last;
//reg   define
reg            [1:0]   state;
reg            [3:0]   preamble_count;
reg            [3:0]   header_count;
reg            [15:0]  data_count;
reg                    rx_error_seen;
reg            [7:0]   delay0;
reg            [7:0]   delay1;
reg            [7:0]   delay2;
reg            [7:0]   delay3;
reg            [7:0]   delay4;
reg            [31:0]  crc_reg;

function [31:0] crc32_byte;
    input   [31:0] crc_in;
    input   [7:0] data_in;
    integer bit_index;
    reg            [31:0]  crc_work;
    begin
        crc_work = crc_in;
        for(bit_index=0; bit_index<8; bit_index=bit_index+1) begin
            if(crc_work[0] ^ data_in[bit_index]) crc_work = (crc_work >> 1) ^ 32'hedb88320;
            else crc_work = crc_work >> 1;
        end
        crc32_byte = crc_work;
    end
endfunction

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//

assign crc_with_last = crc32_byte(crc_reg, delay4);

//state:协议阶段转移，与计数器和数据通路分离
always@(posedge rx_clk or negedge rx_rst_n) begin
    if(rx_rst_n == 1'b0) begin
        state <= ST_IDLE;
    end else begin
        case(state)
            ST_IDLE: begin
                if(gmii_rx_dv && (gmii_rxd == 8'h55)) begin
                    state <= ST_PREAMBLE;
                end
            end
            ST_PREAMBLE: begin
                if(!gmii_rx_dv) begin
                    state <= ST_IDLE;
                end else begin
                    if(!(gmii_rxd == 8'h55)) begin
                        if((gmii_rxd == 8'hd5) && (preamble_count >= 4'd7)) begin
                            state <= ST_HEADER;
                        end else begin
                            state <= ST_IDLE;
                        end
                    end
                end
            end
            ST_HEADER: begin
                if(!gmii_rx_dv) begin
                    state <= ST_IDLE;
                end else begin
                    if(header_count == 4'd13) begin
                        state <= ST_DATA;
                    end
                end
            end
            ST_DATA: begin
                if(!gmii_rx_dv) begin
                    state <= ST_IDLE;
                end
            end
            default: state <= ST_IDLE;
        endcase
    end
end

//preamble_count:累计连续前导码字节
always@(posedge rx_clk or negedge rx_rst_n) begin
    if(rx_rst_n == 1'b0) begin
        preamble_count <= 4'd0;
    end else begin
        case(state)
            ST_IDLE: begin
                preamble_count <= 4'd0;
                if(gmii_rx_dv && (gmii_rxd == 8'h55)) begin
                    preamble_count <= 4'd1;
                end
            end
            ST_PREAMBLE: begin
                if(gmii_rx_dv) begin
                    if(gmii_rxd == 8'h55) begin
                        if(preamble_count != 4'hf) begin
                            preamble_count <= preamble_count + 1'b1;
                        end
                    end
                end
            end
            default: begin
            end
        endcase
    end
end

//header_count:以太网头字段的字节位置
always@(posedge rx_clk or negedge rx_rst_n) begin
    if(rx_rst_n == 1'b0) begin
        header_count <= 4'd0;
    end else begin
        case(state)
            ST_PREAMBLE: begin
                if(gmii_rx_dv) begin
                    if(!(gmii_rxd == 8'h55)) begin
                        if((gmii_rxd == 8'hd5) && (preamble_count >= 4'd7)) begin
                            header_count <= 4'd0;
                        end
                    end
                end
            end
            ST_HEADER: begin
                if(gmii_rx_dv) begin
                    if(!(header_count == 4'd13)) begin
                        header_count <= header_count + 1'b1;
                    end
                end
            end
            default: begin
            end
        endcase
    end
end

//data_count:统计包含FCS的接收区长度
always@(posedge rx_clk or negedge rx_rst_n) begin
    if(rx_rst_n == 1'b0) begin
        data_count <= 16'd0;
    end else begin
        case(state)
            ST_PREAMBLE: begin
                if(gmii_rx_dv) begin
                    if(!(gmii_rxd == 8'h55)) begin
                        if((gmii_rxd == 8'hd5) && (preamble_count >= 4'd7)) begin
                            data_count <= 16'd0;
                        end
                    end
                end
            end
            ST_HEADER: begin
                if(gmii_rx_dv) begin
                    if(header_count == 4'd13) begin
                        data_count <= 16'd0;
                    end
                end
            end
            ST_DATA: begin
                if(gmii_rx_dv) begin
                    data_count <= data_count + 1'b1;
                end
            end
            default: begin
            end
        endcase
    end
end

//rx_error_seen:在整帧期间累计物理接收错误
always@(posedge rx_clk or negedge rx_rst_n) begin
    if(rx_rst_n == 1'b0) begin
        rx_error_seen <= 1'b0;
    end else begin
        case(state)
            ST_PREAMBLE: begin
                if(gmii_rx_dv) begin
                    if(!(gmii_rxd == 8'h55)) begin
                        if((gmii_rxd == 8'hd5) && (preamble_count >= 4'd7)) begin
                            rx_error_seen <= gmii_rx_er;
                        end
                    end
                end
            end
            ST_HEADER: begin
                if(gmii_rx_dv) begin
                    rx_error_seen <= rx_error_seen | gmii_rx_er;
                end
            end
            ST_DATA: begin
                if(gmii_rx_dv) begin
                    rx_error_seen <= rx_error_seen | gmii_rx_er;
                end
            end
            default: begin
            end
        endcase
    end
end

//delay0:五字节尾缓存使FCS不进入上层负载
always@(posedge rx_clk or negedge rx_rst_n) begin
    if(rx_rst_n == 1'b0) begin
        delay0 <= 8'd0;
        delay1 <= 8'd0;
        delay2 <= 8'd0;
        delay3 <= 8'd0;
        delay4 <= 8'd0;
    end else begin
        case(state)
            ST_HEADER: begin
                if(gmii_rx_dv) begin
                    if(header_count == 4'd13) begin
                        delay0 <= 8'd0;
                        delay1 <= 8'd0;
                        delay2 <= 8'd0;
                        delay3 <= 8'd0;
                        delay4 <= 8'd0;
                    end
                end
            end
            ST_DATA: begin
                if(gmii_rx_dv) begin
                    delay0 <= gmii_rxd;
                    delay1 <= delay0;
                    delay2 <= delay1;
                    delay3 <= delay2;
                    delay4 <= delay3;
                end
            end
            default: begin
            end
        endcase
    end
end

//crc_reg:逐字节累计以太网CRC32
always@(posedge rx_clk or negedge rx_rst_n) begin
    if(rx_rst_n == 1'b0) begin
        crc_reg <= 32'hffff_ffff;
    end else begin
        case(state)
            ST_PREAMBLE: begin
                if(gmii_rx_dv) begin
                    if(!(gmii_rxd == 8'h55)) begin
                        if((gmii_rxd == 8'hd5) && (preamble_count >= 4'd7)) begin
                            crc_reg <= 32'hffff_ffff;
                        end
                    end
                end
            end
            ST_HEADER: begin
                if(gmii_rx_dv) begin
                    crc_reg <= crc32_byte(crc_reg, gmii_rxd);
                end
            end
            ST_DATA: begin
                if(gmii_rx_dv) begin
                    if(data_count >= 16'd5) begin
                        crc_reg <= crc32_byte(crc_reg, delay4);
                    end
                end else begin
                    if(data_count >= 16'd5) begin
                        crc_reg <= crc_with_last;
                    end
                end
            end
            default: begin
            end
        endcase
    end
end

//frame_start:完成MAC报头后产生单周期起始标志
always@(posedge rx_clk or negedge rx_rst_n) begin
    if(rx_rst_n == 1'b0) begin
        frame_start <= 1'b0;
    end else begin
        frame_start <= 1'b0;
        case(state)
            ST_HEADER: begin
                if(gmii_rx_dv) begin
                    if(header_count == 4'd13) begin
                        frame_start <= 1'b1;
                    end
                end
            end
            default: begin
            end
        endcase
    end
end

//frame_dst_mac:按报头位置锁存目的MAC、源MAC和帧类型
always@(posedge rx_clk or negedge rx_rst_n) begin
    if(rx_rst_n == 1'b0) begin
        frame_dst_mac <= 48'd0;
        frame_src_mac <= 48'd0;
        frame_eth_type <= 16'd0;
    end else begin
        case(state)
            ST_PREAMBLE: begin
                if(gmii_rx_dv) begin
                    if(!(gmii_rxd == 8'h55)) begin
                        if((gmii_rxd == 8'hd5) && (preamble_count >= 4'd7)) begin
                            frame_dst_mac <= 48'd0;
                            frame_src_mac <= 48'd0;
                            frame_eth_type <= 16'd0;
                        end
                    end
                end
            end
            ST_HEADER: begin
                if(gmii_rx_dv) begin
                    case(header_count)
                        4'd0: frame_dst_mac[47:40] <= gmii_rxd;
                        4'd1: frame_dst_mac[39:32] <= gmii_rxd;
                        4'd2: frame_dst_mac[31:24] <= gmii_rxd;
                        4'd3: frame_dst_mac[23:16] <= gmii_rxd;
                        4'd4: frame_dst_mac[15:8] <= gmii_rxd;
                        4'd5: frame_dst_mac[7:0] <= gmii_rxd;
                        4'd6: frame_src_mac[47:40] <= gmii_rxd;
                        4'd7: frame_src_mac[39:32] <= gmii_rxd;
                        4'd8: frame_src_mac[31:24] <= gmii_rxd;
                        4'd9: frame_src_mac[23:16] <= gmii_rxd;
                        4'd10: frame_src_mac[15:8] <= gmii_rxd;
                        4'd11: frame_src_mac[7:0] <= gmii_rxd;
                        4'd12: frame_eth_type[15:8] <= gmii_rxd;
                        4'd13: frame_eth_type[7:0] <= gmii_rxd;
                        default: begin
                        end
                    endcase
                end
            end
            default: begin
            end
        endcase
    end
end

//payload_valid:对齐负载数据、有效窗口和末字节标志
always@(posedge rx_clk or negedge rx_rst_n) begin
    if(rx_rst_n == 1'b0) begin
        payload_valid <= 1'b0;
        payload_data <= 8'd0;
        payload_last <= 1'b0;
    end else begin
        payload_valid <= 1'b0;
        payload_last <= 1'b0;
        case(state)
            ST_DATA: begin
                if(gmii_rx_dv) begin
                    if(data_count >= 16'd5) begin
                        payload_valid <= 1'b1;
                        payload_data <= delay4;
                    end
                end else begin
                    if(data_count >= 16'd5) begin
                        payload_valid <= 1'b1;
                        payload_data <= delay4;
                        payload_last <= 1'b1;
                    end
                end
            end
            default: begin
            end
        endcase
    end
end

//frame_done:帧结束时输出最终FCS和物理错误结果
always@(posedge rx_clk or negedge rx_rst_n) begin
    if(rx_rst_n == 1'b0) begin
        frame_done <= 1'b0;
        frame_error <= 1'b0;
    end else begin
        frame_done <= 1'b0;
        frame_error <= 1'b0;
        case(state)
            ST_DATA: begin
                if(!gmii_rx_dv) begin
                    if(data_count >= 16'd5) begin
                        frame_done <= 1'b1;
                        frame_error <= rx_error_seen | (~crc_with_last != { delay0, delay1, delay2, delay3 });
                    end else begin
                        frame_done <= 1'b1;
                        frame_error <= 1'b1;
                    end
                end
            end
            default: begin
            end
        endcase
    end
end

endmodule
