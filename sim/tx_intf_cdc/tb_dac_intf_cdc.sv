// P25 S1 CDC bench: real tx_iq_intf (xpm_fifo_sync + csi_fuzzer) and dac_intf.
// The 32-bit iq_out -> data_from_acc bus gets a per-bit transport delay
// (post-route datapath minus clock skew). dac_clk runs PPM off 40 MHz, so the
// acc/dac phase sweeps. Every dac sample with dac_phase=1 is checked against
// the stream written into the FIFO.
`timescale 1ns/1fs
module tb_dac_intf_cdc;
  localparam int N_MAX = 4000000;
  real ppm, acc_half, dac_half, dac_off;
  real dly [0:31];
  int  nsamp;
  string dfile, vfile, ofile;

  reg acc_clk = 0, dac_clk = 0, rstn = 0, dac_rst = 1;
  initial begin
    if (!$value$plusargs("ppm=%f", ppm)) ppm = 100.0;
    if (!$value$plusargs("nsamp=%d", nsamp)) nsamp = 200000;
    if (!$value$plusargs("delays=%s", dfile)) dfile = "";
    if (!$value$plusargs("vec=%s", vfile)) vfile = "";
    if (!$value$plusargs("out=%s", ofile)) ofile = "result.txt";
    if (!$value$plusargs("dac_off=%f", dac_off)) dac_off = 0.7;
    acc_half = 5.0;
    dac_half = 12.5 / (1.0 + ppm * 1e-6);
  end
  initial begin #3.3; forever #(acc_half) acc_clk = ~acc_clk; end
  initial begin #(dac_off); forever #(dac_half) dac_clk = ~dac_clk; end

  // stimulus vector
  reg [31:0] vec [0:4095];
  int nvec;
  initial begin
    int fd, i, q, r;
    nvec = 0;
    if (vfile != "") begin
      fd = $fopen(vfile, "r");
      while (!$feof(fd) && nvec < 4096) begin
        r = $fscanf(fd, "%d %d\n", i, q);
        if (r == 2) begin vec[nvec] = {q[15:0], i[15:0]}; nvec++; end
      end
      $fclose(fd);
    end else begin
      for (nvec = 0; nvec < 4096; nvec++) vec[nvec] = $urandom;
    end
    for (int b = 0; b < 32; b++) dly[b] = 1.0;
    if (dfile != "") begin
      fd = $fopen(dfile, "r");
      for (int b = 0; b < 32; b++) r = $fscanf(fd, "%f\n", dly[b]);
      $fclose(fd);
    end
  end

  // DUT
  wire [31:0] iq_pack, iq_bus;
  wire ready, ready_delay, tx_hold, fifo_empty;
  wire [63:0] dac_data;
  wire dac_valid;
  reg  [15:0] rf_i = 0, rf_q = 0;
  reg  rf_valid = 0;

  tx_iq_intf #(.C_S00_AXIS_TDATA_WIDTH(64), .CSI_FUZZER_WIDTH(6), .IQ_DATA_WIDTH(16)) tx_iq_intf_i (
    .rstn(rstn), .clk(acc_clk),
    .wifi_iq_pack(iq_pack), .wifi_iq_ready(ready), .wifi_iq_valid(),
    .phy_tx_start(1'b0), .tx_bb_is_ongoing(1'b1), .iq_valid_for_check(ready_delay),
    .tx_pkt_iq_to_dac_ongoing(),
    .tx_hold_threshold(10'd200), .bb_gain(10'sd128),
    .bb_gain1(6'sd0), .bb_gain1_rot90_flag(1'b0), .bb_gain2(6'sd0), .bb_gain2_rot90_flag(1'b0),
    .rf_i(rf_i), .rf_q(rf_q), .rf_iq_valid(rf_valid),
    .tx_arbitrary_iq_mode(1'b0), .tx_arbitrary_iq_tx_trigger(1'b0), .tx_arbitrary_iq_in(32'd0),
    .slv_reg_wren(1'b0), .axi_awaddr_core(5'd0),
    .tx_iq_fifo_empty(fifo_empty), .tx_hold(tx_hold));

  // per-bit transport delay on the crossing bus
  genvar g;
  reg [31:0] bus_r = 0;
  assign iq_bus = bus_r;
  for (g = 0; g < 32; g++) begin : gdly
    always @(iq_pack[g]) bus_r[g] <= #(dly[g]) iq_pack[g];
  end

  dac_intf #(.IQ_DATA_WIDTH(16), .DAC_PACK_DATA_WIDTH(64)) dac_intf_i (
    .dac_rst(dac_rst), .dac_clk(dac_clk),
    .dac_data(dac_data), .dac_valid(dac_valid), .dac_ready(1'b1),
    .ant_flag(1'b0), .simple_cdd_flag(2'b00),
    .acc_clk(acc_clk), .acc_rstn(rstn),
    .data_from_acc(iq_bus), .data_valid_from_acc(1'b1),
    .read_bb_fifo(ready), .read_bb_fifo_delay(ready_delay));

  // writer: one sample every 4 acc cycles (25 MSPS) unless tx_hold
  int wr_idx = 0, wr_div = 0;
  reg [31:0] sent [0:N_MAX-1];
  always @(posedge acc_clk) begin
    rf_valid <= 0;
    if (rstn) begin
      wr_div <= (wr_div + 1) % 4;
      if (wr_div == 0 && !tx_hold && wr_idx < N_MAX) begin
        reg [31:0] s;
        s = (vfile == "") ? $urandom : vec[wr_idx % nvec];
        // A zero sample would be ambiguous against fifo-empty padding.
        if (s == 0) s = 32'h00010001;
        rf_i <= s[15:0]; rf_q <= s[31:16]; rf_valid <= 1;
        sent[wr_idx] = s;
        wr_idx++;
      end
    end
  end

  // time of each request that popped a real sample from the tx_iq FIFO
  realtime t_rd [0:N_MAX-1];
  int nread = 0;
  always @(posedge acc_clk) if (rstn && ready && !fifo_empty && nread < N_MAX) begin t_rd[nread] = $realtime; nread++; end
  realtime lat_lo = 1e9, lat_hi = -1;

  // phase of each dac edge against the last acc rising edge
  realtime t_acc = 0, ph_prev = 0, ph_now = 0;
  always @(posedge acc_clk) t_acc = $realtime;

  // checker
  int k = -1, n_out = 0, n_ok = 0, n_bad = 0, n_dup = 0, n_drop = 0, n_pre_bad = 0;
  // Watchdog: a run that never aligns or never finishes reports INCOMPLETE.
  initial begin : watchdog
    int fw;
    #1000;
    #(nsamp * 55.0 + 20000.0);
    fw = $fopen(ofile, "w");
    $fdisplay(fw, "INCOMPLETE ppm %0.1f dac_off %0.3f nsamp %0d out %0d ok %0d corrupt %0d dup %0d drop %0d unaligned_nonzero %0d", ppm, dac_off, nsamp, n_out, n_ok, n_bad, n_dup, n_drop, n_pre_bad);
    $fclose(fw);
    $finish;
  end
  int bin_tot [0:99], bin_bad [0:99];
  int lat_min = 1 << 30, lat_max = -1;
  realtime t_first;
  int fo;
  initial for (int i = 0; i < 100; i++) begin bin_tot[i] = 0; bin_bad[i] = 0; end
  always @(posedge dac_clk) begin : chk
    reg [31:0] got;
    int bin;
    ph_prev = ph_now;
    ph_now = $realtime - t_acc;
    // After this edge dac_data shows stage2 (captured into stage1 at the
    // previous edge, phase ph_prev) when the post-edge dac_phase is 1.
    #0.001;
    if (!dac_rst && dac_intf_i.dac_phase == 1'b1) begin
      got = dac_data[31:0];
      bin = int'($floor(ph_prev * 10.0)) % 100;
      if (k < 0) begin
        if (got != 0) begin : align
          int j;
          for (j = 0; j < 64 && k < 0; j++)
            if (got == sent[j]) begin k = j + 1; n_out = 1; n_ok = 1; end
          if (k < 0) n_pre_bad++;
        end
      end else if (n_out < nsamp) begin
        n_out++;
        bin_tot[bin]++;
        if (got == sent[k]) begin
          n_ok++;
          if ($realtime - t_rd[k] < lat_lo) lat_lo = $realtime - t_rd[k];
          if ($realtime - t_rd[k] > lat_hi) lat_hi = $realtime - t_rd[k];
          k++;
        end
        else begin : resync
          int j, hit;
          hit = 99;
          for (j = -4; j <= 4; j++)
            if (hit == 99 && k + j >= 0 && got == sent[k+j]) hit = j;
          bin_bad[bin]++;
          if (hit == 99) begin n_bad++; k++; end
          else if (hit < 0) begin n_dup++; k = k + hit + 1; end
          else begin n_drop++; k = k + hit + 1; end
        end
        if (n_out == nsamp) begin
          fo = $fopen(ofile, "w");
          $fdisplay(fo, "ppm %0.1f dac_off %0.3f nsamp %0d ok %0d corrupt %0d dup %0d drop %0d lat_ns %0.3f..%0.3f uflow %0d", ppm, dac_off, n_out, n_ok, n_bad, n_dup, n_drop, lat_lo, lat_hi, dac_intf_i.cdc_underflow_sticky);
          for (int i = 0; i < 100; i++)
            $fdisplay(fo, "phase %0.1f-%0.1f ns: %0d/%0d bad", i*0.1, i*0.1+0.1, bin_bad[i], bin_tot[i]);
          $fclose(fo);
          $display("CDC_RESULT ppm %0.1f dac_off %0.3f nsamp %0d ok %0d corrupt %0d dup %0d drop %0d lat_ns %0.3f..%0.3f", ppm, dac_off, n_out, n_ok, n_bad, n_dup, n_drop, lat_lo, lat_hi);
          $finish;
        end
      end
    end
  end

  initial begin
    #200 rstn = 1; dac_rst = 0;
  end
endmodule
