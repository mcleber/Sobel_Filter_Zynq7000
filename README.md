<a id="top"></a>

# Sobel Filter on Zynq-7000 (PS + PL) Using AXI DMA and HDMI

![Platform](https://img.shields.io/badge/Platform-FPGA-blue)
![Board](https://img.shields.io/badge/Board-PYNQ--Z2-green)
![EDA](https://img.shields.io/badge/EDA-Vivado%202025.2.1-blue)
![IDE](https://img.shields.io/badge/IDE-Vitis-blue)
![HDL](https://img.shields.io/badge/HDL-Verilog-orange)
![License](https://img.shields.io/badge/License-GPL--3.0-darkgray)

This repository contains the implementation of a hardware-accelerated image processing system for the **Xilinx Zynq-7000** architecture (ARM Cortex-A9 + FPGA). The application executes the **Sobel Edge Detection Filter** as a streaming hardware accelerator in the Programmable Logic (PL), communicating with the Processing System (PS) DDR memory through **AXI DMA** using **AXI4-Lite**, **AXI4-Full**, and **AXI4-Stream** interfaces. The project also includes support for displaying the processed image in real time through an **HDMI** output.

---

## Directory Structure

The project follows a modular organization that separates version-controlled source code from automatically generated project files.

```text
Sobel_Filter_Zynq7000/
│
├── docs/                             # Detailed implementation guides
│   ├── tutorial_sobel_filter_p1.md   # Main tutorial (Parts 0–4)
│   ├── tutorial_sobel_filter_p2.md   # Addendum 1: HDMI output using AXI VDMA
│   └── tutorial_sobel_filter_p3.md   # Addendum 2: BRAM, Interrupts, RGB and Benchmark
│
├── hls/                       # Vitis HLS
│   ├── src/                   # C/C++ source files
│   └── proj/                  # Generated project files (discard)
│
├── hw/                        # Vivado
│   ├── hdl/                   # Custom RTL (Verilog/VHDL)
│   ├── xdc/                   # Constraint files
│   ├── ip_repo/               # Exported HLS IPs
│   ├── bd/                    # Block Design TCL scripts
│   └── proj/                  # Generated project files (discard)
│
├── sw/                        # Vitis (Bare-Metal Software)
│   ├── src/                   # C source code
│   ├── xsa/                   # Exported hardware platforms
│   └── workspace/             # Generated workspace (discard)
│
├── images/                    # Test images and output results
│
├── .editorconfig
├── .gitattributes
├── .gitignore
|
├── License
└── README.md
```

---

## Implementation Guide

The implementation is divided into three documents. Reading them in order is recommended.

| Part | Document | Main Topics | Difficulty |
|:---:|----------|-------------|:---------:|
| 1 | `tutorial_sobel_filter_p1.md` | Vitis HLS, Sobel IP, AXI4-Stream, AXI DMA, Vivado, Vitis | ★★★☆☆ |
| 2 | `tutorial_sobel_filter_p2.md` | AXI VDMA, Video Timing Controller (VTC), HDMI Output | ★★☆☆☆ |
| 3 | `tutorial_sobel_filter_p3.md` | BRAM, Interrupts, RGB Image Processing, Benchmarking | ★★★★☆ |

---

## Development Tools

The following tools are used throughout the project.

| Tool | Version | Description |
|------|:-------:|-------------|
| Vivado | 2025.2.1 | FPGA hardware design, synthesis, implementation, and bitstream generation. |
| Vitis | 2025.2.1 | Bare-metal software development for the ARM Cortex-A9 Processing System. |

---

## Reference Documentation (AMD/Xilinx)

The following official AMD/Xilinx documentation is recommended throughout the implementation.

| Document | Title | Main Topics |
|----------|-------|-------------|
| PG021 | AXI DMA Product Guide | AXI DMA architecture, register map, Simple Mode vs Scatter-Gather, buffer descriptors and transfer control. |
| UG585 | Zynq-7000 Technical Reference Manual | Processing System architecture, GP/HP AXI ports, DDR controller, GIC, clocks and interconnect. |
| UG1399 | Vitis HLS User Guide | C/C++ coding style, HLS pragmas (`INTERFACE`, `PIPELINE`, `ARRAY_PARTITION`), optimization techniques and `hls::stream`. |
| UG994 | Vivado Design Suite User Guide: Designing IP Subsystems | IP Integrator, Address Editor, Block Design creation and TCL export. |
| UG908 | Vivado Design Suite User Guide: Programming and Debugging | FPGA programming, debugging and Integrated Logic Analyzer (ILA). |

---

## Project Recommendations

### Git Repository

Do **not** commit generated project files.

Keep the repository lightweight by versioning only:

- Source code (C/C++)
- RTL source files (Verilog/VHDL)
- Constraint files (`.xdc`)
- Hardware platform files (`.xsa`) when required
- Block Design TCL scripts (`File → Export → Export Block Design`)
- Documentation

Generated directories such as `proj/` and `workspace/` should remain outside version control.

### Directory Naming

Avoid directory names containing:

- Spaces
- Accented characters
- Special symbols

Prefer simple names such as:

- `src/`
- `docs/`
- `hw/`
- `sw/`
- `images/`

---

## License

This project is distributed under the **GNU General Public License v3.0 (GPL-3.0)**.

---

## Additional Notes

This repository is intended as practical educational material for learning FPGA-based image processing using the Xilinx Zynq-7000 platform, Vitis HLS, Vivado, AXI DMA, and HDMI video output.

---

↑ [Back to top](#top)
