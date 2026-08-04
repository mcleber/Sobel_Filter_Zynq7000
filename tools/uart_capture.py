#!/usr/bin/env python3
"""
uart_capture.py — Captura automatica da imagem PGM pela serial
================================================================
Substitui aquele ritual manual do Tutorial 1 (stty + cat + recorte).
O script fica ouvindo a UART, detecta o cabecalho "P5", le exatamente
os bytes da imagem, salva e ja abre na tela. Aperte reset na placa
com o script rodando e pronto.

Uso:
  python uart_capture.py --port /dev/ttyUSB0            # Linux
  python uart_capture.py --port COM5                    # Windows
  python uart_capture.py --port COM5 --loop             # captura continua

Requer: pip install pyserial pillow
"""
import argparse, re, sys
import serial
from PIL import Image

def read_pgm_from_serial(ser):
    """Consome a serial ate achar 'P5', entao le header + payload."""
    # 1) procura a assinatura P5 no fluxo (ignora logs xil_printf antes)
    window = b""
    print("Aguardando 'P5' na serial... (de reset na placa)")
    while True:
        b = ser.read(1)
        if not b:
            continue
        window = (window + b)[-2:]
        if window == b"P5":
            break

    # 2) le o resto do header: "\n<W> <H>\n255\n"
    header = b""
    newlines = 0
    while newlines < 3:                      # tres \n fecham o header
        c = ser.read(1)
        header += c
        if c == b"\n":
            newlines += 1
    m = re.match(rb"\s*(\d+)\s+(\d+)\s+255", header)
    if not m:
        sys.exit(f"Header PGM invalido: {header!r}")
    w, h = int(m.group(1)), int(m.group(2))
    print(f"Header ok: {w}x{h}. Recebendo {w*h} bytes...")

    # 3) le o payload binario exato (read() do pyserial pode vir
    #    em pedacos — acumula ate completar)
    need, chunks = w * h, []
    while need > 0:
        chunk = ser.read(min(need, 4096))
        if chunk:
            chunks.append(chunk)
            need -= len(chunk)
            print(f"\r  faltam {need:7d} bytes", end="")
    print()
    return w, h, b"".join(chunks)

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", required=True)
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--out", default="resultado.pgm")
    ap.add_argument("--loop", action="store_true",
                    help="continua capturando (uma imagem por reset)")
    a = ap.parse_args()

    with serial.Serial(a.port, a.baud, timeout=1) as ser:
        n = 0
        while True:
            w, h, data = read_pgm_from_serial(ser)
            name = a.out if not a.loop else f"resultado_{n:03d}.pgm"
            with open(name, "wb") as f:
                f.write(f"P5\n{w} {h}\n255\n".encode() + data)
            print(f"Salvo: {name}")
            Image.open(name).show()          # abre no visualizador padrao
            if not a.loop:
                break
            n += 1
