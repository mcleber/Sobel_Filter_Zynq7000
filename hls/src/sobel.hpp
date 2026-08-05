#ifndef SOBEL_H
#define SOBEL_H

#include <hls_stream.h>
#include <ap_axi_sdata.h>

// Resolucao FIXA da imagem (o hardware precisa saber o tamanho
// para gerar o TLAST no lugar certo). Para outra resolucao,
// recompile o IP ou passe WIDTH/HEIGHT via AXI-Lite (exercicio!).
#define WIDTH  512
#define HEIGHT 512

// ap_axiu<8,0,0,0> = pacote AXI-Stream com:
//   8  bits de TDATA (1 pixel grayscale)
//   0  bits de TUSER, TID, TDEST (nao usamos)
// A struct ja inclui os sinais keep/strb/last.
typedef ap_axiu<8, 0, 0, 0> axis_t;

void sobel_filter(hls::stream<axis_t> &in_stream,
                  hls::stream<axis_t> &out_stream);

#endif
