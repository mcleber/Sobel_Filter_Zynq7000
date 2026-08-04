# Tutorial 3: Automação em Python para o Projeto Sobel

Você acertou em cheio na leitura da indústria: **C no embarcado, HDL no hardware, Python amarrando tudo**. Este tutorial monta sua "bancada virtual" — três ferramentas testadas e prontas, integradas ao Tutorial 1 e aos adendos, seguindo a metodologia profissional de verificação:

```
   Python (modelo dourado)  ──gera──►  vetores de teste
            │                              │
            │                              ▼
            │                    HLS C-sim / placa real
            │                              │
            ▼                              ▼
   saida ESPERADA  ──── compare.py ────  saida REAL
                            │
                     PASS / FAIL + diagnóstico
```

A ideia central: **o hardware nunca é julgado no olho**. Ele é comparado, byte a byte, contra um modelo de referência em Python. É assim que a indústria verifica de filtros de imagem a modems de satélite.

---

## Passo 0 — Preparar o ambiente (5 min)

```bash
cd sobel-zynq/
mkdir -p tools
# copie para tools/: sobel_golden.py, uart_capture.py, compare.py

# ambiente virtual (boa prática; no Windows: py -m venv .venv)
python3 -m venv .venv
source .venv/bin/activate        # Windows: .venv\Scripts\activate
pip install numpy pillow matplotlib pyserial
```

A estrutura de diretórios que definimos ganha a pasta nova:

```
sobel-zynq/
├── tools/            # <— as ferramentas Python (este tutorial)
│   ├── sobel_golden.py
│   ├── uart_capture.py
│   ├── compare.py
│   └── test_vectors/     # gerado pelo golden (não versionar no git)
├── hls/  hw/  sw/  docs/  images/   # (Tutorial 1)
```

---

## Ferramenta 1 — `sobel_golden.py`: o modelo dourado

### O que faz
Reimplementa em NumPy **exatamente a mesma aritmética inteira** do `sobel.cpp` (|Gx|+|Gy|, saturação em 255, bordas zeradas). Gera o par entrada/saída-esperada em dois formatos: `.pgm` (para seus olhos) e `.bin` (bytes crus, para testbenches).

> Detalhe que separa amador de profissional: **não** usamos `scipy.ndimage.sobel` — ele normaliza diferente e a comparação bit a bit quebraria. O modelo dourado deve espelhar a *sua* especificação, não "um Sobel qualquer".

### Passo a passo
```bash
cd tools/

# 1. Gerar vetores com a imagem sintética (o mesmo quadrado do Tutorial 1)
python sobel_golden.py --gen quadrado

# 2. Conferir visualmente (abra os dois .pgm)
#    entrada.pgm = quadrado branco | esperado.pgm = só o contorno

# 3. Com uma foto real (qualquer formato; ele converte p/ cinza 512x512)
python sobel_golden.py --gen ../images/minha_foto.jpg

# 4. Exportar a imagem como header C para embutir no ELF do Vitis
python sobel_golden.py --gen ../images/minha_foto.jpg --header
```

### Integração com o Tutorial 1 (duas pontas)

**Ponta HLS** — faça o testbench ler os vetores em vez de gerar internamente. No `sobel_tb.cpp`, troque a geração da imagem por:

```cpp
FILE *fi = fopen("entrada.bin", "rb");
fread(img, 1, WIDTH*HEIGHT, fi);  fclose(fi);
// ... roda o filtro ...
// e no final, em vez de so salvar: compara com esperado.bin
FILE *fe = fopen("esperado.bin", "rb");
// fread + memcmp -> return 0 so se identico (C-sim vira teste automatico!)
```
(No Vitis HLS, adicione os `.bin` como *testbench files* para a C-sim enxergá-los.)

**Ponta Vitis** — o `--header` gera `imagem_teste.h`. No `main.c`:
```c
#include "imagem_teste.h"
/* no lugar de make_test_image(): */
memcpy(img_in, imagem_teste, IMG_SIZE);
```
Pronto: fotos reais na placa **sem SD card, sem Ethernet** — a imagem viaja dentro do ELF.

---

## Ferramenta 2 — `uart_capture.py`: recepção automática

### O que faz
Substitui o ritual manual de `stty + cat + recorte em Python` do Tutorial 1. Fica ouvindo a serial, ignora os logs do `xil_printf`, detecta o header `P5`, lê a quantidade exata de bytes, salva e **já abre a imagem na tela**.

