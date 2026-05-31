# Standalone FPGA OdoCrypt Miner on QMTECH Cyclone V SoC

## Claude Execution Brief

This document replaces the earlier concept-only plan with a **validation-first execution brief** intended for Claude to follow carefully.

The objective is **not** to blindly implement a speculative architecture. The objective is to:

1. inspect the real `odo-miner` codebase,
2. validate the exact QMTECH board constraints,
3. determine whether the proposed standalone architecture is actually compatible,
4. then implement the project in phased milestones.

---

## Project Goal

Convert the open-source `odo-miner` project from a **PC-dependent FPGA miner** into a **standalone mining appliance** using the **ChinaQMTECH / QMTECH Cyclone V SoC KFB with Dual SDRAM** board.

### Target runtime architecture
- The **ARM HPS** on the Cyclone V SoC runs embedded Linux.
- Linux handles **networking, pool communication, and stratum logic**.
- Linux communicates directly with the FPGA fabric through an **HPS-to-FPGA memory-mapped interface**.
- The **FPGA fabric** performs the mining work.
- The final system should run **without a PC during normal mining operation**.

### Critical instruction
This architecture is currently a **hypothesis**, not a verified implementation fact.

Claude must **not assume** that the existing `odo-miner` repository already maps cleanly to this design.

If any detail is unknown, Claude must:
- say that it is unknown,
- explain why it matters,
- identify what file, schematic, document, or test would resolve it,
- and mark it as a blocker, dependency, or risk.

Claude must **not fabricate**:
- board-specific pin assignments,
- DDR parameters,
- PHY details,
- device-tree details,
- host interface widths,
- or internal RTL behavior not directly supported by evidence.

---

## Current Understanding of the Architecture

### Likely current design
The current `odo-miner` project appears to be based on a classic host-controlled FPGA mining flow:
- a PC runs the host software,
- the host uses a JTAG or tool-driven path to communicate with the FPGA,
- the FPGA performs the mining algorithm,
- and the host handles pool/stratum networking.

### Desired standalone design
The desired replacement architecture is:
- HPS Linux replaces the PC,
- JTAG runtime control is removed from normal operation,
- the miner core is exposed through a memory-mapped register interface,
- pool logic runs on the HPS,
- FPGA configuration loads at boot from local storage.

This is a plausible architecture for Cyclone V SoC, but it is **not yet proven** for this exact repository and board combination.

---

## Non-Negotiable Working Rules for Claude

Claude must follow these execution rules throughout the project:

1. **Validation before implementation**
   - Do not write RTL or Linux integration code until the relevant assumptions are checked.

2. **No invention of missing details**
   - If the board schematic, repo structure, or algorithm behavior is unknown, do not guess.

3. **Repository evidence first**
   - Derive interface proposals from the actual `odo-miner` source tree, not from generic FPGA miner patterns.

4. **Board evidence first**
   - Derive SoC bring-up recommendations from actual QMTECH board documentation or known compatible references.

5. **Milestone-based execution**
   - Break the work into proof-of-concept milestones with acceptance criteria.

6. **Separate facts from assumptions**
   - Every major response should distinguish:
     - confirmed facts,
     - assumptions,
     - unknowns,
     - risks,
     - and next actions.

7. **Prefer minimal proof before large rewrites**
   - First prove that HPS↔FPGA MMIO works on this board using a trivial design before modifying the full miner.

---

## Phase -1 - Project Repository Setup

This phase should happen immediately so the project has a clean working structure before analysis and implementation begin.

### Objectives
- Create a dedicated repository for the standalone miner effort.
- Preserve a clear boundary between upstream `odo-miner` and new standalone SoC-specific work.
- Organize documentation, FPGA work, Linux/HPS work, and bring-up notes so the project remains maintainable.

### Required tasks
Claude should recommend a repository strategy that covers:
- whether to create a new standalone project repository,
- whether to include `odo-miner` as a submodule, subtree, or imported snapshot,
- how to preserve attribution and traceability to upstream,
- how to separate upstream code from board-specific and standalone-specific modifications,
- and how to record experimental bring-up findings and milestone results.

### Recommended repository structure
A structure similar to the following is preferred unless repository evidence suggests a better split:

```text
standalone-odo-miner/
├── README.md
├── docs/
│   ├── architecture.md
│   ├── risks.md
│   ├── milestones.md
│   └── board-notes.md
├── upstream/
│   └── odo-miner/
├── fpga/
│   ├── rtl/
│   ├── qsys/
│   ├── constraints/
│   └── build/
├── hps/
│   ├── miner-control/
│   ├── stratum/
│   ├── tests/
│   └── service/
├── boot/
│   ├── uboot/
│   ├── device-tree/
│   └── fpga-load/
├── scripts/
│   ├── build-fpga.sh
│   ├── build-linux.sh
│   └── deploy-sd.sh
├── references/
│   ├── qmtech-board/
│   └── odocrypt-notes/
└── notes/
    ├── bringup-log.md
    └── test-results.md
```

