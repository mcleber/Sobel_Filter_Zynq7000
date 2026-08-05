# Adendo ao Tutorial Sobel: Exibindo Antes/Depois via HDMI HDMI output using AXI VDMA

**Objetivo:** substituir o gerador de colorbar por um **framebuffer na DDR**, exibindo no monitor HDMI a imagem original (metade esquerda) e a filtrada pelo Sobel (metade direita), lado a lado, em 1024×600.

**O que você vai aprender de novo:** o IP **AXI VDMA** (Video DMA) — o irmão do AXI DMA especializado em vídeo — e como integrar **RTL Verilog seu** (o transmissor HDMI) dentro de um block design.

---

## A.0 — Arquitetura: o que muda em relação ao Tutorial 1

O caminho do Sobel (DMA + IP HLS) fica **intacto**. Adicionamos um segundo caminho, só de leitura, que varre a DDR continuamente e joga os pixels no monitor:

```
        ┌──────────────── DDR ────────────────┐
        │ img_in   img_out   framebuffer      │
        │ (512²)   (512²)    1024x600 RGB     │
        └───▲─────────▲──────────┬────────────┘
            │         │          │ leitura continua, 60x/seg
   Tutorial 1 (DMA + Sobel)      │
   PS compoe o framebuffer:      │
   esquerda=img_in,              ▼
   direita=img_out          ┌─────────┐   AXI-Stream   ┌─────────────────┐
                            │ AXI VDMA│───────────────►│ AXI4-Stream to  │
                            │ (read)  │                │ Video Out       │
                            └─────────┘                └───────┬─────────┘
                                              timing ▲         │ RGB+hs/vs/de
                                            ┌────────┴──┐      ▼
                                            │   VTC     │ ┌──────────────────┐
                                            │ (timing   │ │ dvi_transmitter_ │──► TMDS
                                            │ generator)│ │ top (SEU RTL!)   │    (monitor)
                                            └───────────┘ └──────────────────┘
```

### Destino de cada arquivo seu

| Arquivo | Destino | Por quê |
|---|---|---|
| `dvi_transmitter_top.v` | ✅ **Mantido** (vai para dentro do block design) | Só precisa de RGB+syncs, não importa a origem |
| `dvi_encoder.v` | ✅ Mantido (usado pelo transmitter) | idem |
| `serializer_10_to_1.v` | ✅ Mantido | idem |
| `asyn_rst_syn.v` | ✅ Mantido | idem |
| `video_driver.v` | ❌ Substituído pelo **VTC** (Video Timing Controller) | O VTC gera os mesmos hs/vs/de, mas sincronizado com o fluxo do VDMA — e você reusa os SEUS números de timing nele |
| `video_display.v` | ❌ Substituído pelo **VDMA + framebuffer** | Em vez de "cor calculada pela posição", a cor vem da memória |
| `hdmi_colorbar_top.v` | ❌ Substituído pelo próprio block design | O diagrama vira o novo top |

> Não jogue `video_driver.v` fora! Os **números de timing dele são a receita** que você vai digitar no VTC (H: 136/160/1024/24, V: 3/23/600/1). Isso garante que o monitor continua reconhecendo o mesmo modo de vídeo que já funcionava.

---

## A.1 — Conceito novo: AXI VDMA vs AXI DMA

Você já domina o AXI DMA: transferência **única**, dispara e espera o TLAST. Vídeo tem outra natureza — o monitor exige o frame inteiro, **60 vezes por segundo, para sempre**, sem o processador tocar em nada. Para isso existe o **AXI VDMA**:

| | AXI DMA (Tutorial 1) | AXI VDMA (este adendo) |
|---|---|---|
| Transferência | uma por comando | **contínua e circular** (re-varre o frame sozinho) |
| Formato | 1D (bloco de bytes) | **2D** (linhas × colunas, com *stride*) |
| Fim do pacote | TLAST no último byte | TLAST no fim de **cada linha** + TUSER no início do frame |
| Uso típico | dados sob demanda | framebuffer de vídeo, câmeras |

Dois termos novos importantes:

- **Stride**: quantos **bytes** pular na memória para ir da linha N para a linha N+1. Permite exibir uma "janela" dentro de uma imagem maior. No nosso caso: `1024 pixels × 4 bytes = 4096`.
- **Circular / free-running**: o VDMA chega na última linha e volta para a primeira sozinho. O ARM configura **uma vez** e nunca mais se envolve — é o hardware alimentando o monitor.

