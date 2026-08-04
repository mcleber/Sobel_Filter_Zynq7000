# Adendo 2: Reaproveitando seu RTL (BRAM), Interrupções, RGB e Benchmark

Quatro evoluções independentes do projeto. Você pode fazer qualquer uma isoladamente:

- **B.1** — Caminho alternativo de vídeo que **reusa seus `video_driver.v` e `video_display.v`** (framebuffer em BRAM, sem VDMA)
- **B.2** — Trocar polling por **interrupções** no AXI DMA
- **B.3** — Sobel em **imagens RGB**
- **B.4** — **Benchmark** PS vs PL: medindo o speedup

---

## B.1 — Segunda vida para os seus arquivos: framebuffer em BRAM

No Adendo 1, `video_driver.v` e `video_display.v` foram substituídos por IPs Xilinx (VTC + VDMA). Mas existe outra arquitetura, **mais simples**, em que eles sobrevivem quase intactos:

```
                 ┌────────────── PL ───────────────────────────┐
  PS ──AXI──►  AXI BRAM        BRAM (dual port)                │
  (escreve      Controller ──► Porta A                         │
   as imagens)                 Porta B ──► video_framebuffer   │
                                           (seu video_display  │
                                            modificado!)       │
                                               │               │
                               video_driver ───┤ (INTACTO!)    │
                                               ▼               │
                                       dvi_transmitter_top     │
                 └─────────────────────────────┼───────────────┘
                                               ▼ TMDS
```

### A ideia
Uma **BRAM dual-port** vira o framebuffer: o PS escreve as imagens pela **porta A** (através do IP *AXI BRAM Controller*, acessível por endereço como se fosse memória), e o seu pipeline de vídeo lê pela **porta B** na velocidade do pixel clock. Dois mundos, dois clocks, zero conflito — é exatamente para isso que BRAMs têm duas portas.

**Comparação com o caminho VDMA (Adendo 1):**

| | VDMA + DDR (Adendo 1) | BRAM (este caminho) |
|---|---|---|
| Capacidade | gigantesca (DDR) | **limitada** (~630 KB no Z7-020) |
| IPs Xilinx de vídeo | VDMA, VTC, vid_out, subset conv | **nenhum** — só o BRAM Controller |
| Seu RTL aproveitado | só o transmitter | **quase tudo** |
| Complexidade | média/alta | baixa |
| Conceito AXI ensinado | VDMA (streaming 2D) | **AXI BRAM Controller** (memória mapeada na PL) |

Como a BRAM é pequena, exibiremos as imagens em **256×256** (2 × 256×256 × 1 byte = 128 KB — cabe folgado), dobrando cada pixel na tela para ocupar 512×512. O Sobel continua processando em 512×512 na DDR; o PS só faz um *downscale* 2:1 ao copiar para a BRAM.

### B.1.1 Block Design: só 2 IPs novos
1. **AXI BRAM Controller** — duplo clique: *Number of BRAM interfaces = 1*, Data Width = 32. Conecte o `S_AXI` dele ao GP0 do PS (Run Connection Automation resolve). No Address Editor ele ganha, p.ex., `0x4000_0000` com **Range = 128K**.
2. **Block Memory Generator** — o Connection Automation costuma criá-lo junto. Duplo clique: **Memory Type = True Dual Port RAM**. A porta A já fica ligada ao controller. Selecione a interface `BRAM_PORTB` → **Make External**.

> **Por que o PS não precisa de flush de cache aqui?** No BSP standalone, a região de endereços da PL (0x4000_0000+) é marcada como *device memory*, não cacheável. Escreveu, está lá. (Mais um contraste didático com a DDR do Tutorial 1!)

### B.1.2 O wrapper HDL: juntando block design + seu RTL
Aqui entra uma técnica nova: em vez de colocar seu RTL *dentro* do diagrama, criamos um **top-level em Verilog** que instancia o block design E a sua cadeia de vídeo lado a lado. Crie `top.v`:

