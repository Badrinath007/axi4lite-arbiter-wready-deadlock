# AXI4-Lite Arbiter — WREADY Ordering Deadlock (Root-Cause Study)

A single-port shared-memory arbiter for two AXI4-Lite write masters (DMA burst + CPU burst), with a genuine handshake-timing bug deliberately reproduced and diagnosed as a portfolio artifact.

## What's here

- `dma_master.v` / `cpu_master.v` — independent AXI4-Lite write masters (4-beat and 2-beat bursts respectively)
- `shared_spmem.v` — single-port memory, 3-cycle fixed access delay, backpressure-capable (`mem_busy`)
- `mem_arbiter.v` — correct fixed-priority arbiter (DMA wins ties)
- `mem_arbiter_buggy.v` — the same arbiter with one line reverted, reproducing a real timing bug found and fixed during development
- `arbiter_integration_tb.v` — concurrent test against the correct arbiter (passes, 0 errors)
- `arbiter_integration_tb_buggy.v` — same test against the buggy arbiter, with a simulation watchdog (hangs, as expected)
- `waveform.png` — captured stall, FSM states shown for all three modules

## Repo structure

```
axi4lite-arbiter-wready-deadlock/
├── README.md
├── rtl/
│   ├── dma_master.v
│   ├── cpu_master.v
│   ├── shared_spmem.v
│   ├── mem_arbiter.v          # correct version
│   └── mem_arbiter_buggy.v    # bug reverted, for reproduction
├── tb/
│   ├── arbiter_integration_tb.v         # passes against mem_arbiter.v
│   └── arbiter_integration_tb_buggy.v   # hangs against mem_arbiter_buggy.v
└── sim/
    ├── waveform.png            # zoomed capture, cursor at the 5045 ns hang point
    └── hang_log.txt            # HUNG: / $finish simulation transcript, verbatim
```

## The bug

`mem_arbiter_buggy.v` asserts `wready` for exactly one cycle, during the `S_AW` state, instead of holding it through `S_W` until `wvalid` is actually seen. A master's data-channel handshake can legally arrive one or more cycles after its address-channel handshake completes — so a single-cycle `wready` pulse can be (and, deterministically, is) missed.

This is a real ordering-dependency violation, not a contrived example: PULP's own `axi` project changelog documents the same bug class — a master depending on `aw_ready` before applying `w_valid` — as an AXI-specification violation that can lead to deadlock, fixed the same way this project fixes it (removing the dependency, holding `wready` until `wvalid` arrives).

## Verified result

Running the buggy arbiter against the concurrent testbench hangs permanently. Waveform confirms three independent FSMs parked in three different stuck states, with no timeout or forward progress:

| Module   | Stuck state | Meaning |
|----------|-------------|---------|
| Arbiter  | `S_B` (5)   | Waiting for `bready` from a master that will never respond |
| DMA      | `S_W` (2)   | Waiting for `wready`, already withdrawn |
| CPU      | `S_AW` (1)  | Never granted — arbiter never returns to `S_IDLE` |

The captured run shows CPU never reached grant, suggesting DMA alone triggers the stall — consistent with a single-master AW/W protocol-ordering violation rather than a classic multi-master circular-wait deadlock.

## Fix

`mem_arbiter.v` holds `wready` asserted through `S_W` (level-sensitive, not a single pulse) until `wvalid` is actually observed — matching how `dma_master.v` / `cpu_master.v` may legally delay their data phase. Verified passing, 0 errors, both masters concurrently.

## Toolchain

Quartus Prime + QuestaSim (Cyclone IV target).
