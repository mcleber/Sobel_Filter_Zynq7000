`timescale 1ns / 1ps

// ============================================================================
// Módulo: conv
// Descrição:
//   Realiza uma convolução 3x3 simples sobre uma janela de 9 pixels.
//
// Funcionamento:
//   - Recebe 9 pixels de 8 bits através de i_pixel_data.
//   - Utiliza um kernel 3x3 cujos nove coeficientes possuem valor 1.
//   - Multiplica cada pixel pelo respectivo coeficiente do kernel.
//   - Soma os nove resultados.
//   - Divide a soma por 9, realizando a média dos pixels.
//
// Como todos os coeficientes do kernel são iguais a 1, esta operação
// corresponde a um filtro de média 3x3 (blur).
//
// Interface:
//   i_clk                  : clock do circuito.
//   i_pixel_data          : janela de 9 pixels, totalizando 72 bits.
//   i_pixel_data_valid    : indica quando os dados de entrada são válidos.
//   o_convolved_data      : resultado da convolução, com 8 bits.
//   o_convolved_data_valid: indica quando o resultado é válido.
//
// Pipeline:
//   1. Multiplicação dos pixels pelos coeficientes do kernel.
//   2. Soma dos nove resultados.
//   3. Divisão da soma por 9.
//   O sinal de validade acompanha os dados através dos três estágios.
//
// Observação:
//   O módulo utiliza três etapas registradas, portanto existe uma latência
//   de três ciclos de clock entre a entrada válida e a saída válida.
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

    // Resultado da convolução, limitado a 8 bits.
    output reg [7:0] o_convolved_data,

    // Indica que o resultado presente em o_convolved_data é válido.
    output reg   o_convolved_data_valid
    );

// Variável inteira utilizada como índice nos loops.
integer i;

// ============================================================================
// Kernel da convolução
// ============================================================================

// Armazena os 9 coeficientes do kernel 3x3.
// Cada coeficiente possui 8 bits.
reg [7:0] kernel [8:0];

// ============================================================================
// Dados intermediários
// ============================================================================

// Armazena o resultado da multiplicação de cada pixel pelo
// respectivo coeficiente do kernel.
// Cada resultado possui 16 bits para evitar perda durante a multiplicação.
reg [15:0] multData[8:0];

// Armazena temporariamente a soma dos nove resultados das multiplicações.
reg [15:0] sumDataInt;

// Registra a soma dos resultados para o próximo estágio do pipeline.
reg [15:0] sumData;

// Indica que os resultados das multiplicações são válidos.
reg multDataValid;

// Indica que o resultado da soma é válido.
reg sumDataValid;

// Sinal de validade da convolução.
// Atualmente é declarado, mas não é utilizado posteriormente no módulo.
reg convolved_data_valid;

// ============================================================================
// Inicialização do kernel
// ============================================================================

initial
begin

    // Percorre os nove elementos do kernel.
    for(i=0;i<9;i=i+1)
    begin

        // Define cada coeficiente do kernel como 1.
        // O kernel resultante é:
        //
        //     [1 1 1]
        //     [1 1 1]
        //     [1 1 1]
        //
        kernel[i] = 1;
    end
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
        // O pixel é então multiplicado pelo respectivo coeficiente
        // do kernel.
        multData[i] <= kernel[i]*i_pixel_data[i*8+:8];
    end

    // Registra a validade dos dados de entrada.
    // Esse sinal será utilizado para indicar que multData é válido.
    multDataValid <= i_pixel_data_valid;
end


// ============================================================================
// Estágio intermediário: soma
// ============================================================================

// Bloco combinacional.
// É executado sempre que algum dos sinais utilizados na expressão
// for alterado.
always @(*)
begin

    // Inicializa a soma com zero.
    sumDataInt = 0;

    // Percorre os nove resultados das multiplicações.
    for(i=0;i<9;i=i+1)
    begin

        // Soma o resultado da multiplicação atual ao acumulador.
        sumDataInt = sumDataInt + multData[i];
    end
end

// ============================================================================
// Estágio 2: registro da soma
// ============================================================================

// Bloco executado na borda de subida do clock.
always @(posedge i_clk)
begin

    // Registra o resultado da soma.
    sumData <= sumDataInt;

    // Registra a validade associada ao resultado da soma.
    sumDataValid <= multDataValid;
end

// ============================================================================
// Estágio 3: cálculo da média e saída
// ============================================================================

// Bloco executado na borda de subida do clock.
always @(posedge i_clk)
begin

    // Divide a soma dos nove pixels por 9.
    //
    // Como o kernel possui nove coeficientes iguais a 1:
    //
    //     resultado = (pixel0 + pixel1 + ... + pixel8) / 9
    //
    // A divisão inteira descarta qualquer parte fracionária.
    o_convolved_data <= sumData/9;

    // Indica que o resultado da convolução é válido.
    o_convolved_data_valid <= sumDataValid;
end

// Finaliza a declaração do módulo.
endmodule


