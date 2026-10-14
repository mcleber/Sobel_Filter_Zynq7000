`timescale 1ns / 1ps

// Módulo: imageControl
// Descrição: Controlador de buffer de linhas (Line Buffer Controller) para processamento de imagens.
// Gerencia 4 line buffers em esquema circular para fornecer 3 linhas paralelas de pixels (ex: para janelas 3x3 de convolução).
module imageControl(
input                    i_clk,               // Sinal de clock principal
input                    i_rst,               // Sinal de reset (ativo em nível alto)
input [7:0]              i_pixel_data,        // Dado do pixel de entrada (8 bits)
input                    i_pixel_data_valid,  // Indicador de validade do pixel de entrada
output reg [71:0]        o_pixel_data,        // Saída de dados concatenados (3 linhas x 24 bits = 72 bits)
output                   o_pixel_data_valid,  // Indicador de validade dos dados de saída
output reg               o_intr               // Sinal de interrupção (pulsado ao fim da leitura de uma linha)
);

// Sinais internos e registradores
reg [8:0] pixelCounter;         // Contador de pixels gravados na linha atual (0 a 511)
reg [1:0] currentWrLineBuffer;  // Seleciona qual buffer está recebendo os dados de entrada (0 a 3)
reg [3:0] lineBuffDataValid;    // Sinal de escrita (data valid) individual para cada um dos 4 buffers
reg [3:0] lineBuffRdData;       // Sinal de leitura (read enable) individual para cada um dos 4 buffers
reg [1:0] currentRdLineBuffer;  // Seleciona o grupo de buffers que será lido no momento
wire [23:0] lb0data;            // Dados de saída do Line Buffer 0 (3 pixels concatenados = 24 bits)
wire [23:0] lb1data;            // Dados de saída do Line Buffer 1
wire [23:0] lb2data;            // Dados de saída do Line Buffer 2
wire [23:0] lb3data;            // Dados de saída do Line Buffer 3
reg [8:0] rdCounter;            // Contador de pixels lidos da linha atual (0 a 511)
reg rd_line_buffer;             // Flag que indica se a leitura dos buffers está ativa
reg [11:0] totalPixelCounter;   // Saldo total de pixels armazenados nos buffers
reg rdState;                    // Estado da FSM de leitura

// Estados da máquina de estados
localparam IDLE = 'b0,          // Aguardando acúmulo de dados suficientes
           RD_BUFFER = 'b1;     // Lendo dados dos line buffers

// A saída é válida durante todo o período em que a leitura de buffer estiver ativa
assign o_pixel_data_valid = rd_line_buffer;

// Controle do saldo de pixels armazenados no sistema
always @(posedge i_clk)
begin
    if(i_rst)
        totalPixelCounter <= 0;
    else
    begin
        if(i_pixel_data_valid & !rd_line_buffer)
            totalPixelCounter <= totalPixelCounter + 1;
        else if(!i_pixel_data_valid & rd_line_buffer)
            totalPixelCounter <= totalPixelCounter - 1;
    end
end

// Máquina de Estados Finita (FSM) de leitura e geração de interrupção
always @(posedge i_clk)
begin
    if(i_rst)
    begin
        rdState <= IDLE;
        rd_line_buffer <= 1'b0;
        o_intr <= 1'b0;
    end
    else
    begin
        case(rdState)
            IDLE:begin
                o_intr <= 1'b0;
                // Inicia a leitura quando houver pelo menos 3 linhas completas gravadas (3 * 512 = 1536 pixels)
                if(totalPixelCounter >= 1536)
                begin
                    rd_line_buffer <= 1'b1;
                    rdState <= RD_BUFFER;
                end
            end
            RD_BUFFER:begin
                // Finaliza a leitura após processar 512 pixels da linha
                if(rdCounter == 511)
                begin
                    rdState <= IDLE;
                    rd_line_buffer <= 1'b0;
                    o_intr <= 1'b1; // Gera o pulso de interrupção
                end
            end
        endcase
    end
end
    
// Contador de pixels recebidos por linha (0 a 511)
always @(posedge i_clk)
begin
    if(i_rst)
        pixelCounter <= 0;
    else 
    begin
        if(i_pixel_data_valid)
            pixelCounter <= pixelCounter + 1;
    end
end

// Alterna o buffer de escrita após preencher uma linha inteira de 512 pixels
always @(posedge i_clk)
begin
    if(i_rst)
        currentWrLineBuffer <= 0;
    else
    begin
        if(pixelCounter == 511 & i_pixel_data_valid)
            currentWrLineBuffer <= currentWrLineBuffer+1;
    end
end

// Mux/Demux para habilitar a escrita apenas no line buffer selecionado no momento
always @(*)
begin
    lineBuffDataValid = 4'h0;
    lineBuffDataValid[currentWrLineBuffer] = i_pixel_data_valid;
end

// Contador de pixels lidos por linha (0 a 511)
always @(posedge i_clk)
begin
    if(i_rst)
        rdCounter <= 0;
    else 
    begin
        if(rd_line_buffer)
            rdCounter <= rdCounter + 1;
    end
end

// Alterna o ponteiro de leitura após finalizar uma linha inteira lida (512 pixels)
always @(posedge i_clk)
begin
    if(i_rst)
    begin
        currentRdLineBuffer <= 0;
    end
    else
    begin
        if(rdCounter == 511 & rd_line_buffer)
            currentRdLineBuffer <= currentRdLineBuffer + 1;
    end
end

// Multiplexador de saída: concatena 3 linhas paralelas conforme a rotação circular dos buffers
always @(*)
begin
    case(currentRdLineBuffer)
        0:begin
            o_pixel_data = {lb2data,lb1data,lb0data};
        end
        1:begin
            o_pixel_data = {lb3data,lb2data,lb1data};
        end
        2:begin
            o_pixel_data = {lb0data,lb3data,lb2data};
        end
        3:begin
            o_pixel_data = {lb1data,lb0data,lb3data};
        end
    endcase
end

// Demultiplexador do sinal de leitura: ativa simultaneamente os 3 buffers necessários para a saída atual
always @(*)
begin
    case(currentRdLineBuffer)
        0:begin
            lineBuffRdData[0] = rd_line_buffer;
            lineBuffRdData[1] = rd_line_buffer;
            lineBuffRdData[2] = rd_line_buffer;
            lineBuffRdData[3] = 1'b0;
        end
       1:begin
            lineBuffRdData[0] = 1'b0;
            lineBuffRdData[1] = rd_line_buffer;
            lineBuffRdData[2] = rd_line_buffer;
            lineBuffRdData[3] = rd_line_buffer;
        end
       2:begin
             lineBuffRdData[0] = rd_line_buffer;
             lineBuffRdData[1] = 1'b0;
             lineBuffRdData[2] = rd_line_buffer;
             lineBuffRdData[3] = rd_line_buffer;
       end  
      3:begin
             lineBuffRdData[0] = rd_line_buffer;
             lineBuffRdData[1] = rd_line_buffer;
             lineBuffRdData[2] = 1'b0;
             lineBuffRdData[3] = rd_line_buffer;
       end        
    endcase
end
    
// Instâncias dos 4 Line Buffers
lineBuffer lB0(
    .i_clk(i_clk),
    .i_rst(i_rst),
    .i_data(i_pixel_data),
    .i_data_valid(lineBuffDataValid[0]),
    .o_data(lb0data),
    .i_rd_data(lineBuffRdData[0])
 ); 
 
 lineBuffer lB1(
     .i_clk(i_clk),
     .i_rst(i_rst),
     .i_data(i_pixel_data),
     .i_data_valid(lineBuffDataValid[1]),
     .o_data(lb1data),
     .i_rd_data(lineBuffRdData[1])
  ); 
  
  lineBuffer lB2(
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_data(i_pixel_data),
      .i_data_valid(lineBuffDataValid[2]),
      .o_data(lb2data),
      .i_rd_data(lineBuffRdData[2])
   ); 
   
   lineBuffer lB3(
       .i_clk(i_clk),
       .i_rst(i_rst),
       .i_data(i_pixel_data),
       .i_data_valid(lineBuffDataValid[3]),
       .o_data(lb3data),
       .i_rd_data(lineBuffRdData[3])
    );    
    
endmodule

