#include "sobel.hpp"

// =====================================================================
//  SOBEL FILTER WITH AXI4-STREAM INTERFACE
//  - Receives 8-bit pixels (grayscale) in raster order (line by line)
//  - Uses "line buffers" to build the 3x3 window without storing the
//    whole image (the FPGA's BRAM wouldn't fit a large image)
// =====================================================================

void sobel_filter(hls::stream<axis_t> &in_stream,
                  hls::stream<axis_t> &out_stream)
{
// ---------------------------------------------------------------
// INTERFACE PRAGMAS: this is where the AXI interfaces are born!
// ---------------------------------------------------------------
// axis  -> generates an AXI4-Stream interface (TDATA/TVALID/TREADY/TLAST)
#pragma HLS INTERFACE axis port=in_stream
#pragma HLS INTERFACE axis port=out_stream
// ap_ctrl_none -> the block runs on its own, without needing "start"
// via a register. It processes whatever comes in on the stream.
// (Alternative: s_axilite, if you want to control it via a register)
#pragma HLS INTERFACE ap_ctrl_none port=return

    // -----------------------------------------------------------
    // LINE BUFFERS: hold the 2 previous rows of the image.
    // With the current row arriving pixel by pixel, we get the 3
    // rows needed for the Sobel 3x3 window.
    // -----------------------------------------------------------
    static unsigned char line_buf[2][WIDTH];
#pragma HLS ARRAY_PARTITION variable=line_buf complete dim=1

    // Sliding 3x3 window (registers)
    unsigned char window[3][3];
#pragma HLS ARRAY_PARTITION variable=window complete dim=0

    // -----------------------------------------------------------
    // MAIN LOOP: one pixel per iteration.
    // PIPELINE II=1 -> accepts 1 new pixel per clock cycle.
    // At 100 MHz that's 100 Mpixel/s of throughput!
    // -----------------------------------------------------------
    row_loop: for (int row = 0; row < HEIGHT; row++) {
        col_loop: for (int col = 0; col < WIDTH; col++) {
#pragma HLS PIPELINE II=1

            // 1) READ one pixel from the input stream
            axis_t in_pix = in_stream.read();
            unsigned char new_pix = in_pix.data;

            // 2) SLIDE the 3x3 window one column to the left
            for (int i = 0; i < 3; i++) {
                window[i][0] = window[i][1];
                window[i][1] = window[i][2];
            }

            // 3) NEW COLUMN of the window comes from the line buffers
            //    plus the new pixel
            window[0][2] = line_buf[0][col]; // row-2
            window[1][2] = line_buf[1][col]; // row-1
            window[2][2] = new_pix;          // current row

            // 4) UPDATE line buffers (the current row becomes "previous")
            line_buf[0][col] = line_buf[1][col];
            line_buf[1][col] = new_pix;

            // 5) COMPUTE SOBEL (Gx and Gy)
            //     Gx = [-1 0 +1]      Gy = [-1 -2 -1]
            //          [-2 0 +2]           [ 0  0  0]
            //          [-1 0 +1]           [+1 +2 +1]
            int gx = -window[0][0] + window[0][2]
                     - 2*window[1][0] + 2*window[1][2]
                     - window[2][0] + window[2][2];

            int gy = -window[0][0] - 2*window[0][1] - window[0][2]
                     + window[2][0] + 2*window[2][1] + window[2][2];

            // Approximate magnitude: |Gx| + |Gy| (avoids a square root,
            // which would cost a lot of resources on the FPGA)
            int mag = (gx < 0 ? -gx : gx) + (gy < 0 ? -gy : gy);
            if (mag > 255) mag = 255; // saturate to 8 bits

            // Image borders: incomplete window -> output 0
            unsigned char out_pix;
            if (row < 2 || col < 2)
                out_pix = 0;
            else
                out_pix = (unsigned char) mag;

            // 6) WRITE to the output stream
            axis_t out;
            out.data = out_pix;
            out.keep = 1;          // all bytes valid
            out.strb = 1;
            // TLAST = 1 on the LAST pixel: MANDATORY!
            // Without TLAST the S2MM channel of the DMA never "closes"
            // the transfer and your code hangs waiting. This is the
            // #1 mistake for anyone starting out with AXI DMA.
            out.last = (row == HEIGHT-1) && (col == WIDTH-1);
            out_stream.write(out);
        }
    }
}