### Repository management expectations
Claude should explicitly address:
- repository naming,
- initial branch strategy,
- how upstream changes are tracked,
- where generated artifacts should and should not live,
- and what documentation should be committed from day one.

### Acceptance criteria for Phase -1
- A dedicated repository strategy is defined.
- The relationship to upstream `odo-miner` is defined.
- Directory structure is defined for FPGA, HPS, boot, scripts, docs, and notes.
- The project can proceed without mixing unrelated files into an ad hoc working folder.

---

## Phase 0 - Repository Forensics and Feasibility Analysis

Claude must begin here. No implementation code should be generated before this phase is complete.

### Objectives
- Determine how `odo-miner` actually works.
- Verify whether the proposed standalone architecture is compatible with the existing codebase.
- Identify the real integration points.

### Required tasks

#### 0.1 Inspect repository structure
Identify:
- top-level directories,
- RTL source files,
- top-level FPGA module names,
- build scripts,
- host-side scripts,
- tool-specific dependencies,
- and any documentation that explains the current workflow.

#### 0.2 Identify the actual FPGA control path
Determine:
- how work is currently injected into the FPGA,
- how results are retrieved,
- whether JTAG, System Console, in-system probes, or other tool-driven interfaces are used,
- whether the host invokes Quartus tools at runtime,
- and what data format is exchanged with the FPGA.

#### 0.3 Trace the mining job lifecycle
Determine:
- what the host receives from the pool,
- how the job is transformed before being sent to the FPGA,
- whether the FPGA expects midstate, header words, target, or another format,
- and how candidate results are validated and submitted.

#### 0.4 Identify host preprocessing assumptions
Determine whether the host software performs any important preprocessing such as:
- midstate generation,
- endian conversion,
- target packing,
- nonce range management,
- stale-job cancellation,
- result filtering,
- or algorithm-specific transformations.

#### 0.5 Assess interface replaceability
Answer these questions:
- Is the current FPGA-side interface sufficiently isolated that it can be wrapped or replaced cleanly?
- Is a simple register interface likely to be enough?
- Are FIFOs, interrupts, or more complex command queues likely to be required?
- Is the core tightly coupled to the current host-control method?

### Required output for Phase 0
Claude should produce:
1. a repository map,
2. a job/data-flow summary,
3. a host-interface summary,
4. a list of confirmed facts,
5. a list of assumptions still unproven,
6. and a feasibility judgment on whether the standalone architecture looks realistic.

### Acceptance criteria for Phase 0
- The actual RTL entry points are identified.
- The current host/FPGA interaction path is described using evidence from the repo.
- The minimum data needed by the FPGA is identified or clearly marked unknown.
- A reasoned answer is given on whether an MMIO wrapper is plausible.

---

## Phase 0.5 - OdoCrypt-Specific Feasibility Gate

This phase exists because the mining algorithm may impose constraints that make a static standalone design more difficult than expected.

### Objectives
Determine whether OdoCrypt behavior creates architectural risk for a standalone FPGA appliance.

### Required tasks
Claude must determine, from repository evidence and trusted references if needed:
- whether OdoCrypt changes in a way that requires more than ordinary job updates,
- whether the FPGA design remains valid over time without re-synthesis,
- whether the algorithm relies on seeds, permutations, or periodic structural changes,
- and whether the existing miner implementation assumes any external regeneration or update process.

### Critical question
Can this miner reasonably operate as a **static bitstream + changing job data** appliance, or does the algorithm introduce requirements that undermine that model?

### Acceptance criteria for Phase 0.5
- Claude explicitly states whether the static-wrapper concept appears valid, invalid, or unresolved.
- Any unresolved algorithm-level risks are clearly listed.
- If the design would require periodic reconfiguration or regeneration, that is elevated as a project-level risk immediately.

---

## Phase 0.75 - QMTECH Board Validation

This phase validates the target hardware platform before architecture-specific implementation begins.

### Objectives
Determine the exact bring-up requirements and support baseline for the QMTECH Cyclone V SoC board.

### Required tasks
Claude must identify, confirm, or request the following:
- exact board name and revision,
- available schematics and pinout,
- DDR memory part information,
- Ethernet PHY model and interface mode,
- SD boot path,
- UART availability,
- clock sources,
- reset topology,
- whether a known-good Quartus reference design exists,
- whether a known-good U-Boot/Linux baseline exists,
- and whether the board is already supported by any public SoCFPGA reference project.