```verilog
/*
 * TOP: instancia o block design (PS+DMA+Sobel+BRAM) e a cadeia
 * HDMI original, conectando a porta B da BRAM ao leitor de video.
 * Substitui o papel do antigo hdmi_colorbar_top.
 */
module top (
    input        sys_clk,      // oscilador da placa (como no original!)
    input        sys_rst_n,
    output       tmds_clk_p,  tmds_clk_n,
    output [2:0] tmds_data_p, tmds_data_n,
    // DDR/FIXED_IO do PS (o wrapper do BD lista essas portas; copie de la)
    inout [14:0] DDR_addr,  /* ... demais sinais DDR/FIXED_IO ... */
    inout [53:0] FIXED_IO_mio
);

    // ---- clocks de video: o MESMO clk_wiz do projeto original ----
    wire pixel_clk, pixel_clk_5x, clk_locked;
    clk_wiz_0 u_clk_wiz (
        .clk_in1 (sys_clk),
        .clk_out1(pixel_clk),      // 51.2 MHz
        .clk_out2(pixel_clk_5x),   // 256 MHz
        .reset   (~sys_rst_n),
        .locked  (clk_locked)
    );
    wire rst_n = sys_rst_n & clk_locked;

    // ---- porta B da BRAM (exposta pelo block design) ----
    wire [31:0] bram_addr, bram_rdata;
    // (portas exatas: veja o wrapper gerado do BD - addrb/clkb/doutb/...)

    design_1_wrapper u_bd (
        .DDR_addr(DDR_addr), /* ... */
        .FIXED_IO_mio(FIXED_IO_mio), /* ... */
        .BRAM_PORTB_addr(bram_addr),
        .BRAM_PORTB_clk (pixel_clk),   // porta B roda no clock de PIXEL
        .BRAM_PORTB_dout(bram_rdata),
        .BRAM_PORTB_en  (1'b1),
        .BRAM_PORTB_we  (4'b0),        // so leitura
        .BRAM_PORTB_din (32'b0),
        .BRAM_PORTB_rst (1'b0)
    );

    // ---- SEU pipeline, praticamente identico ao original ----
    wire [10:0] xpos, ypos;
    wire [23:0] pix_data, video_rgb;
    wire hs, vs, de;

    video_driver u_driver (            // <<< INTACTO!
        .pixel_clk(pixel_clk), .sys_rst_n(rst_n),
        .video_hs(hs), .video_vs(vs), .video_de(de),
        .video_rgb(video_rgb),
        .pixel_xpos(xpos), .pixel_ypos(ypos),
        .pixel_data(pix_data)
    );

    video_framebuffer u_display (      // <<< video_display MODIFICADO
        .pixel_clk(pixel_clk), .sys_rst_n(rst_n),
        .pixel_xpos(xpos), .pixel_ypos(ypos),
        .bram_addr(bram_addr), .bram_rdata(bram_rdata),
        .pixel_data(pix_data)
    );

    dvi_transmitter_top u_tx (         // <<< INTACTO!
        .pclk(pixel_clk), .pclk_x5(pixel_clk_5x), .reset_n(rst_n),
        .video_din(video_rgb),
        .video_hsync(hs), .video_vsync(vs), .video_de(de),
        .tmds_clk_p(tmds_clk_p), .tmds_clk_n(tmds_clk_n),
        .tmds_data_p(tmds_data_p), .tmds_data_n(tmds_data_n),
        .tmds_oen()
    );
endmodule
```

(No Vivado: *Add Sources* → `top.v` → clique direito nele → **Set as Top**. O wrapper do BD vira submódulo.)

### B.1.3 `video_framebuffer.v` — o `video_display.v` renascido

A mudança conceitual é uma linha: **em vez de calcular a cor pela posição, buscamos a cor na memória usando a posição como endereço**. Compare com o original:

