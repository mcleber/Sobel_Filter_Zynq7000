#ifndef SOBEL_H
#define SOBEL_H

#include <hls_stream.h>
#include <ap_axi_sdata.h>

// FIXED image resolution (the hardware needs to know the size in
// order to generate TLAST at the right spot). For a different
// resolution, recompile the IP or pass WIDTH/HEIGHT via AXI-Lite
// (exercise!).
#define WIDTH  512
#define HEIGHT 512

// ap_axiu<8,0,0,0> = AXI-Stream packet with:
//   8  bits of TDATA (1 grayscale pixel)
//   0  bits of TUSER, TID, TDEST (not used)
// The struct already includes the keep/strb/last signals.
typedef ap_axiu<8, 0, 0, 0> axis_t;

void sobel_filter(hls::stream<axis_t> &in_stream,
                  hls::stream<axis_t> &out_stream);

#endif
