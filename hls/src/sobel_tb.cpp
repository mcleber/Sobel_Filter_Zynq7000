#include "sobel.h"
#include <cstdio>

int main() {
    hls::stream<axis_t> in_s, out_s;

    // Imagem sintetica: um quadrado branco no centro
    // (bordas bem definidas -> facil conferir o Sobel)
    static unsigned char img[HEIGHT][WIDTH];
    for (int r = 0; r < HEIGHT; r++)
        for (int c = 0; c < WIDTH; c++)
            img[r][c] = (r > 128 && r < 384 && c > 128 && c < 384) ? 255 : 0;

    // Alimentar o stream de entrada
    for (int r = 0; r < HEIGHT; r++)
        for (int c = 0; c < WIDTH; c++) {
            axis_t p;
            p.data = img[r][c];
            p.keep = 1; p.strb = 1;
            p.last = (r == HEIGHT-1) && (c == WIDTH-1);
            in_s.write(p);
        }

    sobel_filter(in_s, out_s);

    // Salvar saida em PGM (abra com GIMP/IrfanView/qualquer visualizador)
    FILE *f = fopen("saida_sobel.pgm", "wb");
    fprintf(f, "P5\n%d %d\n255\n", WIDTH, HEIGHT);
    int last_ok = 0;
    for (int i = 0; i < WIDTH*HEIGHT; i++) {
        axis_t p = out_s.read();
        fputc(p.data, f);
        if (p.last) last_ok = 1;  // conferindo o TLAST!
    }
    fclose(f);

    if (!last_ok) { printf("ERRO: TLAST nao veio!\n"); return 1; }
    printf("OK! Confira saida_sobel.pgm\n");
    return 0;
}