```verilog
/*
 * video_framebuffer: mesma interface do video_display original,
 * mas a cor vem da BRAM (porta B) em vez de ser calculada.
 *
 * Layout da BRAM (1 byte/pixel, empacotado em palavras de 32 bits):
 *   0x00000..0x0FFFF : imagem ORIGINAL 256x256
 *   0x10000..0x1FFFF : imagem SOBEL    256x256
 *
 * Na tela (1024x600): original em x=[0..511], sobel em x=[512..1023],
 * y=[44..555] (centralizado). Cada pixel da BRAM vira 2x2 na tela
 * (>>1 nas coordenadas).
 */
module video_framebuffer (
    input             pixel_clk,
    input             sys_rst_n,
    input      [10:0] pixel_xpos,
    input      [10:0] pixel_ypos,

    // porta B da BRAM
    output reg [31:0] bram_addr,     // endereco em BYTES
    input      [31:0] bram_rdata,    // palavra de 32 bits (4 pixels)

    output reg [23:0] pixel_data
);

    localparam V_OFF = 11'd44;   // (600-512)/2

    // Regiao ativa das imagens na tela
    wire in_img = (pixel_ypos >= V_OFF) && (pixel_ypos < V_OFF + 512);
    wire right  = pixel_xpos[10];               // x >= 512 -> imagem sobel

    // Coordenadas 256x256 (pixel doubling: >>1)
    wire [7:0] ix = pixel_xpos[8:1];            // (x % 512) / 2
    wire [8:0] iy = (pixel_ypos - V_OFF) >> 1;  // 0..255

    // Endereco do BYTE do pixel: base + iy*256 + ix
    wire [16:0] byte_addr = {right, iy[7:0], ix};  // 17 bits = 128KB

    // ---------------------------------------------------------
    // TIMING: a BRAM tem 1 ciclo de latencia de leitura, e o
    // byte certo dentro da palavra so e conhecido junto com o
    // dado. Registramos o "byte select" para alinhar.
    // Seu video_driver JA atrasa DE/HS/VS em 2 ciclos para
    // esperar pixel_data - essa folga absorve tudo. Por isso
    // ele funciona aqui SEM MUDAR NADA.
    // ---------------------------------------------------------
    reg [1:0] bsel;
    always @(posedge pixel_clk) begin
        bram_addr <= {byte_addr[16:2], 2'b00};  // alinha na palavra
        bsel      <= byte_addr[1:0];            // qual byte da palavra
    end

    // Seleciona o byte e replica em RGB (imagem em tons de cinza)
    reg [7:0] gray;
    always @(*) begin
        case (bsel)
            2'd0: gray = bram_rdata[ 7: 0];
            2'd1: gray = bram_rdata[15: 8];
            2'd2: gray = bram_rdata[23:16];
            2'd3: gray = bram_rdata[31:24];
        endcase
    end

    always @(posedge pixel_clk or negedge sys_rst_n) begin
        if (!sys_rst_n)      pixel_data <= 24'h000000;
        else if (in_img)     pixel_data <= {gray, gray, gray};
        else                 pixel_data <= 24'h000000;   // moldura preta
    end
endmodule
```

### B.1.4 Lado do PS: copiar as imagens para a BRAM

```c
#define BRAM_BASE   XPAR_AXI_BRAM_0_BASEADDR   /* ex.: 0x40000000 */
#define BRAM_ORIG   (BRAM_BASE)                /* imagem original  */
#define BRAM_SOBEL  (BRAM_BASE + 0x10000)      /* imagem filtrada  */

/* Downscale 2:1 (pega 1 pixel a cada 2, linhas pares) e copia
 * para a BRAM. Regiao nao-cacheavel: escrita direta, sem flush. */
void copy_to_bram(u8 *src, UINTPTR dst)
{
    volatile u8 *bram = (volatile u8 *)dst;
    for (int r = 0; r < 256; r++)
        for (int c = 0; c < 256; c++)
            bram[r*256 + c] = src[(r*2)*WIDTH + (c*2)];
}

/* no main(), depois de run_sobel(): */
copy_to_bram(img_in,  BRAM_ORIG);
copy_to_bram(img_out, BRAM_SOBEL);
/* pronto: a tela mostra antes/depois, sem VDMA! */
```