O VDMA também tem canais MM2S (leitura, o que usaremos) e S2MM (escrita, para câmeras — não usaremos). Assim como o DMA, ele é configurado via **AXI-Lite** e acessa a DDR via **porta HP**. Nada de novo no AXI em si — é o mesmo idioma, com um sotaque de vídeo.

### Formato do pixel no framebuffer

Usaremos **32 bits por pixel** (`0x00RRGGBB`) na DDR, mesmo o dado sendo cinza. Motivo: 32 bits alinha perfeitamente com o barramento (endereços múltiplos de 4, sem repacking), o que simplifica VDMA e código C. Um **AXI4-Stream Subset Converter** corta os 8 bits não usados antes do vídeo (32 → 24 bits). Custo: 2,4 MB de DDR para o frame — irrisório perto dos 512 MB da placa.

---
## A.2 — Preparando o seu RTL para entrar no Block Design

O Vivado permite arrastar um módulo Verilog seu direto para o diagrama (**Module Reference**) — sem precisar empacotar como IP. É o jeito mais rápido de misturar RTL próprio com IPs Xilinx.

1. Adicione ao projeto (*Add Sources → Design Sources*): `dvi_transmitter_top.v`, `dvi_encoder.v`, `serializer_10_to_1.v`, `asyn_rst_syn.v`.
   **Não adicione** `hdmi_colorbar_top.v`, `video_driver.v` e `video_display.v`.
2. No block design, clique com o direito no fundo → **Add Module...** → escolha `dvi_transmitter_top`.
3. Ele aparece como um bloco com as portas `pclk`, `pclk_x5`, `reset_n`, `video_din[23:0]`, `video_hsync`, `video_vsync`, `video_de`, `tmds_*`.
4. Selecione as portas `tmds_clk_p/n` e `tmds_data_p/n` → clique direito → **Make External**. Elas viram as saídas físicas do design (os pinos você amarra no XDC, seção A.5).

---

## A.3 — Novos IPs no Block Design

Ao diagrama do Tutorial 1 (PS + AXI DMA + Sobel), adicione:

| IP | Função |
|---|---|
| **AXI Video Direct Memory Access** (VDMA) | Lê o framebuffer da DDR em loop |
| **Video Timing Controller** (VTC) | Gera a temporização 1024×600 (substitui seu `video_driver`) |
| **AXI4-Stream to Video Out** | Casa o stream do VDMA com o timing do VTC e entrega RGB paralelo + hs/vs/de |
| **AXI4-Stream Subset Converter** | Corta 32 → 24 bits |
| **Clocking Wizard** | Gera pixel clock (~51,2 MHz) e 5× (~256 MHz) |
| **Processor System Reset** (mais um) | Resets sincronizados ao domínio do pixel clock |

### A.3.1 Clocking Wizard
- Entrada: `FCLK_CLK0` (100 MHz do PS).
- `clk_out1` = **51,2 MHz** (pixel) e `clk_out2` = **256 MHz** (5×).
- O wizard talvez entregue algo como 51,28 MHz — **aceite**. O padrão CVT tolera pequenos desvios e o monitor sincroniza normalmente (o que NÃO pode é a razão 1:5 entre os dois clocks estar errada — e o wizard garante isso derivando ambos do mesmo VCO).
- Conecte `locked` do wizard ao `ext_reset_in`... não! Ao contrário: `locked` vai ao novo **Processor System Reset** (`dcm_locked`), e o reset sincronizado resultante alimenta os blocos de vídeo. Isso reproduz a lógica `hdmi_reset_n = rst_n & clk_locked` do seu top antigo, só que do jeito "block design".

### A.3.2 Zynq PS
- Habilite uma **segunda porta HP** (`S AXI HP1`) para o VDMA — ou compartilhe a HP0 via SmartConnect. Porta separada é melhor: vídeo consome banda constante (1024×600×60×4 B ≈ 147 MB/s) e você não quer o Sobel competindo no mesmo funil.

### A.3.3 AXI VDMA (duplo clique)
- ❌ Desabilite o **Write Channel (S2MM)** — só vamos ler.
- ✅ Read Channel: **Memory Map Data Width = 32**, **Stream Data Width = 32**, Read Burst Size = 32.
- **Frame Buffers = 1** (um framebuffer só; com 2-3 você faria double-buffering — evolução futura).
- Advanced → **GenLock Mode: Free Running** (ninguém sincroniza ninguém; o Stream-to-Video-Out absorve a diferença com FIFO).
- Line Buffer Depth: 4096.

