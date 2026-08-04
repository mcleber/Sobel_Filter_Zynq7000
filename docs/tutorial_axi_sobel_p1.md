# Tutorial Completo: Filtro Sobel em Zynq (PS + PL) usando AXI DMA

**Fluxo do projeto:** a aplicação rodando no ARM (via Vitis) envia uma imagem em tons de cinza da memória DDR para o FPGA através de um **AXI DMA**, o FPGA aplica o **filtro Sobel** (IP criado em HLS) e devolve a imagem processada para a DDR, onde você pode salvá-la e visualizá-la no PC.

**Placa alvo:** qualquer Zynq-7000 (Zybo, PYNQ-Z2, ZedBoard, Arty Z7...). O fluxo é idêntico para Zynq UltraScale+ (muda só o nome do bloco PS e das portas HP).

**Ferramentas:** Vivado + Vitis HLS + Vitis (2020.2 ou mais recente — os nomes de menu podem variar levemente).

---

## Parte 0 — Entendendo o AXI de uma vez por todas

Antes de abrir qualquer ferramenta, vamos ao que realmente importa. AXI (Advanced eXtensible Interface) é o "idioma" que o ARM (PS) e a lógica do FPGA (PL) usam para conversar. Existem **três dialetos**, e 90% da confusão vem de não saber qual usar quando:

### 1. AXI4-Lite — "painel de controle"
- Transferências simples: **1 palavra de 32 bits por vez**, sem rajadas (bursts).
- Uso típico: **registradores de configuração e status**. Ligar/desligar um IP, escrever um parâmetro, ler uma flag de "pronto".
- No nosso projeto: é como o ARM configura o AXI DMA ("comece a transferir a partir do endereço X, tamanho Y").
- Analogia: o **interruptor de luz** — você não transfere energia por ele, só comanda.

### 2. AXI4 (Full / Memory-Mapped) — "caminhão de carga com endereço"
- Transferências em **rajadas de até 256 palavras** por endereço.
- Uso típico: acesso de alta largura de banda à **memória DDR**.
- No nosso projeto: é como o DMA lê/escreve a imagem na DDR, através das portas **HP (High Performance)** do Zynq.
- Analogia: o **caminhão de mudança** — leva muita coisa de uma vez para um endereço específico.

### 3. AXI4-Stream — "esteira rolante"
- **Não tem endereço!** Só um fluxo contínuo de dados: `TDATA` + `TVALID`/`TREADY` (handshake) + `TLAST` (marca o fim do pacote).
- Uso típico: dados que fluem pixel a pixel, amostra a amostra — vídeo, áudio, DSP.
- No nosso projeto: é como os pixels entram e saem do filtro Sobel.
- Analogia: a **esteira de sushi** — os pratos passam em sequência, você não pede "o prato do endereço 0x40".

### Sinais essenciais do handshake (vale para os três)
Toda transferência AXI acontece quando, **no mesmo ciclo de clock**:
```
VALID = 1  (quem envia diz: "tenho dado válido")
READY = 1  (quem recebe diz: "posso aceitar")
```
Se você entender só isso, já entendeu 70% do AXI. O resto são canais (endereço de leitura, endereço de escrita, dados, resposta) que as ferramentas geram automaticamente para você.

### O papel do AXI DMA
O ARM **não** envia pixels um a um para a PL (seria lentíssimo). Quem faz o trabalho pesado é o IP **AXI DMA**, que converte:

```
Memória DDR  ──AXI4 Full (MM)──►  AXI DMA  ──AXI4-Stream──►  Sobel IP
Memória DDR  ◄──AXI4 Full (MM)──  AXI DMA  ◄──AXI4-Stream──  Sobel IP
```

- Canal **MM2S** (Memory-Mapped to Stream): lê a imagem da DDR e transforma em stream.
- Canal **S2MM** (Stream to Memory-Mapped): pega o stream processado e escreve de volta na DDR.
- O ARM só configura o DMA via **AXI4-Lite** e espera terminar.

**Arquitetura completa do projeto:**

