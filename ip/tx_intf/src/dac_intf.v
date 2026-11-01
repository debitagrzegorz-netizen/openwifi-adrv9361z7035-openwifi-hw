// Xianjun jiao. putaoshu@msn.com; xianjun.jiao@imec.be;
`include "clock_speed.v"
`include "board_def.v"

`timescale 1 ns / 1 ps

`include "tx_intf_pre_def.v"

`ifdef TX_INTF_ENABLE_DBG
`define DEBUG_PREFIX (*mark_debug="true",DONT_TOUCH="TRUE"*)
`else
`define DEBUG_PREFIX
`endif

`define COUNT_TOP_20M (`NUM_CLK_PER_SAMPLE-1)

`define TX_BB_CLK_GEN_FROM_RF 1

	module dac_intf #
	(
    parameter integer IQ_DATA_WIDTH = 16,
		parameter integer DAC_PACK_DATA_WIDTH = 64
	)
	(
	  input wire dac_rst,
    input wire dac_clk,
    
    //connect util_ad9361_dac_upack
    output wire [DAC_PACK_DATA_WIDTH-1 : 0] dac_data,
    output wire dac_valid,
    `DEBUG_PREFIX input  wire dac_ready,
    
    input wire ant_flag,
    input wire [1:0] simple_cdd_flag,
  
    input wire acc_clk,
	  input wire acc_rstn,
    input wire [(2*IQ_DATA_WIDTH-1) : 0] data_from_acc,
    `DEBUG_PREFIX input wire data_valid_from_acc,

    `DEBUG_PREFIX output wire read_bb_fifo,
    `DEBUG_PREFIX output reg  read_bb_fifo_delay
	);

    // P25 CDC fix. acc_clk is a PLL multiple (5/2) of dac_clk, so the
    // relative phase is fixed per load and can put the launch edge of
    // data_from_acc on the capture edge. The sample now crosses through
    // xpm_fifo_async: one write per request (read_bb_fifo_delay, when the
    // fuzzer output holds the requested sample), one read per dac_phase slot
    // once PREFILL samples are queued. Writes follow reads one for one, so
    // the occupancy, and with it the latency, stays constant.
    localparam integer PREFILL = 2;

    `DEBUG_PREFIX reg dac_phase;
    `DEBUG_PREFIX wire read_bb_fifo_raw;
    `DEBUG_PREFIX reg  read_bb_fifo_raw_reg;

    wire ant_flag_in_rf_domain;
    wire [1:0] simple_cdd_flag_in_rf_domain;

    wire [(2*IQ_DATA_WIDTH-1) : 0] dac_data_internal;
    reg  [(2*IQ_DATA_WIDTH-1) : 0] dac_data_internal_delay1;
    reg  [(2*IQ_DATA_WIDTH-1) : 0] dac_data_internal_delay2;
    wire [(DAC_PACK_DATA_WIDTH-1) : 0] dac_data_internal_after_sel;

    wire [(2*IQ_DATA_WIDTH-1) : 0] cdc_fifo_dout;
    wire cdc_fifo_empty;
    wire [4:0] cdc_fifo_rd_count;
    wire cdc_fifo_rd_rst_busy;
    wire cdc_fifo_wr_rst_busy;
    wire cdc_fifo_full;
    wire cdc_fifo_overflow;
    wire cdc_fifo_underflow;
    wire cdc_fifo_rst;
    reg  [(2*IQ_DATA_WIDTH-1) : 0] dac_sample;
    reg  cdc_started;
    `DEBUG_PREFIX reg cdc_underflow_sticky;
    `DEBUG_PREFIX reg cdc_overflow_sticky;
    wire cdc_rd_en;

    assign dac_data_internal_after_sel = (ant_flag_in_rf_domain?{dac_data_internal,32'd0}:{32'd0,dac_data_internal});
    assign dac_data = ( simple_cdd_flag_in_rf_domain[1]==0? ( simple_cdd_flag_in_rf_domain[0]?{dac_data_internal_delay2, dac_data_internal}:dac_data_internal_after_sel ) : {dac_data_internal,dac_data_internal} );

    assign dac_valid = 1; //dac always need 40Msps IQ data

    assign dac_data_internal = (dac_phase?dac_sample:0);

    assign read_bb_fifo = (read_bb_fifo_raw==1 && read_bb_fifo_raw_reg==0);

    // Read in the cycle before the dac_phase=1 slot, so dac_sample is
    // registered for that slot.
    assign cdc_rd_en = (dac_phase==0) && cdc_started && (!cdc_fifo_empty) && (!cdc_fifo_rd_rst_busy);

    // dac 40MHz domain
    always @( posedge dac_clk )
    begin
      if ( dac_rst == 1 ) begin
        dac_phase <= 0;
        dac_sample <= 0;
        cdc_started <= 0;
        cdc_underflow_sticky <= 0;
        dac_data_internal_delay1 <= 0;
        dac_data_internal_delay2 <= 0;
      end else begin
        dac_phase <= (~dac_phase);
        if (dac_phase==0) begin
          if (cdc_rd_en)
            dac_sample <= cdc_fifo_dout;
          else if (cdc_started)
            dac_sample <= 0;
        end
        if (!cdc_started && !cdc_fifo_rd_rst_busy && cdc_fifo_rd_count >= PREFILL)
          cdc_started <= 1;
        else if (cdc_started && dac_phase==0 && cdc_fifo_empty)
          cdc_started <= 0;
        if (cdc_started && dac_phase==0 && cdc_fifo_empty)
          cdc_underflow_sticky <= 1;

        dac_data_internal_delay1 <= dac_data_internal;
        dac_data_internal_delay2 <= dac_data_internal_delay1;
      end
    end

    // acc 100MHz domain
    always @( posedge acc_clk )
    begin
      if ( acc_rstn == 0 ) begin
        read_bb_fifo_delay <= 0;
        read_bb_fifo_raw_reg <= 0;
      end else begin
        read_bb_fifo_delay <= read_bb_fifo;
        read_bb_fifo_raw_reg <= read_bb_fifo_raw;
      end
    end

    always @( posedge acc_clk )
    begin
      if ( cdc_fifo_rst == 1 )
        cdc_overflow_sticky <= 0;
      else if (cdc_fifo_overflow)
        cdc_overflow_sticky <= 1;
    end

    // xpm_fifo_async wants its reset in the write (acc) domain.
    xpm_cdc_sync_rst #(
      .DEST_SYNC_FF   (4),
      .INIT           (1),
      .INIT_SYNC_FF   (0),
      .SIM_ASSERT_CHK (0)
    ) xpm_cdc_sync_rst_cdc_fifo (
      .src_rst  (dac_rst),
      .dest_clk (acc_clk),
      .dest_rst (cdc_fifo_rst)
    );

    xpm_fifo_async #(
      .CDC_SYNC_STAGES     (2),
      .DOUT_RESET_VALUE    ("0"),
      .ECC_MODE            ("no_ecc"),
      .FIFO_MEMORY_TYPE    ("distributed"),
      .FIFO_READ_LATENCY   (0),
      .FIFO_WRITE_DEPTH    (16),
      .FULL_RESET_VALUE    (0),
      .PROG_EMPTY_THRESH   (5),
      .PROG_FULL_THRESH    (11),
      .RD_DATA_COUNT_WIDTH (5),
      .READ_DATA_WIDTH     (2*IQ_DATA_WIDTH),
      .READ_MODE           ("fwft"),
      .RELATED_CLOCKS      (0),
      .SIM_ASSERT_CHK      (0),
      .USE_ADV_FEATURES    ("0505"),
      .WAKEUP_TIME         (0),
      .WRITE_DATA_WIDTH    (2*IQ_DATA_WIDTH),
      .WR_DATA_COUNT_WIDTH (5)
    ) xpm_fifo_async_cdc_iq (
      .rst           (cdc_fifo_rst),
      .wr_clk        (acc_clk),
      .wr_en         (read_bb_fifo_delay && !cdc_fifo_wr_rst_busy),
      .din           (data_from_acc),
      .full          (cdc_fifo_full),
      .overflow      (cdc_fifo_overflow),
      .wr_rst_busy   (cdc_fifo_wr_rst_busy),
      .rd_clk        (dac_clk),
      .rd_en         (cdc_rd_en),
      .dout          (cdc_fifo_dout),
      .empty         (cdc_fifo_empty),
      .underflow     (cdc_fifo_underflow),
      .rd_rst_busy   (cdc_fifo_rd_rst_busy),
      .rd_data_count (cdc_fifo_rd_count),
      .sleep         (1'b0),
      .injectsbiterr (1'b0),
      .injectdbiterr (1'b0),
      .prog_full     (),
      .wr_data_count (),
      .almost_full   (),
      .wr_ack        (),
      .prog_empty    (),
      .almost_empty  (),
      .data_valid    (),
      .sbiterr       (),
      .dbiterr       ()
    );

    xpm_cdc_array_single #(
      //Common module parameters
      .DEST_SYNC_FF   (4), // integer; range: 2-10
      .INIT_SYNC_FF   (0), // integer; 0=disable simulation init values, 1=enable simulation init values
      .SIM_ASSERT_CHK (0), // integer; 0=disable simulation messages, 1=enable simulation messages
      .SRC_INPUT_REG  (1), // integer; 0=do not register input, 1=register input
      .WIDTH          (1)  // integer; range: 1-1024
    ) xpm_cdc_array_single_inst_ant_flag (
      .src_clk  (acc_clk),  // optional; required when SRC_INPUT_REG = 1
      .src_in   (ant_flag),
      .dest_clk (dac_clk),
      .dest_out (ant_flag_in_rf_domain)
    );

    xpm_cdc_array_single #(
      //Common module parameters
      .DEST_SYNC_FF   (4), // integer; range: 2-10
      .INIT_SYNC_FF   (0), // integer; 0=disable simulation init values, 1=enable simulation init values
      .SIM_ASSERT_CHK (0), // integer; 0=disable simulation messages, 1=enable simulation messages
      .SRC_INPUT_REG  (1), // integer; 0=do not register input, 1=register input
      .WIDTH          (2)  // integer; range: 1-1024
    ) xpm_cdc_array_single_inst_simple_cdd_flag (
      .src_clk  (acc_clk),  // optional; required when SRC_INPUT_REG = 1
      .src_in   (simple_cdd_flag),
      .dest_clk (dac_clk),
      .dest_out (simple_cdd_flag_in_rf_domain)
    );

    xpm_cdc_array_single #(
      //Common module parameters
      .DEST_SYNC_FF   (4), // integer; range: 2-10
      .INIT_SYNC_FF   (0), // integer; 0=disable simulation init values, 1=enable simulation init values
      .SIM_ASSERT_CHK (0), // integer; 0=disable simulation messages, 1=enable simulation messages
      .SRC_INPUT_REG  (1), // integer; 0=do not register input, 1=register input
      .WIDTH          (1)  // integer; range: 1-1024
    ) xpm_cdc_array_single_inst_read_bb_fifo (
      .src_clk  (dac_clk),  // optional; required when SRC_INPUT_REG = 1
      .src_in   (dac_phase),
      .dest_clk (acc_clk),
      .dest_out (read_bb_fifo_raw)
    );
	endmodule
