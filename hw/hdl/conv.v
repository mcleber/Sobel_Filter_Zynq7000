`timescale 1ns / 1ps

// ============================================================================
// Módulo: conv
// Descrição:
//   Detecção de bordas pelo operador de Sobel sobre uma janela 3x3 de
//   pixels. Aplicado à imagem na FPGA.
//
// Funcionamento:
//   - Recebe 9 pixels de 8 bits (tons de cinza) através de i_pixel_data.
//   - Aplica dois kernels 3x3 de Sobel à mesma janela:
//       kernel1 (Gx) responde a bordas verticais (variação na horizontal);
//       kernel2 (Gy) responde a bordas horizontais (variação na vertical).
//   - Multiplica cada pixel pelo respectivo coeficiente de cada kernel
//     e soma os nove resultados, obtendo Gx e Gy.
//   - Calcula a magnitude do gradiente ao quadrado: Gx² + Gy².
//   - Compara com um limiar (4000): acima dele o pixel é borda (branco,
//     8'hFF); abaixo, não é borda (preto, 8'h00).
//
// Usar Gx² + Gy² em vez de sqrt(Gx² + Gy²) evita a raiz quadrada no
// hardware. Comparar a soma dos quadrados com 4000 equivale a comparar a
// magnitude com sqrt(4000) ≈ 63.
//
// Interface:
//   i_clk                 : clock do circuito.
//   i_pixel_data          : janela de 9 pixels, totalizando 72 bits.
//   i_pixel_data_valid    : indica quando os dados de entrada são válidos.
//   o_convolved_data      : resultado binário (8'hFF = borda, 8'h00 = fundo).
//   o_convolved_data_valid: indica quando o resultado é válido.
//
// Pipeline (4 estágios registrados):
//   1. Multiplicação dos pixels pelos coeficientes de Gx e Gy.
//   2. Registro das somas (Gx e Gy).
//   3. Quadrado de Gx e de Gy.
//   4. Soma dos quadrados, comparação com o limiar e saída.
//   O sinal de validade acompanha os dados através dos quatro estágios.
//
// Observação:
//   Existe uma latência de quatro ciclos de clock entre a entrada válida
//   e a saída válida.
// ============================================================================

// Define a unidade de tempo como 1 ns e a precisão como 1 ps.
`timescale 1ns / 1ps

// ============================================================================
// Declaração do módulo
// ============================================================================

// Nome do módulo: conv.
module conv(

    // Clock utilizado para sincronizar os estágios do pipeline.
    input        i_clk,

    // Entrada contendo 9 pixels de 8 bits cada.
    // 9 pixels x 8 bits = 72 bits.
    input [71:0] i_pixel_data,

    // Indica que os dados presentes em i_pixel_data são válidos.
    input        i_pixel_data_valid,

    // Resultado da detecção de bordas: 8'hFF (borda) ou 8'h00 (fundo).
    output reg [7:0] o_convolved_data,

    // Indica que o resultado presente em o_convolved_data é válido.
    output reg   o_convolved_data_valid
    );

// Variável inteira utilizada como índice nos loops.
integer i;

// ============================================================================
// Kernels de Sobel
// ============================================================================

// Cada kernel armazena 9 coeficientes de 8 bits. Os valores negativos
// ficam em complemento de dois (ex.: -1 = 8'hFF) e são interpretados
// com sinal através de $signed na multiplicação.
reg [7:0] kernel1 [8:0];  // Gx: bordas verticais
reg [7:0] kernel2 [8:0];  // Gy: bordas horizontais

// ============================================================================
// Dados intermediários
// ============================================================================

// Resultado da multiplicação de cada pixel pelo coeficiente de Gx
// (multData1) e de Gy (multData2). São 16 bits com sinal: o maior valor
// em módulo é 2 x 255 = 510.
reg [15:0] multData1[8:0];
reg [15:0] multData2[8:0];

// Soma combinacional dos nove produtos: Gx (sumDataInt1) e Gy
// (sumDataInt2). O maior valor em módulo é 4 x 255 = 1020.
reg [15:0] sumDataInt1;
reg [15:0] sumDataInt2;

// Gx e Gy registrados para o próximo estágio do pipeline.
reg [15:0] sumData1;
reg [15:0] sumData2;

// Indica que os resultados das multiplicações são válidos.
reg multDataValid;

// Indica que o resultado da soma é válido.
reg sumDataValid;

// Sinal de validade da convolução.
// Atualmente é declarado, mas não é utilizado posteriormente no módulo.
reg convolved_data_valid;

// Gx² (convolved_data_int1) e Gy² (convolved_data_int2).
// 21 bits: o maior quadrado é 1020² = 1.040.400 < 2²¹.
reg [20:0] convolved_data_int1;
reg [20:0] convolved_data_int2;