### A.3.4 Video Timing Controller (duplo clique)
- ❌ Desmarque **Enable Detection** (detecção é para entrada de vídeo; só geramos).
- ✅ Enable Generation.
- Default/Constant... escolha **Constant** e desmarque "AXI4-Lite" se não quiser configurar por software (mais simples: timing fixo em hardware).
- Aba *Default/Constant Timing*: aqui entram **os números do seu `video_driver.v`**:

| Campo do VTC | Valor | De onde veio |
|---|---|---|
| Active Video Columns | 1024 | `H_ACTIVE` |
| Active Video Rows | 600 | `V_ACTIVE` |
| Horizontal Front Porch | 24 | `H_FRONT` |
| Horizontal Sync Width | 136 | `H_SYNC` |
| Horizontal Back Porch | 160 | `H_BACK` |
| Vertical Front Porch | 1 | `V_FRONT` |
| Vertical Sync Width | 3 | `V_SYNC` |
| Vertical Back Porch | 23 | `V_BACK` |
| Sync polarities | positivas | seu driver usa sync ativo alto |

(Total H = 1344 e V = 627 — o VTC calcula e deve bater com o seu Verilog.)

### A.3.5 AXI4-Stream to Video Out (duplo clique)
- **Timing Mode: Master** — ele passa a *comandar* o VTC (via `vtg_ce`), pausando o gerador de timing se o FIFO esvaziar. É o modo mais robusto contra "tearing".
- Clock Mode: Independent. FIFO Depth: 4096.
- Pixels per clock: 1.

### A.3.6 Subset Converter
- TDATA in: 4 bytes, TDATA out: 3 bytes. TDATA Remap: `tdata[23:0]` (mantém os 24 bits baixos).

---

## A.4 — Conexões (a parte que exige atenção)

**Caminho de dados (stream):**
```
axi_vdma_0/M_AXIS_MM2S → subset_conv/S_AXIS → subset_conv/M_AXIS → v_axi4s_vid_out_0/video_in
```

**Timing:**
```
vtc_0/vtiming_out → v_axi4s_vid_out_0/vtiming_in
v_axi4s_vid_out_0/vtg_ce → vtc_0/gen_clken       (o "freio de mão" do timing)
```

**Vídeo paralelo → seu RTL:** expanda a interface `vid_io_out` do Stream-to-Video-Out e conecte pino a pino:
```
vid_data[23:0] → dvi_transmitter_top/video_din
vid_hsync      → video_hsync
vid_vsync      → video_vsync
vid_active_video → video_de
```

**Clocks — 3 domínios, não misture!**
| Clock | Quem recebe |
|---|---|
| `FCLK_CLK0` (100 MHz) | AXI-Lite do VDMA, M_AXI_MM2S do VDMA (lado memória), DMA/Sobel do Tutorial 1 |
| `clk_out1` (~51,2 MHz, pixel) | `m_axis_mm2s_aclk` do VDMA*, subset converter, `aclk` do vid_out, `clk` do VTC, `pclk` do seu transmitter |
| `clk_out2` (~256 MHz) | apenas `pclk_x5` do seu transmitter |

\* Colocar o lado stream do VDMA já no pixel clock evita mais uma travessia de domínio — o VDMA tem FIFO interno e cuida da passagem 100 MHz ↔ 51,2 MHz sozinho.

**Resets:** o Processor System Reset do domínio de pixel gera `peripheral_aresetn` → conecte ao vid_out, VTC (`resetn`), subset converter e ao `reset_n` do seu transmitter. E lembre: seu transmitter espera reset **ativo baixo** — `peripheral_aresetn` já é ativo baixo, encaixa direto.

**Endereços:** no Address Editor, o `M_AXI_MM2S` do VDMA precisa mapear a DDR inteira (mesma checagem do Tutorial 1). O `S_AXI_LITE` do VDMA ganha um endereço tipo `0x4300_0000`.

Rode *Validate Design*. Warnings de clock domain crossing nas interfaces com FIFO (VDMA, vid_out) são esperados; erros de "clock mismatch" em conexão direta, não — significa que algum bloco ficou no clock errado.

---

## A.5 — Constraints (XDC)

As saídas TMDS agora saem do block design, então o XDC referencia os nomes das portas externas (confira os nomes exatos na aba *External Ports*). Exemplo para PYNQ-Z2/Zybo (ajuste os pinos para a SUA placa!):