```
┌─────────────── PS (ARM) ───────────────┐
│  main.c no Vitis                       │
│  1. coloca imagem na DDR               │
│  2. configura DMA (AXI-Lite via GP0)   │
│  3. espera e lê resultado da DDR       │
└───────┬────────────────────▲───────────┘
   GP0 (AXI-Lite)       HP0 (AXI Full)
        │                    │
┌───────▼────────────────────┴───────────┐
│               AXI DMA                  │
│   MM2S ──────────────────► S2MM        │
└──────┬─────────────────────▲───────────┘
       │ AXI-Stream          │ AXI-Stream
┌──────▼─────────────────────┴───────────┐
│            Sobel IP (HLS)              │
└────────────────────────────────────────┘
```

---
## Parte 1 — O IP Sobel em Vitis HLS

Vamos criar o filtro em C++ e deixar o HLS gerar o RTL com interfaces AXI-Stream. É a forma mais didática de começar (depois você pode reescrever em Verilog/VHDL se quiser).

### 1.1 Criar o projeto
1. Abra o **Vitis HLS** → *Create Project*.
2. Nome: `sobel_hls`. Top function: `sobel_filter`.
3. Part: escolha o chip da sua placa (ex.: `xc7z020clg400-1` para Zybo Z7-20/PYNQ-Z2).
4. Clock: `10 ns` (100 MHz).

### 1.2 Código fonte — `sobel.cpp`

```cpp
#include "sobel.h"

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
```

### 1.3 Header — `sobel.h`

```cpp
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
```

### 1.4 Testbench — `sobel_tb.cpp` (simule ANTES de ir para o hardware!)

```cpp
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
```

### 1.5 Sintetizar e exportar
1. **Run C Simulation** → confira o `saida_sobel.pgm` (deve mostrar só o contorno do quadrado).
2. **Run C Synthesis** → verifique no relatório: II=1 no loop, interfaces `in_stream`/`out_stream` como *axis*.
3. **Export RTL** (Solution → Export RTL) → gera o IP em `.zip`/catálogo para o Vivado.

---
## Parte 2 — Block Design no Vivado

Aqui é onde a maioria "apanha", então vamos com calma e explicando **por que** cada conexão existe.

### 2.1 Criar o projeto
1. Vivado → *Create Project* → RTL Project, **sem** sources.
2. Escolha a **placa** (board) se ela estiver instalada (Zybo, PYNQ-Z2...) — isso já traz as configurações de DDR e clocks corretas. Se não, escolha o chip e configure o PS manualmente depois.
3. *IP Integrator → Create Block Design* → nome `design_1`.

### 2.2 Adicionar o IP do HLS ao catálogo
1. *Settings → IP → Repository → +* → aponte para a pasta do projeto HLS (ou onde extraiu o `.zip` exportado).
2. O IP `sobel_filter` aparece no catálogo.

### 2.3 Montar o diagrama (adicione com o "+")
Adicione, nesta ordem:

| IP | Função |
|---|---|
| **ZYNQ7 Processing System** | O ARM + controlador DDR |
| **AXI Direct Memory Access** | A ponte DDR ↔ Stream |
| **sobel_filter** (seu IP HLS) | O filtro |

### 2.4 Configurar o Zynq PS (duplo clique nele)
1. Se escolheu a *board*, clique em **Run Block Automation** primeiro (aplica preset de DDR/clocks).
2. **PS-PL Configuration → HP Slave AXI Interface → marque `S AXI HP0`**.
   - *Por quê?* O DMA precisa de uma porta de **alta largura de banda para acessar a DDR**. As portas GP são lentas (32 bits, para registradores); as HP são feitas exatamente para DMA (64 bits, acesso direto ao controlador de memória).
3. Confirme que **`M AXI GP0`** está habilitado (normalmente já está).
   - *Por quê?* É por ela que o ARM escreve nos **registradores de controle do DMA** (AXI-Lite).

### 2.5 Configurar o AXI DMA (duplo clique nele)
Esta configuração é a fonte de 80% dos problemas. Faça exatamente assim:

