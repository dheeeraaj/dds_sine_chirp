/* 
 * Copyright (c) 2026 Your Name
 * SPDX-License-Identifier: Apache-2.0
 */
`default_nettype none

module tt_um_dheeeraaj_sine_chirp_beacon (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: input path
    output wire [7:0] uio_out,  // IOs: output path
    output wire [7:0] uio_oe,   // IOs: output enable
    input  wire       ena,      // Always high when selected
    input  wire       clk,      // Clock
    input  wire       rst_n     // Active-low reset
);

    // ------------------------------------------------------------------------
    // UI encoding
    // ui_in[7:6] : mode
    //   00 = fixed sine
    //   01 = rising chirp
    //   10 = ping-pong chirp
    //   11 = dual-tone beacon
    // ui_in[5]   : enable
    // ui_in[4:0] : base pitch code
    //
    // uio_in[7:6] : rate code
    // uio_in[5:4] : chirp depth / dual-tone interval code
    // uio_in[3:0] : unused (left as inputs)
    //
    // Outputs:
    // uo_out[7:0] : 8-bit sine sample for LEDs / logic analyzer / R-2R DAC
    // uio_out[0]  : 1-bit PDM audio output
    // uio_out[1]  : square-wave reference
    // uio_out[2]  : sync pulse at chirp restart / tone toggle
    // uio_out[3]  : copy of enable
    // ------------------------------------------------------------------------

    wire [1:0] mode   = ui_in[7:6];
    wire       enable = ui_in[5];
    wire [1:0] rate   = uio_in[7:6];
    wire [1:0] depth  = uio_in[5:4];

    // Designed around a 1 MHz Tiny Tapeout clock:
    // base_step = (pitch + 1) << 1 with a 12-bit phase accumulator gives
    // a compact, low-gate DDS while preserving useful frequency separation.
    wire [11:0] base_step = ({7'd0, ui_in[4:0]} + 12'd1) << 1;
    wire [11:0] mod_period = 12'd255 << rate;

    reg  [11:0] phase_acc;
    reg  [11:0] phase_step;
    reg  [11:0] mod_count;
    reg  [4:0]  sweep_val;
    reg         sweep_dir;
    reg         tone_sel;
    reg         sync_pulse;
    reg  [1:0]  mode_d;
    reg  [8:0]  pdm_acc;

    reg  [11:0] chirp_offset;
    reg  [11:0] tone_delta;
    wire [11:0] tone_alt = base_step + tone_delta;

    wire [1:0]  phase_quadrant = phase_acc[11:10];
    wire [3:0]  phase_idx_q = phase_acc[9:6];
    wire [3:0]  phase_idx = phase_quadrant[0] ? ~phase_idx_q : phase_idx_q;
    wire [7:0]  sine_mag = sine_lut_q16(phase_idx);
    wire [7:0]  sine_sample = phase_quadrant[1] ? (8'd128 - sine_mag) : (8'd128 + sine_mag);
    wire [7:0]  sample_out   = enable ? sine_sample : 8'd128;
    wire        square_ref   = enable ? phase_acc[11] : 1'b0;

    // Depth controls chirp excursion and dual-tone spacing.
    always @(*) begin
        case (depth)
            2'b00: begin
                chirp_offset = {6'd0, sweep_val, 1'd0}; // x2
                tone_delta = base_step >> 1;
            end
            2'b01: begin
                chirp_offset = {5'd0, sweep_val, 2'd0}; // x4
                tone_delta = base_step >> 2;
            end
            2'b10: begin
                chirp_offset = {4'd0, sweep_val, 3'd0}; // x8
                tone_delta = base_step >> 3;
            end
            default: begin
                chirp_offset = {3'd0, sweep_val, 4'd0}; // x16
                tone_delta = base_step >> 4;
            end
        endcase
    end

    // Select the instantaneous DDS tuning word.
    always @(*) begin
        case (mode)
            2'b00: phase_step = base_step;
            2'b01: phase_step = base_step + chirp_offset;
            2'b10: phase_step = base_step + chirp_offset;
            2'b11: phase_step = tone_sel ? tone_alt : base_step;
            default: phase_step = base_step;
        endcase
    end

    // DDS phase accumulator.
    always @(posedge clk) begin
        if (!rst_n) begin
            phase_acc <= 12'd0;
        end else if (enable) begin
            phase_acc <= phase_acc + phase_step;
        end else begin
            phase_acc <= 12'd0;
        end
    end

    // Slow modulation state machine for chirps / dual-tone mode.
    always @(posedge clk) begin
        if (!rst_n) begin
            mod_count   <= 12'd0;
            sweep_val   <= 5'd0;
            sweep_dir   <= 1'b0;
            tone_sel    <= 1'b0;
            sync_pulse  <= 1'b0;
            mode_d      <= 2'b00;
        end else begin
            sync_pulse <= 1'b0;

            if (!enable) begin
                mod_count  <= 12'd0;
                sweep_val  <= 5'd0;
                sweep_dir  <= 1'b0;
                tone_sel   <= 1'b0;
            end else if (mode != mode_d) begin
                mod_count  <= 12'd0;
                sweep_val  <= 5'd0;
                sweep_dir  <= 1'b0;
                tone_sel   <= 1'b0;
                sync_pulse <= 1'b1;
            end else if (mod_count == mod_period) begin
                mod_count <= 12'd0;
                case (mode)
                    2'b00: begin
                        sweep_val <= 5'd0;
                        tone_sel  <= 1'b0;
                    end

                    // Rising chirp: restart at the low end.
                    2'b01: begin
                        if (sweep_val == 5'd31) begin
                            sweep_val  <= 5'd0;
                            sync_pulse <= 1'b1;
                        end else begin
                            sweep_val <= sweep_val + 5'd1;
                        end
                    end

                    // Ping-pong chirp: sweep up and down.
                    2'b10: begin
                        if (!sweep_dir) begin
                            if (sweep_val == 5'd31) begin
                                sweep_dir <= 1'b1;
                                sweep_val <= 5'd30;
                            end else begin
                                sweep_val <= sweep_val + 5'd1;
                            end
                        end else begin
                            if (sweep_val == 5'd0) begin
                                sweep_dir  <= 1'b0;
                                sweep_val  <= 5'd1;
                                sync_pulse <= 1'b1;
                            end else begin
                                sweep_val <= sweep_val - 5'd1;
                            end
                        end
                    end

                    // Dual-tone beacon: toggle between base and alternate tone.
                    2'b11: begin
                        tone_sel   <= ~tone_sel;
                        sync_pulse <= 1'b1;
                    end
                endcase
            end else begin
                mod_count <= mod_count + 12'd1;
            end

            mode_d <= mode;
        end
    end

    // First-order 1-bit PDM DAC.
    always @(posedge clk) begin
        if (!rst_n) begin
            pdm_acc <= 9'd0;
        end else begin
            pdm_acc <= {1'b0, pdm_acc[7:0]} + {1'b0, sample_out};
        end
    end

    // Tiny Tapeout I/O mapping.
    assign uo_out  = sample_out;
    assign uio_out = {4'b0000, enable, sync_pulse, square_ref, pdm_acc[8]};
    assign uio_oe  = 8'b0000_1111;

    // Prevent unused-signal warnings.
    wire _unused = &{ena, uio_in[3:0], 1'b0};

    // 16-entry quarter-wave sine magnitude LUT (0..127).
    function [7:0] sine_lut_q16;
        input [3:0] idx;
        begin
            case (idx)
                4'd0:  sine_lut_q16 = 8'd0;
                4'd1:  sine_lut_q16 = 8'd13;
                4'd2:  sine_lut_q16 = 8'd25;
                4'd3:  sine_lut_q16 = 8'd37;
                4'd4:  sine_lut_q16 = 8'd49;
                4'd5:  sine_lut_q16 = 8'd60;
                4'd6:  sine_lut_q16 = 8'd71;
                4'd7:  sine_lut_q16 = 8'd81;
                4'd8:  sine_lut_q16 = 8'd90;
                4'd9:  sine_lut_q16 = 8'd98;
                4'd10: sine_lut_q16 = 8'd106;
                4'd11: sine_lut_q16 = 8'd112;
                4'd12: sine_lut_q16 = 8'd117;
                4'd13: sine_lut_q16 = 8'd122;
                4'd14: sine_lut_q16 = 8'd125;
                default: sine_lut_q16 = 8'd127;
            endcase
        end
    endfunction

endmodule
