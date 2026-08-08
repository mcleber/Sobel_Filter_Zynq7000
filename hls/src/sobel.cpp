#include "sobel.hpp"

void sobel_filter(hls::stream<axis_t> &in_stream,
                  hls::stream<axis_t> &out_stream)
{
#pragma HLS INTERFACE axis port=in_stream
#pragma HLS INTERFACE axis port=out_stream
#pragma HLS INTERFACE ap_ctrl_none port=return

    // ============================================================
    // Line Buffers
    // ============================================================
    static unsigned char line_buf[2][WIDTH];
#pragma HLS ARRAY_PARTITION variable=line_buf complete dim=1

    // ============================================================
    // Janela 3x3
    // ============================================================
    unsigned char window[3][3];
#pragma HLS ARRAY_PARTITION variable=window complete dim=0

row_loop:
    for (int row = 0; row < HEIGHT; row++)
    {
    col_loop:
        for (int col = 0; col < WIDTH; col++)
        {
#pragma HLS PIPELINE II=1

            //------------------------------------------------------
            // Recebe um pixel
            //------------------------------------------------------
            axis_t pixel = in_stream.read();

            unsigned char value = pixel.data;

            //------------------------------------------------------
            // Desloca a janela
            //------------------------------------------------------
            for (int i = 0; i < 3; i++)
            {
                window[i][0] = window[i][1];
                window[i][1] = window[i][2];
            }

            //------------------------------------------------------
            // Nova coluna da janela
            //------------------------------------------------------
            window[0][2] = line_buf[0][col];
            window[1][2] = line_buf[1][col];
            window[2][2] = value;

            //------------------------------------------------------
            // Atualiza os line buffers
            //------------------------------------------------------
            line_buf[0][col] = line_buf[1][col];
            line_buf[1][col] = value;

            //------------------------------------------------------
            // Calcula Gx
            //------------------------------------------------------
            int gx =
                -window[0][0] + window[0][2]
                -2 * window[1][0] + 2 * window[1][2]
                -window[2][0] + window[2][2];

            //------------------------------------------------------
            // Calcula Gy
            //------------------------------------------------------
            int gy =
                -window[0][0] - 2 * window[0][1] - window[0][2]
                +window[2][0] + 2 * window[2][1] + window[2][2];

            //------------------------------------------------------
            // Calcula a magnitude
            //------------------------------------------------------
            int mag =
                (gx < 0 ? -gx : gx) +
                (gy < 0 ? -gy : gy);

            (void)mag;

            // Continua enviando o pixel original
            out_stream.write(pixel);
        }
    }
}
