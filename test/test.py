# SPDX-FileCopyrightText: © 2026
# SPDX-License-Identifier: Apache-2.0

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles


def pack_ui(mode: int, enable: int, pitch: int) -> int:
    return ((mode & 0x3) << 6) | ((enable & 0x1) << 5) | (pitch & 0x1F)


def pack_uio(rate: int, depth: int) -> int:
    return ((rate & 0x3) << 6) | ((depth & 0x3) << 4)


async def apply_reset(dut):
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 8)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 4)


@cocotb.test()
async def test_sine_chirp_beacon(dut):
    dut._log.info("Start DDS sine chirp beacon test")
    clock = Clock(dut.clk, 1, unit="us")  # 1 MHz
    cocotb.start_soon(clock.start())

    await apply_reset(dut)

    assert int(dut.uio_oe.value) == 0x0F
    assert int(dut.uo_out.value) == 128

    dut._log.info("Checking fixed-tone waveform span")
    dut.ui_in.value = pack_ui(mode=0, enable=1, pitch=20)
    dut.uio_in.value = pack_uio(rate=0, depth=0)

    samples = []
    for _ in range(1200):
        await ClockCycles(dut.clk, 1)
        samples.append(int(dut.uo_out.value))

    assert min(samples) < 20, f"Expected a low sine sample, got min={min(samples)}"
    assert max(samples) > 235, f"Expected a high sine sample, got max={max(samples)}"

    dut._log.info("Checking chirp sync pulse")
    dut.ui_in.value = pack_ui(mode=1, enable=1, pitch=8)
    dut.uio_in.value = pack_uio(rate=0, depth=3)

    sync_seen = 0
    for _ in range(9000):
        await ClockCycles(dut.clk, 1)
        if (int(dut.uio_out.value) >> 2) & 0x1:
            sync_seen += 1

    assert sync_seen >= 2, "Expected mode-change pulse plus at least one chirp restart pulse"

    dut._log.info("Checking dual-tone beacon toggles")
    dut.ui_in.value = pack_ui(mode=3, enable=1, pitch=10)
    dut.uio_in.value = pack_uio(rate=0, depth=1)

    toggles = 0
    for _ in range(700):
        await ClockCycles(dut.clk, 1)
        if (int(dut.uio_out.value) >> 2) & 0x1:
            toggles += 1

    assert toggles >= 3, "Expected mode-change pulse plus repeated dual-tone sync pulses"

    dut._log.info("DDS sine chirp beacon test passed")