**Recapitulando o que este caminho ensinou:** o **AXI BRAM Controller** é a forma mais direta de o PS enxergar memória *dentro* da PL como endereços comuns — útil para trocar dados pequenos, tabelas de configuração, LUTs. E os seus três arquivos "descartados"? `video_driver.v` voltou **sem tocar em uma linha**, `video_display.v` virou `video_framebuffer.v` mudando só a origem do pixel, e o papel do `hdmi_colorbar_top.v` foi herdado pelo novo `top.v` — que segue a mesmíssima estrutura dele.

---
## B.2 — Trocando polling por interrupções no AXI DMA

No Tutorial 1, o ARM fica preso em `while (XAxiDma_Busy(...))` — queimando ciclos à toa. Com interrupções, o DMA **avisa** quando termina, e o ARM fica livre (para compor o framebuffer da próxima imagem, por exemplo).

### B.2.1 Mudanças no Vivado
1. Adicione o IP **Concat** (concatena sinais de interrupção).
2. No Zynq PS: *Interrupts → Fabric Interrupts → PL-PS Interrupt Ports →* ✅ **IRQ_F2P**.
3. Conecte:
   - `axi_dma_0/mm2s_introut` → `xlconcat_0/In0`
   - `axi_dma_0/s2mm_introut` → `xlconcat_0/In1`
   - `xlconcat_0/dout` → `PS/IRQ_F2P`
4. Regenere o bitstream e o `.xsa`, atualize a plataforma no Vitis.

Os IDs das interrupções aparecem no `xparameters.h` como `XPAR_FABRIC_AXI_DMA_0_MM2S_INTROUT_INTR` (61) e `..._S2MM_INTROUT_INTR` (62) — a ordem no Concat define qual é qual (In0 = 61, In1 = 62).

### B.2.2 Código: GIC + handlers