### Board support classification
Claude must classify the board as one of:
- **Fully supported baseline exists**
- **Partial baseline exists**
- **Bring-up required from scratch**

### Acceptance criteria for Phase 0.75
- The board-specific unknowns are explicitly listed.
- The board support classification is stated.
- The required evidence or missing documents are listed.
- No invented HPS pin, PHY, or DDR details are used.

---

## Phase 1 - Minimal SoC Bring-Up Strategy

This phase begins only after the earlier validation phases show that the project is still plausible.

### Objective
Create the smallest practical plan to prove that the QMTECH board can support the required HPS↔FPGA integration path.

### Required design direction
Claude should propose the simplest proof-of-concept bring-up path using:
- known-good HPS configuration if available,
- minimal FPGA fabric logic,
- and a minimal Linux userspace test.

### Preferred proof-of-concept
Before touching the miner core, use a tiny FPGA fabric design that exposes a few memory-mapped registers such as:
- scratch register,
- free-running counter,
- status register,
- and optional interrupt.

### Phase 1 outputs
Claude should define:
- the minimal Quartus/Platform Designer system structure,
- which HPS bridge to use,
- the address map concept,
- the minimum Linux side access strategy,
- and the specific proof that would validate MMIO communication.

### Acceptance criteria for Phase 1
- A test design is defined that can prove HPS↔FPGA memory-mapped communication.
- The design avoids unnecessary miner-specific complexity.
- The proof method is clear enough to validate read/write behavior on real hardware.

---

## Phase 2 - HPS to FPGA MMIO Proof of Life

### Objective
Demonstrate that Linux on the HPS can read and write FPGA fabric registers reliably.

### Recommended prototype approach
- Start with a userspace test program.
- `/dev/mem` is acceptable for the first proof-of-concept.
- UIO or a proper driver may follow later if needed.

### Important caution
Claude must present `/dev/mem` as a prototype path, not as the final production architecture unless justified.

### Required outputs
Claude should define:
- a minimal register map for the test design,
- userspace access method,
- expected read/write behavior,
- and a simple diagnostic script or test plan.

### Acceptance criteria for Phase 2
- Linux can write a register in FPGA fabric and read it back.
- Linux can read a changing value such as a counter from FPGA fabric.
- The bridge, address map, and userspace method are validated on the actual board.

---

## Phase 3 - Miner Core Interface Extraction

This phase translates repository analysis into an actual integration boundary.

### Objective
Identify the exact boundary between the existing miner logic and the current host-control path.

### Required tasks
Claude must derive from the repository:
- what signals the miner actually needs as inputs,
- what outputs it generates,
- what control sequencing is required,
- what reset/clocking dependencies exist,
- and what job lifecycle semantics must be preserved.

### Important warning
Claude must not assume that the interface is only:
- midstate,
- target,
- start,
- status,
- nonce.

That may be true, but must be proven.

### Additional interface concerns to evaluate
- job ID
- stale job cancel
- work queue depth
- multiple result handling
- result valid handshake
- restart semantics
- heartbeat/watchdog
- nonce range assignment
- target formatting
- endian issues

### Acceptance criteria for Phase 3
- The miner-core boundary is described from real source evidence.
- A proposed replacement interface is justified by the existing design.
- Unknown interface elements are explicitly called out instead of guessed.

---

## Phase 4 - Memory-Mapped Wrapper Design

This phase begins only after the miner interface has been extracted from the repository.

### Objective
Design an FPGA wrapper that replaces the existing runtime host-control path with an HPS-accessible register interface.

### Expected design direction
Claude should propose a wrapper that may include some combination of:
- memory-mapped control/status registers,
- command registers,
- result registers,
- small FIFOs,
- optional interrupt support,
- and synchronization across clock domains if needed.

### Required considerations
Claude must address:
- clock-domain crossing,
- reset behavior,
- stale job replacement behavior,
- host writes while mining is active,
- how result validity is signaled,
- whether polling is sufficient,
- and how multiple results would be handled if possible.

### Acceptance criteria for Phase 4
- The wrapper architecture is consistent with the actual miner interface.
- The wrapper semantics are explicit.
- The register map is justified rather than generic.
- Any limitations are clearly documented.

---

## Phase 5 - Linux Control Path Design

### Objective
Replace the old PC-driven runtime control path with a local HPS-side control program.

### Expected responsibilities of the HPS-side program
- receive jobs from the pool/stratum layer,
- transform them into the exact FPGA input format required,
- load work into the wrapper interface,
- monitor status/results,
- submit candidate shares,
- handle stale jobs,
- and recover cleanly from network interruptions.

