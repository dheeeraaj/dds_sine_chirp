# SPDX-FileCopyrightText: © 2026
# SPDX-License-Identifier: Apache-2.0

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles


def pack_ui(mode: int, enable: int, pitch: int) -> int:
    return ((mode & 0x3) << 6) | ((enable & 0x1) << 5) | (pitch & 0x1F)


def pack_uio(rate: int, depth: int) -> int:
    return ((rate & 0x3) << 6) | ((depth & 0x3) << 4)


def uio_bit(uio_value: int, bit: int) -> int:
    return (uio_value >> bit) & 0x1


async def apply_reset(dut):
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 8)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 4)


async def count_edges_on_uio_bit(dut, bit: int, cycles: int) -> int:
    prev = uio_bit(int(dut.uio_out.value), bit)
    edges = 0

    for _ in range(cycles):
        await ClockCycles(dut.clk, 1)
        cur = uio_bit(int(dut.uio_out.value), bit)
        if cur != prev:
            edges += 1
        prev = cur

    return edges


async def count_sync_pulses_and_width(dut, cycles: int):
    pulses = 0
    run_len = 0
    max_run = 0
    prev = uio_bit(int(dut.uio_out.value), 2)

    for _ in range(cycles):
        await ClockCycles(dut.clk, 1)
        cur = uio_bit(int(dut.uio_out.value), 2)

        if cur:
            run_len += 1
            max_run = max(max_run, run_len)
        else:
            run_len = 0

        if (not prev) and cur:
            pulses += 1
        prev = cur

    return pulses, max_run


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


@cocotb.test()
async def test_enable_gating_behavior(dut):
    dut._log.info("Start enable gating test")
    clock = Clock(dut.clk, 1, unit="us")  # 1 MHz
    cocotb.start_soon(clock.start())

    await apply_reset(dut)

    # Disabled: output should stay midscale and timing markers should be low.
    dut.ui_in.value = pack_ui(mode=0, enable=0, pitch=20)
    dut.uio_in.value = pack_uio(rate=0, depth=0)
    for _ in range(80):
        await ClockCycles(dut.clk, 1)
        assert int(dut.uo_out.value) == 128
        uio = int(dut.uio_out.value)
        assert uio_bit(uio, 3) == 0, "uio_out[3] should mirror enable=0"
        assert uio_bit(uio, 1) == 0, "Square ref should be low when disabled"
        assert uio_bit(uio, 2) == 0, "No sync pulse expected while disabled"

    # Enabled: waveform should move away from midscale.
    dut.ui_in.value = pack_ui(mode=0, enable=1, pitch=20)
    saw_non_midscale = False
    for _ in range(200):
        await ClockCycles(dut.clk, 1)
        if int(dut.uo_out.value) != 128:
            saw_non_midscale = True
        assert uio_bit(int(dut.uio_out.value), 3) == 1

    assert saw_non_midscale, "Expected waveform motion when enabled"

    # Disable again and verify immediate return to quiet state.
    dut.ui_in.value = pack_ui(mode=0, enable=0, pitch=20)
    for _ in range(20):
        await ClockCycles(dut.clk, 1)
        assert int(dut.uo_out.value) == 128
        uio = int(dut.uio_out.value)
        assert uio_bit(uio, 3) == 0
        assert uio_bit(uio, 1) == 0
        assert uio_bit(uio, 2) == 0


@cocotb.test()
async def test_ping_pong_mode_sync_behavior(dut):
    dut._log.info("Start ping-pong chirp sync test")
    clock = Clock(dut.clk, 1, unit="us")  # 1 MHz
    cocotb.start_soon(clock.start())

    await apply_reset(dut)

    # mode=2 is ping-pong chirp; expect sync on mode entry and each full down-sweep restart.
    dut.ui_in.value = pack_ui(mode=2, enable=1, pitch=8)
    dut.uio_in.value = pack_uio(rate=0, depth=2)

    pulses, max_run = await count_sync_pulses_and_width(dut, cycles=17000)
    assert pulses >= 2, "Expected mode-change pulse plus at least one ping-pong restart pulse"
    assert max_run == 1, f"Expected one-cycle sync pulses, got max pulse width {max_run}"


@cocotb.test()
async def test_pitch_and_rate_controls(dut):
    dut._log.info("Start control-sensitivity test")
    clock = Clock(dut.clk, 1, unit="us")  # 1 MHz
    cocotb.start_soon(clock.start())

    await apply_reset(dut)

    # Higher pitch should increase square_ref transition rate.
    dut.ui_in.value = pack_ui(mode=0, enable=1, pitch=1)
    dut.uio_in.value = pack_uio(rate=0, depth=0)
    await ClockCycles(dut.clk, 20)
    low_pitch_edges = await count_edges_on_uio_bit(dut, bit=1, cycles=4096)

    dut.ui_in.value = pack_ui(mode=0, enable=1, pitch=30)
    await ClockCycles(dut.clk, 20)
    high_pitch_edges = await count_edges_on_uio_bit(dut, bit=1, cycles=4096)
    assert high_pitch_edges > (low_pitch_edges + 5), (
        f"Expected higher pitch to increase edge rate, got low={low_pitch_edges}, high={high_pitch_edges}"
    )

    # In dual-tone mode, lower rate code should toggle sync more often.
    dut.ui_in.value = pack_ui(mode=3, enable=1, pitch=10)
    dut.uio_in.value = pack_uio(rate=0, depth=1)
    await ClockCycles(dut.clk, 20)
    fast_pulses, _ = await count_sync_pulses_and_width(dut, cycles=4096)

    dut.uio_in.value = pack_uio(rate=3, depth=1)
    await ClockCycles(dut.clk, 20)
    slow_pulses, _ = await count_sync_pulses_and_width(dut, cycles=4096)
    assert fast_pulses > slow_pulses, (
        f"Expected rate=0 to pulse faster than rate=3, got fast={fast_pulses}, slow={slow_pulses}"
    )


@cocotb.test()
async def test_control_space_smoke(dut):
    dut._log.info("Start control-space smoke test")
    clock = Clock(dut.clk, 1, unit="us")  # 1 MHz
    cocotb.start_soon(clock.start())

    await apply_reset(dut)

    for mode in range(4):
        for enable in (0, 1):
            for pitch in (0, 1, 15, 31):
                for rate in range(4):
                    for depth in range(4):
                        dut.ui_in.value = pack_ui(mode=mode, enable=enable, pitch=pitch)
                        dut.uio_in.value = pack_uio(rate=rate, depth=depth)
                        await ClockCycles(dut.clk, 16)

                        assert int(dut.uio_oe.value) == 0x0F
                        assert int(dut.uo_out.value) in range(256)
                        assert uio_bit(int(dut.uio_out.value), 3) == enable