- ❌ **DESMARQUE "Enable Scatter Gather Engine"** — modo Scatter-Gather usa descritores em memória e é bem mais complexo. Para aprender, use o **Simple Mode** (registrador direto). Com SG ligado, as funções `XAxiDma_SimpleTransfer` do código C **não funcionam**.
- **Width of Buffer Length Register: 26** — este campo define o tamanho MÁXIMO de uma transferência: 2^26 = 64 MB. O padrão (14 bits = 16 KB) é menor que nossa imagem de 512×512 = 256 KB, e o DMA **truncaria a transferência silenciosamente**. Erro clássico!
- ✅ **Enable Read Channel (MM2S)** e ✅ **Enable Write Channel (S2MM)** — precisamos dos dois (ida e volta).
- **Memory Map Data Width: 32** (ou 64) e **Stream Data Width: 8** — o stream tem 8 bits porque nosso pixel tem 8 bits. O DMA faz a conversão de largura automaticamente.
- Allow Unaligned Transfers: pode deixar desmarcado (vamos alinhar os buffers no C).

### 2.6 Conectar tudo
Use o **Run Connection Automation** (ele resolve quase tudo), mas confira estas conexões — e entenda cada uma:

| De | Para | Protocolo | Função |
|---|---|---|---|
| `axi_dma_0/M_AXIS_MM2S` | `sobel_filter_0/in_stream` | AXI-Stream | pixels DDR → filtro |
| `sobel_filter_0/out_stream` | `axi_dma_0/S_AXIS_S2MM` | AXI-Stream | pixels filtro → DDR |
| `PS/M_AXI_GP0` | `axi_dma_0/S_AXI_LITE` | AXI-Lite | ARM configura o DMA |
| `axi_dma_0/M_AXI_MM2S` e `M_AXI_S2MM` | `PS/S_AXI_HP0` | AXI Full | DMA acessa a DDR |

As duas conexões AXI-Stream você faz **na mão** (arraste de porta a porta). As outras, o Connection Automation cria, inserindo automaticamente os blocos `AXI Interconnect`/`SmartConnect` e `Processor System Reset` necessários.

**Clock:** conecte `FCLK_CLK0` do PS a **todos** os clocks (`s_axi_lite_aclk`, `m_axi_mm2s_aclk`, `m_axi_s2mm_aclk` do DMA, `ap_clk` do Sobel). O Connection Automation costuma fazer isso; confira. Clock faltando = bloco morto = travamento sem mensagem de erro.

### 2.7 Endereços
Abra a aba **Address Editor**:
- `axi_dma_0` deve ter um endereço no espaço do GP0, tipicamente **`0x4040_0000`** (anote — o Vitis usa via `xparameters.h`).
- Os masters do DMA (`M_AXI_MM2S`/`M_AXI_S2MM`) devem **enxergar toda a DDR** (`0x0000_0000` até o tamanho da sua RAM). Se aparecer "excluded/unmapped", clique com o direito → *Assign*. DMA sem acesso à DDR = transferência que nunca completa.

### 2.8 Gerar o hardware
1. *Validate Design* (F6) — não pode haver erros (warnings de largura de stream 8→32 são normais, o DMA converte).
2. Na aba Sources: clique com o direito em `design_1` → **Create HDL Wrapper** (Let Vivado manage).
3. **Generate Bitstream** (vai rodar síntese + implementação; demora).
4. *File → Export → Export Hardware* → ✅ **Include bitstream** → gera o arquivo **`.xsa`**. Esse arquivo é a "foto" completa do hardware que o Vitis precisa.

---
## Parte 3 — Aplicação no Vitis (baremetal)

### 3.1 Criar a plataforma e a aplicação
1. Abra o **Vitis** → workspace novo.
2. *Create Platform Project* → selecione o **`.xsa`** exportado → OS: **standalone**, processador: `ps7_cortexa9_0`. Build.
3. *Create Application Project* → use a plataforma criada → template **Hello World** → nome `sobel_app`.

### 3.2 O código — substitua o `helloworld.c` por este `main.c`

