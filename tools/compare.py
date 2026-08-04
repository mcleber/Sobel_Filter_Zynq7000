#!/usr/bin/env python3
"""
compare.py — Verificacao automatica: hardware vs modelo dourado
================================================================
Fecha o ciclo da metodologia: compara a imagem que VOLTOU da placa
(ou da C-sim do HLS) com a saida do modelo dourado, byte a byte.

Veredicto em 3 niveis:
  PASS           -> identica bit a bit (o esperado p/ aritmetica inteira!)
  QUASE (PSNR)   -> parecida mas nao identica: provavel bug sutil
                    (borda, saturacao, ordem de linha)
  FAIL           -> muito diferente: bug grosseiro (cache? TLAST? stride?)

Alem do veredicto, gera diff.png marcando ONDE diferem — a posicao
do erro denuncia a causa (ver dicas impressas no final).

Uso:
  python compare.py test_vectors/esperado.pgm resultado.pgm
Requer: pip install numpy pillow matplotlib
"""
import sys
import numpy as np
from PIL import Image

def load(p):
    return np.array(Image.open(p).convert("L"), dtype=np.uint8)

def main(ref_path, dut_path):
    ref, dut = load(ref_path), load(dut_path)
    if ref.shape != dut.shape:
        sys.exit(f"FAIL: tamanhos diferem {ref.shape} vs {dut.shape} "
                 "(transferencia truncada? Buffer Length Register?)")

    diff = ref.astype(np.int16) - dut.astype(np.int16)
    nbad = int(np.count_nonzero(diff))

    if nbad == 0:
        print("PASS: identico bit a bit ao modelo dourado. \\o/")
        return 0

    mse = float(np.mean(diff.astype(np.float64) ** 2))
    psnr = 10 * np.log10(255**2 / mse)
    pct = 100 * nbad / diff.size
    print(f"{'QUASE' if psnr > 30 else 'FAIL'}: "
          f"{nbad} pixels diferem ({pct:.2f}%), PSNR={psnr:.1f} dB")

    # Mapa de calor dos erros + dicas de diagnostico pela GEOMETRIA
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    fig, ax = plt.subplots(1, 3, figsize=(14, 5))
    for a, im, t in zip(ax, [ref, dut, np.abs(diff)],
                        ["esperado (golden)", "recebido (hardware)", "|diferenca|"]):
        a.imshow(im, cmap="gray"); a.set_title(t); a.axis("off")
    fig.savefig("diff.png", dpi=110, bbox_inches="tight")
    print("Mapa salvo em diff.png. Leia a geometria do erro:")

    rows_bad = np.unique(np.nonzero(diff)[0])
    if rows_bad.size and rows_bad.min() > ref.shape[0] // 2:
        print(" - erro so na METADE FINAL -> cheira a cache "
              "(faltou Invalidate) ou transferencia parcial")
    if np.all(np.any(diff != 0, axis=1)):
        print(" - TODAS as linhas erradas -> deslocamento/stride "
              "ou ordem de bytes")
    if rows_bad.size and rows_bad.max() < 3:
        print(" - so as primeiras linhas -> tratamento de borda "
              "diverge do golden")
    return 1

if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    sys.exit(main(sys.argv[1], sys.argv[2]))
