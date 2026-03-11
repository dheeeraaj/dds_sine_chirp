/* 
 * Copyright (c) 2026 Dheeraj Sharma
 * SPDX-License-Identifier: Apache-2.0
 */
`default_nettype none

module tt_um_yourgithub_sine_chirp_beacon (
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

    // Designed around a 1 MHz Tiny Tapeout clock:
    // base_step = (pitch + 1) << 10 gives roughly ~61 Hz .. ~1.95 kHz.
    wire [23:0] base_step   = ({19'd0, ui_in[4:0]} + 24'd1) << 10;
    wire [15:0] mod_period  = 16'd255 << uio_in[7:6];
    wire [23:0] tone_alt    = base_step + (base_step >> (uio_in[5:4] + 3'd1));

    reg  [23:0] phase_acc;
    reg  [23:0] phase_step;
    reg  [15:0] mod_count;
    reg  [4:0]  sweep_val;
    reg         sweep_dir;
    reg         tone_sel;
    reg         sync_pulse;
    reg  [1:0]  mode_d;
    reg  [8:0]  pdm_acc;

    wire [23:0] chirp_offset = {19'd0, sweep_val} << (uio_in[5:4] + 3'd6);
    wire [7:0]  sine_sample  = sine_lut(phase_acc[23:18]);
    wire [7:0]  sample_out   = enable ? sine_sample : 8'd128;
    wire        square_ref   = phase_acc[23];

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
            phase_acc <= 24'd0;
        end else if (enable) begin
            phase_acc <= phase_acc + phase_step;
        end else begin
            phase_acc <= 24'd0;
        end
    end

    // Slow modulation state machine for chirps / dual-tone mode.
    always @(posedge clk) begin
        if (!rst_n) begin
            mod_count   <= 16'd0;
            sweep_val   <= 5'd0;
            sweep_dir   <= 1'b0;
            tone_sel    <= 1'b0;
            sync_pulse  <= 1'b0;
            mode_d      <= 2'b00;
        end else begin
            sync_pulse <= 1'b0;

            if (!enable) begin
                mod_count  <= 16'd0;
                sweep_val  <= 5'd0;
                sweep_dir  <= 1'b0;
                tone_sel   <= 1'b0;
            end else if (mode != mode_d) begin
                mod_count  <= 16'd0;
                sweep_val  <= 5'd0;
                sweep_dir  <= 1'b0;
                tone_sel   <= 1'b0;
                sync_pulse <= 1'b1;
            end else if (mod_count == mod_period) begin
                mod_count <= 16'd0;
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
                mod_count <= mod_count + 16'd1;
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

    // 64-entry full-wave sine LUT.
    function [7:0] sine_lut;
        input [5:0] idx;
        begin
            case (idx)
                6'd0:  sine_lut = 8'd128;
                6'd1:  sine_lut = 8'd140;
                6'd2:  sine_lut = 8'd152;
                6'd3:  sine_lut = 8'd165;
                6'd4:  sine_lut = 8'd176;
                6'd5:  sine_lut = 8'd188;
                6'd6:  sine_lut = 8'd198;
                6'd7:  sine_lut = 8'd208;
                6'd8:  sine_lut = 8'd218;
                6'd9:  sine_lut = 8'd226;
                6'd10: sine_lut = 8'd234;
                6'd11: sine_lut = 8'd240;
                6'd12: sine_lut = 8'd245;
                6'd13: sine_lut = 8'd250;
                6'd14: sine_lut = 8'd253;
                6'd15: sine_lut = 8'd254;
                6'd16: sine_lut = 8'd255;
                6'd17: sine_lut = 8'd254;
                6'd18: sine_lut = 8'd253;
                6'd19: sine_lut = 8'd250;
                6'd20: sine_lut = 8'd245;
                6'd21: sine_lut = 8'd240;
                6'd22: sine_lut = 8'd234;
                6'd23: sine_lut = 8'd226;
                6'd24: sine_lut = 8'd218;
                6'd25: sine_lut = 8'd208;
                6'd26: sine_lut = 8'd198;
                6'd27: sine_lut = 8'd188;
                6'd28: sine_lut = 8'd176;
                6'd29: sine_lut = 8'd165;
                6'd30: sine_lut = 8'd152;
                6'd31: sine_lut = 8'd140;
                6'd32: sine_lut = 8'd128;
                6'd33: sine_lut = 8'd115;
                6'd34: sine_lut = 8'd103;
                6'd35: sine_lut = 8'd90;
                6'd36: sine_lut = 8'd79;
                6'd37: sine_lut = 8'd67;
                6'd38: sine_lut = 8'd57;
                6'd39: sine_lut = 8'd47;
                6'd40: sine_lut = 8'd37;
                6'd41: sine_lut = 8'd29;
                6'd42: sine_lut = 8'd21;
                6'd43: sine_lut = 8'd15;
                6'd44: sine_lut = 8'd10;
                6'd45: sine_lut = 8'd5;
                6'd46: sine_lut = 8'd2;
                6'd47: sine_lut = 8'd1;
                6'd48: sine_lut = 8'd0;
                6'd49: sine_lut = 8'd1;
                6'd50: sine_lut = 8'd2;
                6'd51: sine_lut = 8'd5;
                6'd52: sine_lut = 8'd10;
                6'd53: sine_lut = 8'd15;
                6'd54: sine_lut = 8'd21;
                6'd55: sine_lut = 8'd29;
                6'd56: sine_lut = 8'd37;
                6'd57: sine_lut = 8'd47;
                6'd58: sine_lut = 8'd57;
                6'd59: sine_lut = 8'd67;
                6'd60: sine_lut = 8'd79;
                6'd61: sine_lut = 8'd90;
                6'd62: sine_lut = 8'd103;
                6'd63: sine_lut = 8'd115;
            endcase
        end
    endfunction

endmodule