// Gx² + Gy² (magnitude do gradiente ao quadrado).
// 22 bits: a maior soma é 2.080.800 < 2²².
wire [21:0] convolved_data_int;

// Indica que Gx² e Gy² são válidos.
reg convolved_data_int_valid;

// ============================================================================
// Inicialização dos kernels
// ============================================================================

// Os kernels nunca são alterados, então a síntese os trata como
// constantes. O índice segue a ordem dos pixels em i_pixel_data
// (índice 0 = i_pixel_data[7:0]). Na forma de matriz 3x3:
//
//        kernel1 (Gx)          kernel2 (Gy)
//      [ 1   0  -1 ]         [  1   2   1 ]
//      [ 2   0  -2 ]         [  0   0   0 ]
//      [ 1   0  -1 ]         [ -1  -2  -1 ]
initial
begin
    kernel1[0] =  1;
    kernel1[1] =  0;
    kernel1[2] = -1;
    kernel1[3] =  2;
    kernel1[4] =  0;
    kernel1[5] = -2;
    kernel1[6] =  1;
    kernel1[7] =  0;
    kernel1[8] = -1;

    kernel2[0] =  1;
    kernel2[1] =  2;
    kernel2[2] =  1;
    kernel2[3] =  0;
    kernel2[4] =  0;
    kernel2[5] =  0;
    kernel2[6] = -1;
    kernel2[7] = -2;
    kernel2[8] = -1;
end

// ============================================================================
// Estágio 1: multiplicação
// ============================================================================

// Bloco executado na borda de subida do clock.
always @(posedge i_clk)
begin

    // Percorre os nove pixels da janela 3x3.
    for(i=0;i<9;i=i+1)
    begin

        // Extrai 8 bits correspondentes ao pixel i.
        //
        // i*8 determina a posição inicial do pixel.
        // +:8 indica que serão selecionados 8 bits a partir dessa posição.
        //
        // Exemplos:
        // i = 0 -> i_pixel_data[7:0]
        // i = 1 -> i_pixel_data[15:8]
        // i = 2 -> i_pixel_data[23:16]
        // ...
        // i = 8 -> i_pixel_data[71:64]
        //
        // {1'b0, pixel} acrescenta um bit 0 à esquerda para que o pixel
        // (0 a 255) continue positivo quando tratado com sinal. O pixel é
        // então multiplicado pelo coeficiente de Gx e pelo de Gy.
        multData1[i] <= $signed(kernel1[i])*$signed({1'b0,i_pixel_data[i*8+:8]});
        multData2[i] <= $signed(kernel2[i])*$signed({1'b0,i_pixel_data[i*8+:8]});
    end

    // Registra a validade dos dados de entrada.
    // Esse sinal será utilizado para indicar que multData é válido.
    multDataValid <= i_pixel_data_valid;
end


// ============================================================================
// Soma (combinacional)
// ============================================================================

// Bloco combinacional.
// É executado sempre que algum dos sinais utilizados na expressão
// for alterado. Soma os nove produtos, com sinal, obtendo Gx e Gy.
always @(*)
begin
    sumDataInt1 = 0;
    sumDataInt2 = 0;
    for(i=0;i<9;i=i+1)
    begin
        sumDataInt1 = $signed(sumDataInt1) + $signed(multData1[i]);
        sumDataInt2 = $signed(sumDataInt2) + $signed(multData2[i]);
    end
end

// ============================================================================
// Estágio 2: registro da soma
// ============================================================================

// Bloco executado na borda de subida do clock.
always @(posedge i_clk)
begin
    sumData1 <= sumDataInt1;
    sumData2 <= sumDataInt2;
    sumDataValid <= multDataValid;
end

// ============================================================================
// Estágio 3: quadrado de Gx e de Gy
// ============================================================================

// Bloco executado na borda de subida do clock.
// O quadrado é sempre positivo, então o sinal de Gx e Gy não importa
// a partir daqui.
always @(posedge i_clk)
begin
    convolved_data_int1 <= $signed(sumData1)*$signed(sumData1);
    convolved_data_int2 <= $signed(sumData2)*$signed(sumData2);
    convolved_data_int_valid <= sumDataValid;
end

// Soma combinacional: Gx² + Gy².
assign convolved_data_int = convolved_data_int1+convolved_data_int2;

// ============================================================================
// Estágio 4: limiar e saída
// ============================================================================

// Bloco executado na borda de subida do clock.
// Acima do limiar, o pixel é marcado como borda (branco); abaixo, como
// fundo (preto). Aumentar 4000 deixa só as bordas mais fortes; diminuir
// revela bordas mais fracas (e mais ruído).
always @(posedge i_clk)
begin
    if(convolved_data_int > 4000)
        o_convolved_data <= 8'hff;
    else
        o_convolved_data <= 8'h00;
    o_convolved_data_valid <= convolved_data_int_valid;
end

endmodule