```tcl
## HDMI TX — CONFIRA os pinos no manual/master XDC da sua placa!
set_property -dict {PACKAGE_PIN L16 IOSTANDARD TMDS_33} [get_ports tmds_clk_p]
set_property -dict {PACKAGE_PIN L17 IOSTANDARD TMDS_33} [get_ports tmds_clk_n]
set_property -dict {PACKAGE_PIN K17 IOSTANDARD TMDS_33} [get_ports {tmds_data_p[0]}]
set_property -dict {PACKAGE_PIN K18 IOSTANDARD TMDS_33} [get_ports {tmds_data_n[0]}]
set_property -dict {PACKAGE_PIN K19 IOSTANDARD TMDS_33} [get_ports {tmds_data_p[1]}]
set_property -dict {PACKAGE_PIN J19 IOSTANDARD TMDS_33} [get_ports {tmds_data_n[1]}]
set_property -dict {PACKAGE_PIN J18 IOSTANDARD TMDS_33} [get_ports {tmds_data_p[2]}]
set_property -dict {PACKAGE_PIN H18 IOSTANDARD TMDS_33} [get_ports {tmds_data_n[2]}]
```

O padrão **TMDS_33** é obrigatório (é o que faz o par diferencial HDMI funcionar eletricamente). Depois: *Generate Bitstream* → *Export Hardware* (novo `.xsa`) → atualize a plataforma no Vitis (clique direito na plataforma → *Update Hardware Specification*).

---
## A.6 — Código Vitis: compondo o framebuffer e ligando o VDMA

Adicione ao `main.c` do Tutorial 1 (novos trechos comentados):

```c
#include "xaxivdma.h"   /* driver do VDMA */

/* ------------------------------------------------------------------
 * FRAMEBUFFER 1024x600, 32 bits/pixel (0x00RRGGBB).
 * A tela e maior que as imagens (600 > 512), entao centralizamos
 * verticalmente com offset de (600-512)/2 = 44 linhas.
 * ------------------------------------------------------------------ */
#define FB_W      1024
#define FB_H      600
#define V_OFF     ((FB_H - HEIGHT) / 2)   /* 44 */

static u32 framebuf[FB_H][FB_W] __attribute__((aligned(64)));
static XAxiVdma vdma;

/* Converte 1 pixel cinza em RGB 32 bits (replica o valor nos 3 canais) */
static inline u32 gray2rgb(u8 g) { return ((u32)g << 16) | ((u32)g << 8) | g; }

/* ================================================================
 * Compoe a tela: original a esquerda, Sobel a direita.
 * Chame DEPOIS de run_sobel().
 * ================================================================ */
void compose_framebuffer(void)
{
    /* fundo preto */
    for (int r = 0; r < FB_H; r++)
        for (int c = 0; c < FB_W; c++)
            framebuf[r][c] = 0x000000;

    for (int r = 0; r < HEIGHT; r++) {
        for (int c = 0; c < WIDTH; c++) {
            framebuf[r + V_OFF][c]         = gray2rgb(img_in [r*WIDTH + c]); /* esquerda  */
            framebuf[r + V_OFF][c + WIDTH] = gray2rgb(img_out[r*WIDTH + c]); /* direita   */
        }
    }

    /* CACHE, sempre ele: o VDMA vai ler a DDR direto (porta HP),
     * entao empurre o framebuffer do cache para a DDR.            */
    Xil_DCacheFlushRange((UINTPTR)framebuf, sizeof(framebuf));
}

/* ================================================================
 * Configura o VDMA em leitura circular: depois desta funcao o
 * monitor mostra o framebuffer PARA SEMPRE, sem CPU envolvida.
 * ================================================================ */
int init_vdma(void)
{
    XAxiVdma_Config *cfg = XAxiVdma_LookupConfig(XPAR_AXIVDMA_0_DEVICE_ID);
    if (!cfg) { xil_printf("ERRO: VDMA nao encontrado\r\n"); return XST_FAILURE; }

    if (XAxiVdma_CfgInitialize(&vdma, cfg, cfg->BaseAddress) != XST_SUCCESS)
        return XST_FAILURE;

    XAxiVdma_DmaSetup rd;
    rd.VertSizeInput       = FB_H;            /* linhas                     */
    rd.HoriSizeInput       = FB_W * 4;        /* BYTES por linha (nao px!)  */
    rd.Stride              = FB_W * 4;        /* bytes ate a proxima linha  */
    rd.FrameDelay          = 0;
    rd.EnableCircularBuf   = 1;               /* re-varre o frame sozinho   */
    rd.EnableSync          = 0;               /* free running (sem genlock) */
    rd.PointNum            = 0;
    rd.EnableFrameCounter  = 0;
    rd.FixedFrameStoreAddr = 0;

    if (XAxiVdma_DmaConfig(&vdma, XAXIVDMA_READ, &rd) != XST_SUCCESS)
        return XST_FAILURE;

    /* Endereco do (unico) frame buffer */
    UINTPTR addr = (UINTPTR)framebuf;
    if (XAxiVdma_DmaSetBufferAddr(&vdma, XAXIVDMA_READ, &addr) != XST_SUCCESS)
        return XST_FAILURE;

    /* Play! */
    if (XAxiVdma_DmaStart(&vdma, XAXIVDMA_READ) != XST_SUCCESS)
        return XST_FAILURE;

    xil_printf("VDMA rodando: monitor deve acender.\r\n");
    return XST_SUCCESS;
}

/* ================================================================ */
int main(void)
{
    xil_printf("\r\n=== Sobel + HDMI ===\r\n");

    if (init_dma() != XST_SUCCESS) return -1;   /* Tutorial 1 */
    make_test_image();                          /* Tutorial 1 */
    if (run_sobel() != XST_SUCCESS) return -1;  /* Tutorial 1 */

    compose_framebuffer();                      /* novo */
    if (init_vdma() != XST_SUCCESS) return -1;  /* novo */

    /* O ARM pode ate dormir: o VDMA alimenta o monitor sozinho.
     * Se voce recompuser o framebuffer (nova imagem), basta chamar
     * compose_framebuffer() de novo - o flush de cache incluso
     * torna a mudanca visivel no proximo frame. */
    while (1);
    return 0;
}
```

