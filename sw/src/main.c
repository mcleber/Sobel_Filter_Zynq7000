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
