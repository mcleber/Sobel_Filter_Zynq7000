`timescale 1ns / 1ps

// ============================================================================
// Module: imageProcessTop
//
// Descrição:
// Módulo de nível superior responsável por integrar todo o fluxo de
// processamento da imagem:
//
//   Entrada AXI-Stream
//        |
//        v
//   imageControl
//        |
//        v
//   Janela de pixels 3x3 (72 bits)
//        |
//        v
//      conv
//        |
//        v
//   outputBuffer (FIFO AXI-Stream)
//        |
//        v
//   Saída AXI-Stream
//
// O módulo também disponibiliza um sinal de interrupção (o_intr),
// gerado pelo bloco imageControl.
//
// O fluxo de dados utiliza uma interface semelhante ao AXI4-Stream:
//
//   i_data_valid / o_data_ready
//   o_data_valid / i_data_ready
//
// ============================================================================

module imageProcessTop(

    // ------------------------------------------------------------------------
    // Clock e reset
    // ------------------------------------------------------------------------

    // Clock principal do processamento.
    input   axi_clk,

    // Reset ativo em nível baixo.
    // É utilizado diretamente pelo outputBuffer e invertido para
    // fornecer um reset ativo em nível alto ao imageControl.
    input   axi_reset_n,


    // ------------------------------------------------------------------------
    // Interface AXI-Stream de entrada (slave)
    // ------------------------------------------------------------------------

    // Indica que o dado presente em i_data é válido.
    input   i_data_valid,

    // Pixel de entrada.
    // Cada pixel possui 8 bits.
    input [7:0] i_data,

    // Indica que o módulo está pronto para receber dados.
    //
    // Este sinal é controlado pelo nível de ocupação do FIFO de saída.
    // Quando o FIFO está próximo de ficar cheio, a entrada é interrompida
    // para evitar overflow.
    output  o_data_ready,


    // ------------------------------------------------------------------------
    // Interface AXI-Stream de saída (master)
    // ------------------------------------------------------------------------

    // Indica que existe um dado válido disponível na saída.
    output  o_data_valid,

    // Dado processado na saída.
    // Cada pixel processado possui 8 bits.
    output [7:0] o_data,

    // Indica que o módulo conectado à saída está pronto para receber
    // o dado.
    input   i_data_ready,


    // ------------------------------------------------------------------------
    // Interrupção
    // ------------------------------------------------------------------------

    // Sinal de interrupção gerado pelo bloco imageControl.
    output  o_intr

    );

    // =========================================================================
    // Sinais internos
    // =========================================================================

    // -------------------------------------------------------------------------
    // Janela de pixels utilizada pelo filtro de convolução.
    //
    // O bloco imageControl organiza os pixels recebidos em uma janela
    // contendo 9 pixels:
    //
    //   P0 P1 P2
    //   P3 P4 P5
    //   P6 P7 P8
    //
    // Como cada pixel possui 8 bits:
    //
    //   9 pixels x 8 bits = 72 bits
    // -------------------------------------------------------------------------
    wire [71:0] pixel_data;

    // Indica que uma nova janela de pixels está disponível em pixel_data.
    wire pixel_data_valid;

    // Sinal gerado pelo FIFO indicando que ele está próximo de ficar cheio.
    //
    // Esse sinal é utilizado para controlar o fluxo de entrada através
    // de o_data_ready.
    wire axis_prog_full;

    // Resultado de 8 bits produzido pelo bloco de convolução.
    wire [7:0] convolved_data;

    // Indica que convolved_data contém um resultado válido.
    wire convolved_data_valid;


    // =========================================================================
    // Controle de fluxo da entrada
    // =========================================================================

    // O módulo aceita novos dados enquanto o FIFO de saída não estiver
    // próximo de ficar cheio.
    //
    // Quando axis_prog_full = 1:
    //
    //     o_data_ready = 0
    //
    // Quando axis_prog_full = 0:
    //
    //     o_data_ready = 1
    //
    // Dessa forma, o processamento pode exercer backpressure sobre
    // a interface de entrada quando necessário.
    assign o_data_ready = !axis_prog_full;


    // =========================================================================
    // Image Control
    // =========================================================================
    //
    // Responsável pelo controle do fluxo de pixels e pela formação da
    // janela de 3x3 pixels utilizada pelo filtro de convolução.
    //
    // Entrada:
    //   i_data              -> pixel recebido
    //   i_data_valid        -> indica pixel válido
    //
    // Saída:
    //   pixel_data          -> janela de 3x3 pixels (72 bits)
    //   pixel_data_valid    -> indica janela válida
    //   o_intr              -> sinal de interrupção
    //
    // O reset deste bloco é ativo em nível alto, por isso axi_reset_n
    // é invertido.
    // =========================================================================

    imageControl IC(
        .i_clk(axi_clk),

        // axi_reset_n é ativo em nível baixo.
        // imageControl recebe reset ativo em nível alto.
        .i_rst(!axi_reset_n),

        // Pixel de entrada.
        .i_pixel_data(i_data),

        // Validade do pixel de entrada.
        .i_pixel_data_valid(i_data_valid),

        // Janela de 3x3 pixels.
        .o_pixel_data(pixel_data),

        // Indica que a janela de pixels é válida.
        .o_pixel_data_valid(pixel_data_valid),

        // Sinal de interrupção.
        .o_intr(o_intr)
    );


    // =========================================================================
    // Convolution
    // =========================================================================
    //
    // Recebe a janela de 3x3 pixels produzida pelo imageControl e realiza
    // a operação de convolução.
    //
    // Entrada:
    //   pixel_data          -> 9 pixels / 72 bits
    //   pixel_data_valid    -> indica janela válida
    //
    // Saída:
    //   convolved_data      -> resultado da convolução / 8 bits
    //   convolved_data_valid
    //
    // =========================================================================

    conv conv(
        .i_clk(axi_clk),

        // Janela contendo os 9 pixels.
        .i_pixel_data(pixel_data),

        // Indica que a janela de pixels é válida.
        .i_pixel_data_valid(pixel_data_valid),

        // Resultado da convolução.
        .o_convolved_data(convolved_data),

        // Indica que o resultado da convolução é válido.
        .o_convolved_data_valid(convolved_data_valid)
    );


    // =========================================================================
    // Output Buffer
    // =========================================================================
    //
    // FIFO AXI-Stream utilizado para armazenar temporariamente os resultados
    // da convolução antes que eles sejam enviados para o próximo módulo.
    //
    // O FIFO possui duas interfaces:
    //
    //   S_AXIS:
    //       recebe os resultados produzidos pelo bloco conv.
    //
    //   M_AXIS:
    //       fornece os resultados para o módulo externo.
    //
    // O FIFO também fornece o sinal axis_prog_full, utilizado para impedir
    // que novos dados sejam recebidos quando o buffer estiver próximo de
    // ficar cheio.
    // =========================================================================

    outputBuffer OB (

        // ---------------------------------------------------------------------
        // Sinais de status de reset do FIFO
        // ---------------------------------------------------------------------

        // Não utilizados neste módulo.
        // Os sinais são deixados desconectados porque não são necessários
        // para o controle externo.
        .wr_rst_busy(),

        // Não utilizado neste módulo.
        .rd_rst_busy(),


        // ---------------------------------------------------------------------
        // Clock e reset do FIFO
        // ---------------------------------------------------------------------

        // Clock utilizado pelo FIFO.
        .s_aclk(axi_clk),

        // Reset ativo em nível baixo.
        .s_aresetn(axi_reset_n),


        // ---------------------------------------------------------------------
        // Interface AXI-Stream de entrada do FIFO
        // ---------------------------------------------------------------------

        // Indica que o bloco conv possui um resultado válido.
        .s_axis_tvalid(convolved_data_valid),

        // Sinal de ready do FIFO.
        //
        // Este sinal não é utilizado externamente neste módulo, por isso
        // permanece desconectado.
        .s_axis_tready(),

        // Resultado da convolução enviado para o FIFO.
        .s_axis_tdata(convolved_data),


        // ---------------------------------------------------------------------
        // Interface AXI-Stream de saída do FIFO
        // ---------------------------------------------------------------------

        // Indica que existe um dado válido disponível na saída do FIFO.
        .m_axis_tvalid(o_data_valid),

        // Indica que o consumidor externo está pronto para receber o dado.
        .m_axis_tready(i_data_ready),

        // Dado processado fornecido pelo FIFO.
        .m_axis_tdata(o_data),


        // ---------------------------------------------------------------------
        // Status de ocupação do FIFO
        // ---------------------------------------------------------------------

        // Indica que o FIFO atingiu o nível programado de ocupação.
        //
        // Esse sinal é utilizado acima para controlar o sinal
        // o_data_ready.
        .axis_prog_full(axis_prog_full)
    );


endmodule