```c
#include "xscugic.h"   /* GIC: o controlador de interrupcoes do Cortex-A9 */

static XScuGic gic;
/* Flags de comunicacao handler -> main. "volatile" e OBRIGATORIO:
 * sem ele o compilador otimiza o loop de espera para sempre ler
 * um valor em registrador e nunca ve a mudanca feita pelo handler. */
static volatile int tx_done, rx_done, dma_error;

/* ---------- HANDLER do canal MM2S (envio DDR -> Sobel) ---------- */
static void mm2s_isr(void *ref)
{
    XAxiDma *dma_p = (XAxiDma *)ref;

    /* 1. Ler quais interrupcoes estao pendentes */
    u32 irq = XAxiDma_IntrGetIrq(dma_p, XAXIDMA_DMA_TO_DEVICE);
    /* 2. LIMPAR (ack) - esquecer isso = interrupcao dispara em loop
     *    infinito e o programa "congela" misteriosamente          */
    XAxiDma_IntrAckIrq(dma_p, irq, XAXIDMA_DMA_TO_DEVICE);

    if (irq & XAXIDMA_IRQ_ERROR_MASK) { dma_error = 1; return; }
    if (irq & XAXIDMA_IRQ_IOC_MASK)   tx_done = 1;   /* IOC = completou */
}

/* ---------- HANDLER do canal S2MM (retorno Sobel -> DDR) -------- */
static void s2mm_isr(void *ref)
{
    XAxiDma *dma_p = (XAxiDma *)ref;
    u32 irq = XAxiDma_IntrGetIrq(dma_p, XAXIDMA_DEVICE_TO_DMA);
    XAxiDma_IntrAckIrq(dma_p, irq, XAXIDMA_DEVICE_TO_DMA);

    if (irq & XAXIDMA_IRQ_ERROR_MASK) { dma_error = 1; return; }
    if (irq & XAXIDMA_IRQ_IOC_MASK)   rx_done = 1;
}

/* ---------- Configuracao do GIC (uma vez, no boot) --------------- */
int init_interrupts(void)
{
    XScuGic_Config *cfg = XScuGic_LookupConfig(XPAR_SCUGIC_SINGLE_DEVICE_ID);
    if (XScuGic_CfgInitialize(&gic, cfg, cfg->CpuBaseAddress) != XST_SUCCESS)
        return XST_FAILURE;

    /* Prioridade (0xA0) e gatilho por borda de subida (0x3) */
    XScuGic_SetPriorityTriggerType(&gic,
        XPAR_FABRIC_AXI_DMA_0_MM2S_INTROUT_INTR, 0xA0, 0x3);
    XScuGic_SetPriorityTriggerType(&gic,
        XPAR_FABRIC_AXI_DMA_0_S2MM_INTROUT_INTR, 0xA0, 0x3);

    /* Registrar os handlers */
    XScuGic_Connect(&gic, XPAR_FABRIC_AXI_DMA_0_MM2S_INTROUT_INTR,
                    (Xil_InterruptHandler)mm2s_isr, &dma);
    XScuGic_Connect(&gic, XPAR_FABRIC_AXI_DMA_0_S2MM_INTROUT_INTR,
                    (Xil_InterruptHandler)s2mm_isr, &dma);

    XScuGic_Enable(&gic, XPAR_FABRIC_AXI_DMA_0_MM2S_INTROUT_INTR);
    XScuGic_Enable(&gic, XPAR_FABRIC_AXI_DMA_0_S2MM_INTROUT_INTR);

    /* Ligar o caminho excecao-do-ARM -> GIC */
    Xil_ExceptionInit();
    Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_INT,
        (Xil_ExceptionHandler)XScuGic_InterruptHandler, &gic);
    Xil_ExceptionEnable();
    return XST_SUCCESS;
}

/* ---------- run_sobel() versao com interrupcoes ------------------ */
int run_sobel_irq(void)
{
    tx_done = rx_done = dma_error = 0;

    Xil_DCacheFlushRange((UINTPTR)img_in, IMG_SIZE);
    Xil_DCacheInvalidateRange((UINTPTR)img_out, IMG_SIZE);

    /* AGORA habilitamos as interrupcoes do DMA (no Tutorial 1
     * era IntrDisable - repare a inversao)                       */
    XAxiDma_IntrEnable(&dma, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DEVICE_TO_DMA);
    XAxiDma_IntrEnable(&dma, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);

    /* Mesma ordem do Tutorial 1: RECEPCAO primeiro */
    if (XAxiDma_SimpleTransfer(&dma, (UINTPTR)img_out, IMG_SIZE,
            XAXIDMA_DEVICE_TO_DMA) != XST_SUCCESS) return XST_FAILURE;
    if (XAxiDma_SimpleTransfer(&dma, (UINTPTR)img_in, IMG_SIZE,
            XAXIDMA_DMA_TO_DEVICE) != XST_SUCCESS) return XST_FAILURE;

    /* Aqui o ARM esta LIVRE. Num projeto real voce faria outra
     * coisa util; para demonstrar, esperamos as flags (wfi =
     * "wait for interrupt": dorme ate a proxima interrupcao,
     * gastando ~zero energia - bem melhor que busy-wait).        */
    while (!(tx_done && rx_done) && !dma_error)
        __asm__ __volatile__("wfi");

    if (dma_error) { xil_printf("ERRO no DMA!\r\n"); return XST_FAILURE; }

    Xil_DCacheInvalidateRange((UINTPTR)img_out, IMG_SIZE);
    return XST_SUCCESS;
}
```

No `main()`: chame `init_interrupts()` depois de `init_dma()`, e use `run_sobel_irq()` no lugar de `run_sobel()`.

**Os 2 bugs clássicos de interrupção:** (1) esquecer o `IntrAckIrq` → o handler dispara em loop eterno; (2) esquecer o `volatile` nas flags → o `while` nunca enxerga a mudança. Se o programa "congelar" após a primeira interrupção, é quase certamente um desses.

---

## B.3 — Sobel em imagens RGB

Duas decisões de projeto antes do código:

**Como aplicar Sobel em cor?** A forma padrão (e a que usaremos): converter RGB → **luminância** (Y) dentro do FPGA e aplicar o Sobel no Y. Bordas são um conceito de intensidade, não de cor — aplicar Sobel por canal e somar também existe, mas gasta 3× DSPs para um resultado visualmente parecido.