### Prototype vs production distinction
Claude may propose:
- a Python prototype first,
- then a harder userspace implementation or driver-backed model later if justified.

### Acceptance criteria for Phase 5
- The host-side control path is mapped end-to-end from network job to FPGA command to candidate result submission.
- Job lifecycle transitions are defined.
- Error handling and stale-job handling are included.

---

## Phase 6 - Boot and Deployment Architecture

### Objective
Define how the board boots into a self-contained miner appliance.

### Required areas to address
Claude must explain, using evidence where possible:
- boot source expectations,
- preloader / SPL considerations,
- U-Boot role,
- FPGA bitstream loading strategy,
- Linux kernel and device tree role,
- root filesystem placement,
- and service startup ordering.

### Important caution
Claude must not present generic SoCFPGA boot advice as board-specific fact unless it is supported by known QMTECH board evidence.

### Acceptance criteria for Phase 6
- The boot architecture is coherent.
- FPGA loading point is clearly defined.
- Linux userspace miner start sequence is defined.
- Unknown board-specific boot details are explicitly listed.

---

## Phase 7 - Appliance Hardening

The project is not complete when the miner first hashes. A usable standalone appliance also needs operational hardening.

### Required operational topics
Claude should plan for:
- automatic startup,
- network reconnect behavior,
- stale share handling,
- crash restart,
- watchdog strategy,
- logging,
- thermal monitoring,
- optional fan control if hardware supports it,
- version tracking for software and bitstream,
- and recovery strategy if a deployment fails.

### Acceptance criteria for Phase 7
- The design includes a realistic unattended-operation strategy.
- Failure and recovery paths are considered.
- Logging and observability are not omitted.

---

## Required Output Format for Claude at Each Step

For each major response, Claude should use this structure:

### 1. Confirmed facts
Only facts supported by repository evidence, board documentation, or established SoCFPGA behavior.

### 2. Assumptions
What is still being inferred and not yet proven.

### 3. Unknowns / blockers
What information is missing and why it matters.

### 4. Risks
Highest-risk issues, ranked if possible.

### 5. Recommendation
What the next action should be.

### 6. Code or implementation artifacts
Only include code when the assumptions required for that code are sufficiently closed.

---

## Strongly Preferred Milestone Plan

Claude should prefer this milestone sequence unless evidence suggests a better one:

### Milestone A - Repository analysis complete
**Acceptance:** actual top-level modules, runtime control path, and host data flow are identified.

### Milestone B - Board support baseline established
**Acceptance:** board support is classified and major hardware unknowns are listed.

### Milestone C - HPS↔FPGA MMIO proof works
**Acceptance:** Linux reads/writes trivial FPGA registers on the actual board.

### Milestone D - Miner interface extracted
**Acceptance:** miner control boundary is documented from source evidence.

### Milestone E - Wrapper integrated around miner core
**Acceptance:** host can load test work and observe deterministic control/status behavior.

### Milestone F - Local standalone mining loop works
**Acceptance:** HPS can feed jobs to FPGA and process returned candidate results without a PC.

### Milestone G - Pool integration works
**Acceptance:** jobs arrive from a pool and candidate shares are submitted correctly.

### Milestone H - Appliance hardening complete
**Acceptance:** system starts automatically, logs correctly, and recovers from common failures.

---

## What Claude Must Not Do

Claude must not:
- jump directly into writing an Avalon wrapper before validating the existing miner interface,
- assume the board has the same support path as an Intel reference dev kit,
- present guessed PHY, DDR, or pinmux details as fact,
- treat `/dev/mem` prototype code as automatically suitable for final deployment,
- ignore OdoCrypt-specific feasibility questions,
- or skip the HPS↔FPGA proof-of-life milestone.

---

## Initial Task for Claude

Claude, begin with **Phase 0, Phase 0.5, and Phase 0.75 only**.

Do **not** write code yet.

Your first response should contain:
1. confirmed facts about the `odo-miner` repository,
2. confirmed or required facts about the QMTECH Cyclone V SoC board,
3. assumptions in the current standalone-miner concept,
4. major technical risks,
5. a feasibility judgment,
6. and a milestone-driven next-step plan.

If the repository or board information is insufficient, explicitly state what additional files, links, schematics, or documentation are required before implementation can begin.

---

## Summary

This project may be feasible, but feasibility depends on three things being proven early:

1. the real host/miner interface inside `odo-miner`,
2. the OdoCrypt-specific architectural constraints,
3. and the real support baseline for the QMTECH Cyclone V SoC board.

The correct execution strategy is therefore:
- validate first,
- prove HPS↔FPGA communication second,
- integrate the miner core third,
- and only then turn it into a hardened standalone appliance.
