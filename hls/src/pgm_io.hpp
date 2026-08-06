#ifndef PGM_IO_HPP
#define PGM_IO_HPP

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cctype>

// PT: Le um arquivo PGM binario (formato P5) diretamente para o buffer 2D fornecido.
//     Retorna false se o arquivo nao existir, nao for P5, ou tiver dimensoes
//     diferentes de exp_width x exp_height (o design tem WIDTH/HEIGHT fixos).
// EN: Reads a binary PGM file (P5 format) directly into the provided 2D buffer.
//     Returns false if the file doesn't exist, isn't P5, or its dimensions
//     differ from exp_width x exp_height (the design has fixed WIDTH/HEIGHT).
inline bool read_pgm(const char *filename, unsigned char img[][512],
                      int exp_width, int exp_height) {
    FILE *fp = fopen(filename, "rb");
    if (!fp) {
        fprintf(stderr, "Erro: nao foi possivel abrir '%s'\n", filename);
        fprintf(stderr, "Error: could not open '%s'\n", filename);
        return false;
    }

    char magic[3] = {0};
    if (fscanf(fp, "%2s", magic) != 1 || strcmp(magic, "P5") != 0) {
        fprintf(stderr, "Erro: formato invalido, esperado P5 (binario)\n");
        fprintf(stderr, "Error: invalid format, expected P5 (binary)\n");
        fclose(fp);
        return false;
    }

    // PT: Pula espacos em branco e linhas de comentario ('#') no cabecalho PGM.
    //     IMPORTANTE: precisamos pular espacos/quebras de linha ANTES de
    //     verificar '#', pois apos o "P5" vem sempre um '\n' que nao e o
    //     inicio do comentario -- o '#' fica na linha seguinte.
    // EN: Skip whitespace and comment lines ('#') in the PGM header.
    //     IMPORTANT: we must skip whitespace/newlines BEFORE checking for
    //     '#', since right after "P5" there's always a '\n' that is not the
    //     start of the comment -- the '#' is on the following line.
    int c;
    while (true) {
        c = fgetc(fp);
        if (c == '#') {
            while ((c = fgetc(fp)) != '\n' && c != EOF); // PT: descarta a linha | EN: discard the line
        } else if (!isspace(c)) {
            ungetc(c, fp);
            break;
        }
    }

    int width, height, maxval;
    fscanf(fp, "%d %d %d", &width, &height, &maxval);
    fgetc(fp); // PT: consome o \n apos o cabecalho | EN: consume newline after header

    // PT: O design tem dimensoes fixas (WIDTH x HEIGHT em sobel.hpp), entao a
    //     imagem de entrada precisa bater exatamente com essas dimensoes.
    // EN: The design has fixed dimensions (WIDTH x HEIGHT in sobel.hpp), so the
    //     input image must exactly match those dimensions.
    if (width != exp_width || height != exp_height) {
        fprintf(stderr, "Erro: imagem %dx%d, mas o design espera %dx%d\n",
                width, height, exp_width, exp_height);
        fprintf(stderr, "Error: image is %dx%d, but the design expects %dx%d\n",
                width, height, exp_width, exp_height);
        fprintf(stderr, "Dica/Tip: redimensione a imagem no GIMP antes de exportar / "
                        "resize the image in GIMP before exporting.\n");
        fclose(fp);
        return false;
    }

    for (int r = 0; r < height; r++)
        for (int col = 0; col < width; col++)
            img[r][col] = (unsigned char)fgetc(fp);

    fclose(fp);
    return true;
}

#endif // PGM_IO_HPP