**Formato do stream:** 32 bits (`0x00RRGGBB`), casando com o framebuffer do Adendo 1 — assim a imagem colorida flui da DDR ao monitor sem conversões no PS.

### B.3.1 HLS: mudanças no `sobel.h`

```cpp
typedef ap_axiu<32, 0, 0, 0> axis_t;   // era <8,...> -> agora 32 bits
```

### B.3.2 HLS: mudanças no corpo do filtro

```cpp
    // ... dentro do col_loop, substituindo a leitura antiga:

    axis_t in_pix = in_stream.read();
    u32 rgb = in_pix.data;

    // --- RGB -> LUMINANCIA (aproximacao inteira do BT.601) ---
    // Y = 0.299R + 0.587G + 0.114B  ~=  (77R + 150G + 29B) >> 8
    // Somente somas e shifts: barato em hardware, sem float!
    ap_uint<8> r = rgb >> 16, g = rgb >> 8, b = rgb;
    ap_uint<8> new_pix = (77*r + 150*g + 29*b) >> 8;

    // ... todo o miolo (line buffers, janela, gx/gy) fica IGUAL,
    // operando sobre new_pix (8 bits) como antes ...

    // --- saida: replica a magnitude nos 3 canais (cinza) ---
    u32 out_rgb = ((u32)out_pix << 16) | ((u32)out_pix << 8) | out_pix;
    out.data = out_rgb;
    out.keep = 0xF;          // 4 bytes validos agora (era 1!)
    out.strb = 0xF;
```

Os line buffers continuam de 8 bits (guardamos o Y, não o RGB) — o custo de BRAM não muda. Variação divertida: em vez de replicar cinza na saída, misture a borda com a cor original (`bordas coloridas`) — uma linha de código, efeito visual ótimo.

### B.3.3 Ajustes fora do HLS
- **Vivado**: AXI DMA → Stream Data Width = **32** (era 8). Reexporte o IP do HLS e faça *Refresh IP Catalog* → *Upgrade*.
- **Vitis**: buffers viram `u32 img_in[IMG_SIZE]`, e `IMG_SIZE` em **bytes** agora é `WIDTH*HEIGHT*4` nas chamadas de DMA e cache. Erro clássico: passar o tamanho em pixels e transferir só ¼ da imagem.
- A imagem de teste pode virar algo colorido (gradientes RGB) para você *ver* que a luminância está pesando os canais direito.

---

## B.4 — Benchmark: PS vs PL (a melhor parte!)

Vamos medir o mesmo Sobel rodando (a) em C puro no ARM e (b) no FPGA, usando o **timer global** do Cortex-A9 — um contador de 64 bits que roda a metade do clock da CPU (333 MHz numa Zynq de 667 MHz).