```c
/**********************************************************************
 *  SOBEL EM ZYNQ — aplicacao baremetal
 *
 *  Fluxo:
 *   1. Imagem de teste e gerada na DDR (ou recebida do PC)
 *   2. AXI DMA envia a imagem para a PL (canal MM2S)
 *   3. Sobel IP processa em streaming
 *   4. AXI DMA devolve o resultado para a DDR (canal S2MM)
 *   5. Imagem processada e enviada pela UART em formato PGM
 *********************************************************************/

#include <stdio.h>
#include "xaxidma.h"      /* driver do AXI DMA                       */
#include "xparameters.h"  /* enderecos gerados a partir do .xsa      */
#include "xil_cache.h"    /* controle de cache — CRUCIAL, veja abaixo*/
#include "xil_printf.h"

/* Mesma resolucao compilada no IP HLS! */
#define WIDTH   512
#define HEIGHT  512
#define IMG_SIZE (WIDTH * HEIGHT)   /* bytes (1 byte/pixel) */

/* ------------------------------------------------------------------
 * Buffers na DDR.
 * "aligned(64)": alinhamento em linha de cache (32B no Cortex-A9;
 * 64 funciona para todos) — evita corrupcao nas bordas do buffer
 * quando fazemos flush/invalidate de cache.
 * ------------------------------------------------------------------ */
static u8 img_in [IMG_SIZE] __attribute__((aligned(64)));
static u8 img_out[IMG_SIZE] __attribute__((aligned(64)));

static XAxiDma dma;   /* instancia do driver */

/* ================================================================ */
int init_dma(void)
{
    /* Busca a configuracao do DMA pelo ID definido em xparameters.h.
     * Se seu bloco tiver outro nome, procure "XPAR_AXI_DMA" nesse
     * header para achar o ID/base address corretos.                */
    XAxiDma_Config *cfg = XAxiDma_LookupConfig(XPAR_AXIDMA_0_DEVICE_ID);
    if (!cfg) { xil_printf("ERRO: DMA nao encontrado\r\n"); return XST_FAILURE; }

    if (XAxiDma_CfgInitialize(&dma, cfg) != XST_SUCCESS) {
        xil_printf("ERRO: init do DMA falhou\r\n"); return XST_FAILURE;
    }

    /* Este exemplo exige modo SIMPLES (sem Scatter-Gather).
     * Se isto falhar, voce esqueceu de desmarcar o SG no Vivado.   */
    if (XAxiDma_HasSg(&dma)) {
        xil_printf("ERRO: DMA esta em modo Scatter-Gather\r\n");
        return XST_FAILURE;
    }

    /* Vamos usar "polling" (ficar perguntando se acabou), entao
     * desabilitamos as interrupcoes dos dois canais.               */
    XAxiDma_IntrDisable(&dma, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DEVICE_TO_DMA);
    XAxiDma_IntrDisable(&dma, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);
    return XST_SUCCESS;
}

/* ================================================================ */
int run_sobel(void)
{
    int status;

    /* --------------------------------------------------------------
     * CACHE: o topico que mais derruba iniciantes!
     *
     * O ARM enxerga a DDR ATRAVES do cache L1/L2. O DMA acessa a
     * DDR DIRETO (via porta HP), sem passar pelo cache. Logo:
     *
     *  - Antes de o DMA LER img_in:  FLUSH (empurra o conteudo do
     *    cache para a DDR, senao o DMA le lixo/dados velhos).
     *  - Antes de o ARM LER img_out: INVALIDATE (descarta a copia
     *    velha do cache, forcando leitura da DDR onde o DMA
     *    escreveu o resultado).
     *
     * Sintoma classico de esquecer isso: "a imagem volta igual" ou
     * "volta metade certa, metade lixo".
     * ------------------------------------------------------------ */
    Xil_DCacheFlushRange((UINTPTR)img_in, IMG_SIZE);
    Xil_DCacheInvalidateRange((UINTPTR)img_out, IMG_SIZE);

    /* --------------------------------------------------------------
     * ORDEM IMPORTA: arme o canal de RECEPCAO (S2MM) PRIMEIRO.
     * Se voce dispara o envio antes, o Sobel ja comeca a cuspir
     * pixels e o S2MM ainda nao esta pronto para receber.
     * ------------------------------------------------------------ */
    status = XAxiDma_SimpleTransfer(&dma, (UINTPTR)img_out, IMG_SIZE,
                                    XAXIDMA_DEVICE_TO_DMA);  /* PL -> DDR */
    if (status != XST_SUCCESS) { xil_printf("ERRO S2MM: %d\r\n", status); return status; }

    status = XAxiDma_SimpleTransfer(&dma, (UINTPTR)img_in, IMG_SIZE,
                                    XAXIDMA_DMA_TO_DEVICE);  /* DDR -> PL */
    if (status != XST_SUCCESS) { xil_printf("ERRO MM2S: %d\r\n", status); return status; }

    /* Espera (polling) os dois canais terminarem.
     * Se travar aqui para sempre -> ver secao Troubleshooting
     * (quase sempre e TLAST ausente ou Buffer Length Register curto) */
    while (XAxiDma_Busy(&dma, XAXIDMA_DMA_TO_DEVICE)) { /* MM2S */ }
    while (XAxiDma_Busy(&dma, XAXIDMA_DEVICE_TO_DMA)) { /* S2MM */ }

    /* Invalidate de novo por garantia (algumas linhas podem ter
     * sido trazidas ao cache especulativamente durante a espera). */
    Xil_DCacheInvalidateRange((UINTPTR)img_out, IMG_SIZE);
    return XST_SUCCESS;
}

/* ================================================================ */
void make_test_image(void)
{
    /* Quadrado branco no centro — mesmo padrao do testbench HLS */
    for (int r = 0; r < HEIGHT; r++)
        for (int c = 0; c < WIDTH; c++)
            img_in[r*WIDTH + c] =
                (r > 128 && r < 384 && c > 128 && c < 384) ? 255 : 0;
}

/* Envia a imagem como PGM pela UART (texto+binario).
 * No PC, capture a saida serial para um arquivo .pgm e abra. */
void send_image_uart(u8 *img)
{
    xil_printf("P5\n%d %d\n255\n", WIDTH, HEIGHT);
    for (int i = 0; i < IMG_SIZE; i++)
        outbyte(img[i]);
}

/* ================================================================ */
int main(void)
{
    xil_printf("\r\n=== Sobel Zynq: PS + PL via AXI DMA ===\r\n");

    if (init_dma() != XST_SUCCESS) return -1;

    make_test_image();

    xil_printf("Processando %dx%d na PL...\r\n", WIDTH, HEIGHT);
    if (run_sobel() != XST_SUCCESS) return -1;
    xil_printf("Concluido!\r\n");

    /* Confere alguns pixels: a borda do quadrado (linha 129+) deve
     * ter valores altos; o interior deve ser ~0. */
    xil_printf("pixel borda  (200,129) = %d (esperado ~255)\r\n",
               img_out[200*WIDTH + 129]);
    xil_printf("pixel dentro (256,256) = %d (esperado 0)\r\n",
               img_out[256*WIDTH + 256]);

    xil_printf("Enviando imagem pela UART em 5s...\r\n");
    for (volatile int i = 0; i < 200000000; i++);
    send_image_uart(img_out);

    return 0;
}
```

