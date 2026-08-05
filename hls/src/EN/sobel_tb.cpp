#include "sobel.hpp"
#include <cstdio>

int main() {
    hls::stream<axis_t> in_s, out_s;

    // Synthetic image: a white square in the center
    // (well-defined edges -> easy to check the Sobel output)
    static unsigned char img[HEIGHT][WIDTH];
    for (int r = 0; r < HEIGHT; r++)
        for (int c = 0; c < WIDTH; c++)
            img[r][c] = (r > 128 && r < 384 && c > 128 && c < 384) ? 255 : 0;

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

    // Save the output as PGM (open with GIMP/IrfanView/any viewer)
    FILE *f = fopen("saida_sobel.pgm", "wb");
    fprintf(f, "P5\n%d %d\n255\n", WIDTH, HEIGHT);
    int last_ok = 0;
    for (int i = 0; i < WIDTH*HEIGHT; i++) {
        axis_t p = out_s.read();
        fputc(p.data, f);
        if (p.last) last_ok = 1;  // checking TLAST!
    }
    fclose(f);

    if (!last_ok) { printf("ERROR: TLAST never arrived!\n"); return 1; }
    printf("OK! Check saida_sobel.pgm\n");
    return 0;
}
