# DDS Sine Chirp Beacon

## What it does

This project is a small **direct digital synthesis (DDS)** engine for Tiny Tapeout.

It can generate:

- a fixed sine tone
- a rising chirp
- a ping-pong chirp
- a dual-tone beacon

The design exposes the waveform in two ways:

- `uo_out[7:0]` carries the current 8-bit sine sample
- `uio[0]` carries a 1-bit PDM version of the same signal

That makes it useful as a tiny **audio tone source**, **piezo driver reference**, 
or **resonance-finder / swept-sine exciter** for simple experiments.

## Why it is a good Tiny Tapeout project

- Purely digital, so it maps naturally onto the Tiny Tapeout flow
- Small architecture: one phase accumulator, a tiny LUT, and simple control logic
- Easy to demonstrate on a board with a resistor ladder, RC filter, piezo, logic analyzer, or LEDs

## Modes

`ui[7:6]` selects the mode:

- `00` = fixed sine
- `01` = rising chirp
- `10` = ping-pong chirp
- `11` = dual-tone beacon

`ui[4:0]` is the base pitch code.  
`ui[5]` enables the generator.

`uio[7:6]` selects the sweep / toggle rate.  
`uio[5:4]` selects chirp depth or the separation between the two beacon tones.

## How it works

The core uses a 24-bit phase accumulator.

Every clock cycle, the current tuning word is added into the phase accumulator.  
The top 6 bits of the phase select one of 64 values in a sine lookup table.  
That produces an 8-bit waveform sample.

A simple first-order PDM stage converts that 8-bit sample into a 1-bit bitstream on `uio[0]`.

The chirp modes vary the DDS tuning word slowly over time, which creates a swept-frequency tone.  
That is the application angle of the project: it can be used to excite a resonant system or scan an audio 
path and watch for the strongest response.

## External hardware ideas

- **R-2R DAC** on `uo[7:0]` for a parallel analog output
- **RC low-pass filter** on `uio[0]` for a 1-bit DAC
- **Piezo buzzer or amplifier input** driven from `uio[0]` through a buffer
- **Logic analyzer / LEDs** on `uo[7:0]` and `uio[1:3]`

## Suggested demo

1. Set `clock_hz: 1000000`.
2. Connect `uo[7:0]` to a simple resistor ladder, or connect `uio[0]` through an RC filter to an amplifier.
3. Try fixed-tone mode first.
4. Switch to chirp mode and listen for resonances in a piezo, speaker, or filter setup.