### 3.3 Rodar na placa
1. Conecte a placa (JTAG + UART), jumpers em modo **JTAG**.
2. Clique com o direito no `sobel_app` → **Run As → Launch Hardware (Single Application Debug)** — isso programa o bitstream *e* carrega o ELF.
3. Abra um terminal serial a **115200 baud**.

### 3.4 Visualizar a imagem no PC
A forma mais simples (sem drivers, sem Ethernet): capturar a UART para arquivo.

**Linux/macOS:**
```bash
# capture ANTES de resetar a placa; Ctrl+C depois que a transmissao acabar
(stty 115200 raw < /dev/ttyUSB0; cat /dev/ttyUSB0 > captura.bin) 
# recorte a partir do "P5" e salve como .pgm:
python3 - << 'EOF'
data = open('captura.bin','rb').read()
i = data.find(b'P5')
open('resultado.pgm','wb').write(data[i:i + 15 + 512*512 + 5])
EOF
```
Abra `resultado.pgm` no GIMP/IrfanView. Você deve ver **apenas o contorno do quadrado** — o Sobel funcionou de ponta a ponta!

> **Evolução natural:** depois que a UART funcionar, troque por transferência via `xsct` (`mrd`/dow de memória), cartão SD (xilffs) ou lwIP/Ethernet para imagens reais e maiores. A parte AXI/DMA não muda nada — só a forma de colocar/tirar a imagem da DDR.

