#include "sobel.hpp"

// =====================================================================
//  FILTRO SOBEL COM INTERFACE AXI4-STREAM
//  - Recebe pixels 8 bits (grayscale) em raster order (linha a linha)
//  - Usa "line buffers" para montar a janela 3x3 sem armazenar a
//    imagem inteira (a BRAM do FPGA nao caberia uma imagem grande)
// =====================================================================

void sobel_filter(hls::stream<axis_t> &in_stream,
                  hls::stream<axis_t> &out_stream)
{
// ---------------------------------------------------------------
// PRAGMAS DE INTERFACE: aqui nasce o AXI!
// ---------------------------------------------------------------
// axis  -> gera interface AXI4-Stream (TDATA/TVALID/TREADY/TLAST)
#pragma HLS INTERFACE axis port=in_stream
#pragma HLS INTERFACE axis port=out_stream
// ap_ctrl_none -> o bloco roda sozinho, sem precisar de "start"
// via registrador. Ele processa tudo que chegar no stream.
// (Alternativa: s_axilite, se voce quiser controlar via registrador)
#pragma HLS INTERFACE ap_ctrl_none port=return

    // -----------------------------------------------------------
    // LINE BUFFERS: guardam as 2 linhas anteriores da imagem.
    // Com a linha atual chegando pixel a pixel, temos as 3 linhas
    // necessarias para a janela 3x3 do Sobel.
    // -----------------------------------------------------------
    static unsigned char line_buf[2][WIDTH];
#pragma HLS ARRAY_PARTITION variable=line_buf complete dim=1

    // Janela 3x3 deslizante (registradores)
    unsigned char window[3][3];
#pragma HLS ARRAY_PARTITION variable=window complete dim=0

    // -----------------------------------------------------------
    // LOOP PRINCIPAL: um pixel por iteracao.
    // PIPELINE II=1 -> aceita 1 pixel novo por ciclo de clock.
    // A 100 MHz isso da 100 Mpixel/s de throughput!
    // -----------------------------------------------------------
    row_loop: for (int row = 0; row < HEIGHT; row++) {
        col_loop: for (int col = 0; col < WIDTH; col++) {
#pragma HLS PIPELINE II=1

            // 1) LER um pixel do stream de entrada
            axis_t in_pix = in_stream.read();
            unsigned char new_pix = in_pix.data;

            // 2) DESLIZAR a janela 3x3 uma coluna para a esquerda
            for (int i = 0; i < 3; i++) {
                window[i][0] = window[i][1];
                window[i][1] = window[i][2];
            }

            // 3) NOVA COLUNA da janela vem dos line buffers + pixel novo
            window[0][2] = line_buf[0][col]; // linha row-2
            window[1][2] = line_buf[1][col]; // linha row-1
            window[2][2] = new_pix;          // linha atual

            // 4) ATUALIZAR line buffers (a linha atual vira "anterior")
            line_buf[0][col] = line_buf[1][col];
            line_buf[1][col] = new_pix;

            // 5) CALCULAR SOBEL (Gx e Gy)
            //     Gx = [-1 0 +1]      Gy = [-1 -2 -1]
            //          [-2 0 +2]           [ 0  0  0]
            //          [-1 0 +1]           [+1 +2 +1]
            int gx = -window[0][0] + window[0][2]
                     - 2*window[1][0] + 2*window[1][2]
                     - window[2][0] + window[2][2];

            int gy = -window[0][0] - 2*window[0][1] - window[0][2]
                     + window[2][0] + 2*window[2][1] + window[2][2];

            // Magnitude aproximada: |Gx| + |Gy| (evita raiz quadrada,
            // que custaria muitos recursos no FPGA)
            int mag = (gx < 0 ? -gx : gx) + (gy < 0 ? -gy : gy);
            if (mag > 255) mag = 255; // saturacao em 8 bits

            // Bordas da imagem: janela incompleta -> saida 0
            unsigned char out_pix;
            if (row < 2 || col < 2)
                out_pix = 0;
            else
                out_pix = (unsigned char) mag;

            // 6) ESCREVER no stream de saida
            axis_t out;
            out.data = out_pix;
            out.keep = 1;          // todos os bytes validos
            out.strb = 1;
            // TLAST = 1 no ULTIMO pixel: OBRIGATORIO!
            // Sem TLAST o canal S2MM do DMA nunca "fecha" a
            // transferencia e seu codigo trava esperando. Esse e o
            // erro #1 de quem comeca com AXI DMA.
            out.last = (row == HEIGHT-1) && (col == WIDTH-1);
            out_stream.write(out);
        }
    }
}