```c
#include "xtime_l.h"   /* XTime_GetTime: le o Global Timer de 64 bits */

/* ---------- Sobel em SOFTWARE (referencia justa: mesmo algoritmo,
 * mesma aritmetica inteira do HLS) ------------------------------- */
void sobel_sw(const u8 *in, u8 *out)
{
    for (int r = 0; r < HEIGHT; r++) {
        for (int c = 0; c < WIDTH; c++) {
            if (r < 2 || c < 2) { out[r*WIDTH+c] = 0; continue; }
            /* janela 3x3 ancorada em (r-1, c-1), como no HLS */
            #define P(dr,dc) in[(r-1+(dr))*WIDTH + (c-1+(dc))]
            int gx = -P(0,0)+P(0,2) -2*P(1,0)+2*P(1,2) -P(2,0)+P(2,2);
            int gy = -P(0,0)-2*P(0,1)-P(0,2) +P(2,0)+2*P(2,1)+P(2,2);
            #undef P
            int mag = (gx<0?-gx:gx) + (gy<0?-gy:gy);
            out[r*WIDTH+c] = (mag > 255) ? 255 : mag;
        }
    }
}

/* ---------- Medicao ---------------------------------------------- */
void benchmark(void)
{
    static u8 out_sw[IMG_SIZE] __attribute__((aligned(64)));
    XTime t0, t1;
    /* COUNTS_PER_SECOND ja vem do BSP = CPU_FREQ/2 */

    /* --- (a) PS: ARM Cortex-A9 --- */
    XTime_GetTime(&t0);
    sobel_sw(img_in, out_sw);
    XTime_GetTime(&t1);
    u64 cyc_ps = t1 - t0;

    /* --- (b) PL: DMA + Sobel em hardware ---
     * Medimos o CICLO COMPLETO (flush + DMA ida + filtro + DMA
     * volta + invalidate). E a comparacao honesta: e o tempo que
     * a APLICACAO espera, incluindo o custo de mover os dados.   */
    XTime_GetTime(&t0);
    run_sobel();                       /* ou run_sobel_irq() */
    XTime_GetTime(&t1);
    u64 cyc_pl = t1 - t0;

    /* --- Resultados (em microssegundos) --- */
    u32 us_ps = (u32)(cyc_ps * 1000000 / COUNTS_PER_SECOND);
    u32 us_pl = (u32)(cyc_pl * 1000000 / COUNTS_PER_SECOND);
    xil_printf("\r\n===== BENCHMARK Sobel %dx%d =====\r\n", WIDTH, HEIGHT);
    xil_printf("PS (ARM @ 667MHz):  %8u us  (%u fps)\r\n", us_ps, 1000000/us_ps);
    xil_printf("PL (FPGA + DMA):    %8u us  (%u fps)\r\n", us_pl, 1000000/us_pl);
    xil_printf("Speedup: %u.%02ux\r\n",
               us_ps/us_pl, (us_ps*100/us_pl)%100);

    /* Sanity check: os dois resultados devem ser IDENTICOS,
     * afinal e a mesma aritmetica. Se diferir, tem bug em um lado. */
    int diff = 0;
    for (int i = 0; i < IMG_SIZE; i++)
        if (out_sw[i] != img_out[i]) diff++;
    xil_printf("Pixels diferentes PS vs PL: %d (esperado: 0)\r\n", diff);
}
```

### O que esperar (512×512, Zynq-7020)
- **PL**: o filtro processa 1 pixel/ciclo a 100 MHz → ~2,6 ms de cômputo puro; com DMA e cache, o ciclo completo fica na casa de **3–4 ms** (~300 fps).
- **PS**: o mesmo laço em C, mesmo com `-O2`, tipicamente fica em **15–40 ms** (depende das flags; compile em *Release*!).
- **Speedup típico: 5–15×** — e o mais importante: enquanto a PL filtra, o ARM estava *livre* (especialmente com as interrupções do B.2). Num pipeline contínuo de vídeo, é essa sobreposição que vale ouro, mais até que o speedup bruto.

Dois cuidados para a medição ser justa: compile o Vitis em **Release (-O2)** — em Debug o lado PS fica artificialmente lento e o speedup vira propaganda enganosa; e rode o `sobel_sw` duas vezes medindo só a segunda (a primeira "esquenta" o cache).

---

## Fechamento

| Adendo | O que entrega |
|---|---|
| Tutorial 1 | AXI Lite/Full/Stream + DMA + Sobel HLS |
| Adendo 1 | Vídeo HDMI via VDMA (caminho "IPs Xilinx") |
| **B.1** | Vídeo HDMI via BRAM **reusando seu RTL** (caminho "faça você mesmo") |
| **B.2** | Interrupções: o ARM deixa de esperar ocupado |
| **B.3** | RGB: streams de 32 bits, keep/strb de 4 bytes |
| **B.4** | Benchmark: o número que justifica tudo isso |

Com B.1 e o Adendo 1 você tem os **dois estilos de engenharia Zynq** lado a lado: montar com IPs prontos da Xilinx vs. integrar RTL próprio. Saber transitar entre os dois é exatamente o que diferencia quem "usa o Vivado" de quem projeta sistemas heterogêneos.