Repare no detalhe pedagógico bonito: depois do `init_vdma()`, se você alterar `framebuf` e der flush, **a tela muda sozinha** — o VDMA está varrendo a DDR 60×/s. Framebuffer é isso.

---

## A.7 — Troubleshooting específico de vídeo

| Sintoma | Causa provável | Solução |
|---|---|---|
| Tela preta total (monitor "sem sinal") | Clock 5x errado, reset preso, ou pinos TMDS errados no XDC | Confira razão exata 1:5 no Clocking Wizard, `locked` → PS Reset, e os pinos no manual da placa |
| Monitor sincroniza (detecta 1024×600) mas imagem preta | VDMA não está entregando dados: esqueceu `XAxiVdma_DmaStart`, endereço errado, ou HP não habilitada | Leia o registrador de erro do VDMA (`XAxiVdma_GetStatus`); confira Address Editor |
| Imagem "rolando"/rasgada | FIFO underflow: VDMA não sustenta a banda | Aumente Read Burst Size (32→64), Line Buffer Depth, e use porta HP exclusiva |
| Cores erradas (ex.: tudo azulado) | Ordem RGB trocada entre o subset converter e o `video_din` | Ajuste o remap do subset converter (`tdata[23:0]`) ou a ordem dos canais no seu encoder |
| Imagem deslocada/enrolada horizontalmente | `HoriSizeInput`/`Stride` em PIXELS em vez de BYTES | Ambos devem ser `FB_W * 4` |
| Metade da tela com lixo | Faltou `Xil_DCacheFlushRange` do framebuffer | Flush após CADA escrita no framebuf |
| Funciona mas trava se rodar Sobel de novo | DMA e VDMA disputando a mesma HP saturada | Portas HP separadas (HP0 p/ DMA, HP1 p/ VDMA) |

**Dica de depuração incremental:** antes de ligar o VDMA, preencha o `framebuf` com barras coloridas *por software* (reproduzindo o seu `video_display.v` em C!). Se as barras aparecerem, todo o caminho VDMA→HDMI está bom, e qualquer problema restante é do lado Sobel/composição. Depurar em camadas economiza horas.

---

## A.8 — Fechando o ciclo

Olha que elegante o que você construiu: os **três AXIs do tutorial original** continuam lá (Lite para controle, Full para memória, Stream para pixels), e agora você viu que o mesmo idioma escala para vídeo em tempo real — o VDMA é só um AXI DMA que aprendeu a pensar em 2D e a correr em círculos. E o seu RTL HDMI, que antes era um projeto isolado, virou um IP de saída de vídeo reutilizável em qualquer design Zynq.

**Próximos passos naturais:**
1. **Double buffering**: 2 frame buffers no VDMA + `XAxiVdma_StartParking` para trocar de frame sem tearing.
2. Processar a imagem **continuamente** (loop: DMA → Sobel → compõe → tela) e ver a latência na prática.
3. Trocar a imagem de teste por uma foto real carregada via SD card (xilffs) — aí o antes/depois no monitor fica impressionante de verdade.
