# SPDX-FileCopyrightText: © 2024 Tiny Tapeout
# SPDX-License-Identifier: Apache-2.0

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

# Bit positions
UI_AWVALID = 0
UI_ARVALID = 1
UI_WVALID  = 2
UI_RREADY  = 3
UI_BREADY  = 4
UI_ADDR    = 5  # use multiple bits if addr > 1
UI_WSTRB   = 6

def pack_ui(aw=0, ar=0, w=0, rr=1, br=1, addr=0, wstrb=1):
    v  = (aw & 1) << UI_AWVALID
    v |= (ar & 1) << UI_ARVALID
    v |= (w  & 1) << UI_WVALID
    v |= (rr & 1) << UI_RREADY
    v |= (br & 1) << UI_BREADY
    v |= (addr & 1) << UI_ADDR  # fix if addr width >1
    v |= (wstrb & 1) << UI_WSTRB
    return v

async def reset_dut(dut):
    dut.ena.value = 0
    dut.rst_n.value = 0
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    dut.ena.value = 1
    await ClockCycles(dut.clk, 2)

async def axi_write(dut, addr: int, data: int):
    dut.uio_in.value = data & 0xFF

    # Address phase
    dut.ui_in.value = pack_ui(aw=1, addr=addr)
    await RisingEdge(dut.clk)
    while not (int(dut.uo_out.value) & (1 << 0)):  # AWREADY
        await RisingEdge(dut.clk)
    dut.ui_in.value = pack_ui(addr=addr)  # drop AWVALID

    # Data phase
    dut.ui_in.value = pack_ui(w=1, addr=addr)
    await RisingEdge(dut.clk)
    while not (int(dut.uo_out.value) & (1 << 1)):  # WREADY
        await RisingEdge(dut.clk)
    dut.ui_in.value = pack_ui(addr=addr)  # drop WVALID

    # Write response
    await RisingEdge(dut.clk)
    while not (int(dut.uo_out.value) & (1 << 2)):  # BVALID
        await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)

async def axi_read(dut, addr: int) -> int:
    dut.ui_in.value = pack_ui(ar=1, addr=addr)
    await RisingEdge(dut.clk)
    while not (int(dut.uo_out.value) & (1 << 3)):  # ARREADY
        await RisingEdge(dut.clk)
    dut.ui_in.value = pack_ui(addr=addr)  # drop ARVALID

    await RisingEdge(dut.clk)
    while not (int(dut.uo_out.value) & (1 << 4)):  # RVALID
        await RisingEdge(dut.clk)

    data = int(dut.uio_out.value) & 0xFF
    await RisingEdge(dut.clk)
    return data

@cocotb.test()
async def test_byte_invert(dut):
    cocotb.start_soon(Clock(dut.clk, 40, units="ns").start())
    await reset_dut(dut)

    test_val = 0x5A
    expected = (~test_val) & 0xFF

    await axi_write(dut, addr=0, data=test_val)
    got = await axi_read(dut, addr=1)

    assert got == expected, f"Mismatch: got 0x{got:02X}, expected 0x{expected:02X}"