### Passo a passo
```bash
# 1. Descubra a porta:
#    Linux: ls /dev/ttyUSB*    | Windows: Gerenciador de Dispositivos (COMx)

# 2. Rode ANTES de resetar a placa:
python uart_capture.py --port /dev/ttyUSB0        # ou COM5

# 3. Aperte o reset da placa. O script mostra o progresso e abre a imagem.

# 4. Modo contínuo (uma captura por reset, arquivos numerados):
python uart_capture.py --port COM5 --loop
```

> Dica: feche o terminal serial (PuTTY/minicom) antes — só um programa pode abrir a porta por vez. Esse é o "bug" nº 1 desta ferramenta.

---

## Ferramenta 3 — `compare.py`: o veredicto

### O que faz
Compara a imagem que voltou da placa com a do modelo dourado e responde a única pergunta que importa: **o hardware está certo?** Três níveis:

- **PASS** — idêntico bit a bit (é o esperado: aritmética inteira não tem "quase").
- **QUASE** (PSNR alto) — parecido mas não idêntico → bug sutil (borda, saturação).
- **FAIL** — muito diferente → bug grosseiro (cache, TLAST, stride).

E o pulo do gato: ele gera o `diff.png` (esperado | recebido | diferença) e **lê a geometria do erro** para sugerir a causa — porque no Zynq, *onde* a imagem está errada denuncia *o que* está errado:

| Geometria do erro | Diagnóstico provável |
|---|---|
| Só a metade final errada | Cache (faltou Invalidate) ou transferência truncada |
| Todas as linhas erradas | Deslocamento/stride ou ordem de bytes |
| Só as 2 primeiras linhas | Tratamento de borda diverge do golden |

### Passo a passo
```bash
python compare.py test_vectors/esperado.pgm resultado.pgm
echo $?    # 0 = PASS, 1 = falha  (Windows: echo %ERRORLEVEL%)
```

O código de saída permite usar em scripts — que é o gancho para o próximo nível.

---

## O fluxo completo, ponta a ponta (o "dia perfeito")

```bash
# 1. Gera vetores + header a partir de uma foto
python sobel_golden.py --gen ../images/gato.jpg --header

# 2. HLS: C-sim le entrada.bin e compara com esperado.bin -> PASS na simulacao

# 3. Vitis: main.c usa imagem_teste.h -> compila -> roda na placa

# 4. Captura o retorno
python uart_capture.py --port COM5

# 5. Veredicto
python compare.py test_vectors/esperado.pgm resultado.pgm
#    PASS: identico bit a bit ao modelo dourado. \o/
```

Quando esse `PASS` aparecer, você provou que **PC, simulação e silício concordam byte a byte**. Essa sensação não tem preço — e esse fluxo é, em miniatura, o que times de verificação fazem profissionalmente.

### Usando com os adendos
- **Adendo 1/B.1 (vídeo):** o golden continua sendo o juiz — a imagem no monitor é para humanos, o `compare.py` é para a verdade. Rode as duas coisas.
- **B.3 (RGB):** evolua o golden: adicione a conversão de luminância `(77R+150G+29B)>>8` em NumPy antes do Sobel e gere vetores de 32 bits. Exercício de ~10 linhas.
- **B.4 (benchmark):** faça o `main.c` imprimir `CSV: ps_us, pl_us` e um script com matplotlib plota speedup × tamanho de imagem. É o gráfico que impressiona em relatório.

---

## Para onde a automação cresce (o mapa da indústria)

1. **cocotb** — testbenches em *Python* para o seu Verilog: o mesmo `sobel_golden` vira o verificador do RTL, com o simulador (GHDL/Verilator/XSIM) controlado por Python. É o padrão moderno de verificação e o próximo passo natural destas ferramentas — seus arquivos `video_driver.v`/`dvi_encoder.v` são ótimas cobaias (ex.: verificar que hsync tem exatamente 136 ciclos).
2. **Tcl scriptado** — Vivado é 100% automatizável: um `build.tcl` que recria projeto + block design + bitstream do zero (`vivado -mode batch -source build.tcl`). Combinado com o `design_1.tcl` exportado (Tutorial de diretórios), seu hardware inteiro vira "código que compila". Python orquestra chamando esses scripts.
3. **XSCT scriptado** — o console do Vitis também é Tcl: programar FPGA + carregar ELF + rodar sem abrir a GUI. Ponto de partida de uma esteira de "CI para hardware".
4. **PYNQ** — o final do arco: Python rodando *dentro* do Zynq (Linux), controlando seu overlay Sobel com `dma.sendchannel.transfer(buffer)` num Jupyter Notebook. O mesmo hardware do Tutorial 1, driver em 5 linhas de Python.

Sugestão de ordem: domine as 3 ferramentas deste tutorial → cocotb no seu RTL HDMI → build.tcl → PYNQ.