---

## Parte 4 — Troubleshooting: os 7 erros clássicos

| Sintoma | Causa provável | Solução |
|---|---|---|
| Trava no `while (XAxiDma_Busy(...S2MM))` para sempre | **TLAST nunca chega** no S2MM | Confirme `out.last = 1` no último pixel do HLS; confirme que WIDTH/HEIGHT do C == do HLS |
| Transferência "completa" mas só parte da imagem volta | **Buffer Length Register** pequeno demais (padrão 14 bits = 16 KB) | No Vivado, DMA → Width of Buffer Length Register = 26 |
| Imagem volta igual à de entrada ou com lixo | **Cache** não gerenciado | `Xil_DCacheFlushRange` antes de enviar, `Xil_DCacheInvalidateRange` antes de ler |
| `XAxiDma_SimpleTransfer` retorna erro logo de cara | DMA em modo **Scatter-Gather** | Desmarque "Enable Scatter Gather Engine" no Vivado |
| Nada acontece, nem erro | **Clock ou reset** faltando em algum bloco, ou DMA sem endereço na DDR | Confira todos os `aclk` conectados ao FCLK_CLK0 e o Address Editor (masters do DMA mapeando a DDR inteira) |
| DMA dá erro/halted no meio (registrador DMASR mostra erro) | Porta **HP0 não habilitada** no PS, ou master do DMA "excluded" no Address Editor | Habilite S AXI HP0; Assign nos endereços |
| Funciona uma vez, trava na segunda rodada | DMA precisa de **reset entre transferências com erro**, ou buffers desalinhados | `XAxiDma_Reset(&dma)` + esperar `XAxiDma_ResetIsDone`; use `aligned(64)` nos buffers |

**Dica de depuração ouro:** leia o registrador de status do DMA quando travar:
```c
xil_printf("MM2S SR=0x%08x  S2MM SR=0x%08x\r\n",
    XAxiDma_ReadReg(dma.RegBase, XAXIDMA_TX_OFFSET + XAXIDMA_SR_OFFSET),
    XAxiDma_ReadReg(dma.RegBase, XAXIDMA_RX_OFFSET + XAXIDMA_SR_OFFSET));
```
Bit 0 = halted, bit 1 = idle, bits 4-6 = erros internos/slave/decode. Com isso você sabe *qual* canal e *qual* tipo de erro.

Outra ferramenta poderosa: adicione um **ILA (Integrated Logic Analyzer)** nas conexões AXI-Stream no Vivado (clique direito na conexão → Debug). Você literalmente vê o TVALID/TREADY/TLAST em tempo real e descobre onde o fluxo empacou.

---

## Recapitulando o mapa mental do AXI

- **AXI-Lite** = registradores de controle (ARM → DMA): "faça isso".
- **AXI Full (MM)** = dados em massa com endereço (DMA ↔ DDR pela porta HP).
- **AXI-Stream** = fluxo de pixels sem endereço (DMA ↔ seu IP), com **TLAST** fechando o pacote.
- **DMA** = tradutor entre os dois mundos, para o ARM não carregar pixel no braço.
- **Cache** = flush antes de enviar, invalidate antes de ler. Sempre.

## Próximos passos sugeridos
1. Parametrize WIDTH/HEIGHT via **AXI-Lite** no IP HLS (`s_axilite`) — você vai exercitar o terceiro tipo de AXI dentro do seu próprio IP.
2. Troque polling por **interrupções** do DMA (mais eficiente).
3. Processe imagens RGB (stream de 24/32 bits, `ap_axiu<32,...>`).
4. Compare o tempo PS-only vs PL usando o timer global (`XTime_GetTime`) — ver o speedup é a melhor parte!
