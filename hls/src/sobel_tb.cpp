#include "sobel.hpp"
#include "pgm_io.hpp"
#include <cstdio>

int main(int argc, char **argv) {
    hls::stream<axis_t> in_s, out_s;

    static unsigned char img[HEIGHT][WIDTH];

    // PT: Caminho de saida padrao, pode ser sobrescrito via argv[2]
    // EN: Default output path, can be overridden via argv[2]
    const char *output_path = "saida_sobel.pgm";

    if (argc >= 2) {
        // PT: Um caminho de imagem foi passado -> tenta carregar do disco.
        //     Uso: <executavel> <imagem_entrada.pgm> [imagem_saida.pgm]
        // EN: An image path was provided -> try to load it from disk.
        //     Usage: <executable> <input_image.pgm> [output_image.pgm]
        printf("Usando imagem externa: %s\n", argv[1]);
        printf("Using external image: %s\n", argv[1]);

        if (!read_pgm(argv[1], img, WIDTH, HEIGHT)) {
            return 1; // PT: erro ja reportado dentro de read_pgm | EN: error already reported inside read_pgm
        }

        if (argc >= 3) output_path = argv[2];

    } else {
        // PT: Nenhum argumento -> gera a imagem sintetica padrao (quadrado branco no centro)
        //     (bordas bem definidas -> facil conferir o Sobel)
        // EN: No argument -> generate the default synthetic image (white square in the center)
        //     (well-defined edges -> easy to verify the Sobel output)
        printf("Nenhuma imagem informada, gerando quadrado sintetico.\n");
        printf("No image provided, generating synthetic square.\n");

        for (int r = 0; r < HEIGHT; r++)
            for (int c = 0; c < WIDTH; c++)
                img[r][c] = (r > 128 && r < 384 && c > 128 && c < 384) ? 255 : 0;
    }

    // Alimentar o stream de entrada
    // Feed the input stream
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
    // Save the output as PGM (open with GIMP/IrfanView/any viewer)
    FILE *f = fopen(output_path, "wb");
    fprintf(f, "P5\n%d %d\n255\n", WIDTH, HEIGHT);
    int last_ok = 0;
    for (int i = 0; i < WIDTH*HEIGHT; i++) {
        axis_t p = out_s.read();
        fputc(p.data, f);
        if (p.last) last_ok = 1;  // conferindo o TLAST!
    }
    fclose(f);

    if (!last_ok) { printf("ERRO: TLAST nao veio!\n"); return 1; }
    printf("OK! Confira %s\n", output_path);
    return 0;
}
