#!/usr/bin/env python3
"""
sobel_golden.py — Modelo dourado + gerador de vetores de teste
================================================================
Papel na metodologia: este script e a REFERENCIA. O HLS (C sim),
o Verilog (testbench) e a placa real devem produzir EXATAMENTE os
mesmos bytes que ele. Se diferir, o bug esta no hardware.

IMPORTANTE: reproduz a MESMA aritmetica inteira do sobel.cpp
(|gx|+|gy| com saturacao, bordas zeradas em row<2 || col<2) —
nada de scipy.ndimage.sobel, que usa outra normalizacao e
quebraria a comparacao bit a bit!

Uso:
  python sobel_golden.py --gen quadrado        # imagem de teste sintetica
  python sobel_golden.py --gen foto.png        # ou uma foto real qualquer
  python sobel_golden.py --header              # exporta imagem como .h p/ Vitis

Saidas em test_vectors/:
  entrada.pgm  entrada.bin   -> alimentam testbench HLS/Verilog
  esperado.pgm esperado.bin  -> saida que o hardware DEVE produzir
  imagem_teste.h             -> (opcional) p/ embutir no ELF do Vitis
"""
import argparse, os
import numpy as np
from PIL import Image

W, H = 512, 512   # deve casar com WIDTH/HEIGHT do sobel.h!

def make_square():
    """Mesma imagem sintetica do make_test_image() do Vitis."""
    img = np.zeros((H, W), dtype=np.uint8)
    img[129:384, 129:384] = 255          # r>128 && r<384 (limites do C)
    return img

def sobel_golden(img):
    """Copia fiel, linha a linha, da aritmetica do sobel.cpp."""
    img = img.astype(np.int32)
    out = np.zeros_like(img)
    # janela ancorada como no HLS: pixel de saida (r,c) usa
    # linhas r-2..r e colunas c-2..c (line buffers atrasam 2)
    gx = (-img[:-2, :-2] + img[:-2, 2:]
          - 2*img[1:-1, :-2] + 2*img[1:-1, 2:]
          - img[2:, :-2] + img[2:, 2:])
    gy = (-img[:-2, :-2] - 2*img[:-2, 1:-1] - img[:-2, 2:]
          + img[2:, :-2] + 2*img[2:, 1:-1] + img[2:, 2:])
    mag = np.abs(gx) + np.abs(gy)
    out[2:, 2:] = np.clip(mag, 0, 255)   # bordas (row<2||col<2) ficam 0
    return out.astype(np.uint8)

def load_any(path):
    """Carrega qualquer imagem, converte p/ cinza e redimensiona."""
    return np.array(Image.open(path).convert("L").resize((W, H)),
                    dtype=np.uint8)

def save_all(name, arr, outdir):
    Image.fromarray(arr).save(f"{outdir}/{name}.pgm")
    arr.tofile(f"{outdir}/{name}.bin")      # bytes crus p/ testbench

def export_c_header(img, outdir):
    """Gera imagem_teste.h — substitui make_test_image() no Vitis."""
    with open(f"{outdir}/imagem_teste.h", "w") as f:
        f.write(f"/* gerado por sobel_golden.py — {W}x{H} */\n")
        f.write(f"static const unsigned char imagem_teste[{W*H}] = {{\n")
        flat = img.flatten()
        for i in range(0, len(flat), 16):
            f.write("  " + ",".join(str(b) for b in flat[i:i+16]) + ",\n")
        f.write("};\n")

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--gen", default="quadrado",
                    help="'quadrado' ou caminho de uma imagem")
    ap.add_argument("--header", action="store_true",
                    help="tambem exporta imagem_teste.h para o Vitis")
    a = ap.parse_args()

    os.makedirs("test_vectors", exist_ok=True)
    img = make_square() if a.gen == "quadrado" else load_any(a.gen)
    ref = sobel_golden(img)

    save_all("entrada", img, "test_vectors")
    save_all("esperado", ref, "test_vectors")
    if a.header:
        export_c_header(img, "test_vectors")

    print(f"OK: vetores {W}x{H} em test_vectors/")
    print("Fluxo: entrada.bin -> [seu hardware] -> comparar com esperado.bin")
