`timescale 1ns / 1ps

/*
 * Módulo: lineBuffer
 * -------------------
 * Implementa um buffer de linha (line buffer) usado para armazenar
 * pixels recebidos serialmente (1 byte por pixel) e disponibilizá-los
 * em grupos de 3 pixels consecutivos na saída.
 *
 * Funcionamento:
 *  - A cada ciclo de clock em que i_data_valid está ativo, um novo
 *    byte (pixel) é escrito na memória interna "line", na posição
 *    apontada por wrPntr, que é incrementado automaticamente.
 *  - A leitura é feita de forma combinacional: a saída o_data entrega
 *    3 pixels consecutivos (rdPntr, rdPntr+1, rdPntr+2), totalizando
 *    24 bits (3 bytes).
 *  - O ponteiro de leitura rdPntr avança sempre que i_rd_data é
 *    ativado.
 *
 * Parâmetros/Portas:
 *  i_clk        - clock do sistema
 *  i_rst        - reset síncrono (zera os ponteiros)
 *  i_data       - byte de entrada (pixel) a ser armazenado
 *  i_data_valid - indica que i_data é válido e deve ser escrito
 *  o_data       - saída com 3 pixels concatenados (24 bits)
 *  i_rd_data    - pulso que avança o ponteiro de leitura
 */

module lineBuffer(
    input i_clk,             // clock principal do módulo
    input i_rst,             // reset síncrono, zera os ponteiros de leitura/escrita
    input [7:0] i_data,      // dado de entrada (1 pixel = 1 byte)
    input i_data_valid,      // sinaliza que i_data é válido para escrita

    output [24:0] o_data,    // 24 bits porque cada pixel tem 8 bits (1 Byte/pixel) e 3 pixels x 8 bits = 24 bits
    input  i_rd_data         // sinaliza que deve avançar o ponteiro de leitura
);

reg [7:0] line [511:0];     // memória do line buffer: 512 posições de 8 bits (1 byte) cada
reg [8:0] wrPntr;           // ponteiro de escrita (9 bits, cobre as 512 posições)
reg [8:0] rdPntr;           // ponteiro de leitura (9 bits, cobre as 512 posições)


// Processo de escrita: grava o byte de entrada na posição atual do ponteiro de escrita
always @(posedge i_clk)
begin
    if(i_data_valid)             // só escreve quando o dado de entrada é válido
        line[wrPntr] <= i_data;  // armazena o pixel recebido na posição wrPntr
end

// Processo de controle do ponteiro de escrita
always @(posedge i_clk)
begin
    if(i_rst)                    // em reset, zera o ponteiro de escrita
        wrPntr <= 'd0;
    else if(i_data_valid)        // a cada escrita válida, avança o ponteiro
        wrPntr <= wrPntr + 'd1;
end

// Leitura combinacional: concatena 3 pixels consecutivos a partir de rdPntr
assign o_data = {line[rdPntr],line[rdPntr + 1],line[rdPntr + 2]};   // posições 0, 1 e 2 - pois lemos 3 pixels por vez

// Processo de controle do ponteiro de leitura
always @(posedge i_clk)
begin
    if(i_rst)
        rdPntr <= 'd0;           // em reset, zera o ponteiro de leitura
    else if(i_rd_data)
        rdPntr <= rdPntr + 'd1;  // a cada pulso de leitura, avança o ponteiro
end

endmodule