`timescale 1ns / 1ps


// APOS A SIMULACAO, RODAR NO TCL: run all


// Testbench for imageProcessTop using a binary PGM (P5) grayscale image.
//
// The PGM header has variable length (the GIMP comment line makes it
// 59 bytes for grayscale_landscape.pgm), so it is parsed instead of using
// a fixed size as for BMP (1080 bytes). The header is copied unchanged to
// the output file; after it come exactly WIDTH*HEIGHT bytes, one per pixel,
// top row first.

`define IMG_WIDTH  512
`define IMG_HEIGHT 512
`define imageSize  (`IMG_WIDTH*`IMG_HEIGHT)

module tb_imageProcess(

    );

 reg clk;
 reg reset;
 reg [7:0] imgData;
 integer file, file1, file2, i;
 reg imgDataValid;
 integer sentSize;
 wire intr;
 wire [7:0] outData;
 wire outDataValid;
 integer receivedData = 0;

 // Added for imageData.h
 integer pixel;

 // Header information read from the PGM file
 integer pgmWidth, pgmHeight, pgmMaxVal, headerBytes;

 initial
 begin
    clk = 1'b0;
    forever
    begin
        #5 clk = ~clk;
    end
 end

 // --------------------------------------------------------------------
 // Copies the PGM header from file to file1 and extracts its numbers.
 // Format: "P5" <ws> width <ws> height <ws> maxval <one ws> pixels...
 // Lines starting with '#' are comments. The loop stops right after the
 // single whitespace that follows maxval, i.e. at the first pixel byte.
 // --------------------------------------------------------------------
 task copy_pgm_header;
    integer c, token, inToken, inComment, value;
    begin
        token = 0;          // 0 = magic, 1 = width, 2 = height, 3 = maxval
        inToken = 0;
        inComment = 0;
        value = 0;
        headerBytes = 0;

        c = $fgetc(file);
        if (c != "P") begin
            $display("ERRO: arquivo nao comeca com 'P' (nao e PGM)");
            $finish;
        end
        $fwrite(file1, "%c", c[7:0]);
        headerBytes = 1;

        c = $fgetc(file);
        if (c != "5") begin
            $display("ERRO: PGM nao e binario (P5). Encontrado P%c", c[7:0]);
            $finish;
        end
        $fwrite(file1, "%c", c[7:0]);
        headerBytes = 2;
        inToken = 1;        // still inside the magic token "P5"

        while (token < 4)
        begin
            c = $fgetc(file);
            if (c == -1) begin
                $display("ERRO: fim de arquivo dentro do cabecalho");
                $finish;
            end
            $fwrite(file1, "%c", c[7:0]);
            headerBytes = headerBytes + 1;

            if (inComment) begin
                if (c == 8'h0A)
                    inComment = 0;
            end
            else if (c == "#") begin
                inComment = 1;
            end
            else if (c == " " || c == 8'h0A || c == 8'h0D || c == 8'h09) begin
                if (inToken) begin
                    if (token == 1) pgmWidth  = value;
                    if (token == 2) pgmHeight = value;
                    if (token == 3) pgmMaxVal = value;
                    token = token + 1;
                    inToken = 0;
                    value = 0;
                end
            end
            else begin
                inToken = 1;
                value = value * 10 + (c - "0");
            end
        end

        $display("PGM: %0d x %0d, maxval %0d, cabecalho de %0d bytes",
                 pgmWidth, pgmHeight, pgmMaxVal, headerBytes);

        if (pgmWidth != `IMG_WIDTH || pgmHeight != `IMG_HEIGHT) begin
            $display("ERRO: imagem %0dx%0d, o hardware espera %0dx%0d",
                     pgmWidth, pgmHeight, `IMG_WIDTH, `IMG_HEIGHT);
            $finish;
        end
        if (pgmMaxVal > 255) begin
            $display("ERRO: maxval > 255 usa 2 bytes por pixel");
            $finish;
        end
    end
 endtask

 initial
 begin
    reset = 0;
    sentSize = 0;
    imgDataValid = 0;
    imgData = 0;
    #100;
    reset = 1;
    #100;

    file = $fopen("grayscale_landscape.pgm", "rb");
    if (file == 0) begin
        $display("ERRO: nao foi possivel abrir grayscale_landscape.pgm");
        $finish;
    end
    file1 = $fopen("sobel_filter_image.pgm", "wb"); // blurred_grayscale_landscape
    if (file1 == 0) begin
        $display("ERRO: nao foi possivel criar sobel_filter_image.pgm"); //blurred_grayscale_landscape
        $finish;
    end

    // Added: create imageData.h
    file2 = $fopen("imageData.h", "w");
    if (file2 == 0) begin
        $display("ERRO: nao foi possivel criar imageData.h");
        $finish;
    end

    copy_pgm_header;
    $fflush(file1);   // header is on disk even if the simulation stops early

    // First 4 lines fill the line buffers
    for (i = 0; i < 4*`IMG_WIDTH; i = i + 1)
    begin
        @(posedge clk);

        pixel = $fgetc(file);
        imgData <= pixel;
        imgDataValid <= 1'b1;

        // Added: write input pixel to imageData.h
        $fwrite(file2, "%0d,", pixel);
    end
    sentSize = 4*`IMG_WIDTH;
    @(posedge clk);
    imgDataValid <= 1'b0;

    // One new line after every interrupt
    while (sentSize < `imageSize)
    begin
        @(posedge intr);
        for (i = 0; i < `IMG_WIDTH; i = i + 1)
        begin
            @(posedge clk);

            pixel = $fgetc(file);
            imgData <= pixel;
            imgDataValid <= 1'b1;

            // Added: write input pixel to imageData.h
            $fwrite(file2, "%0d,", pixel);
        end
        @(posedge clk);
        imgDataValid <= 1'b0;
        sentSize = sentSize + `IMG_WIDTH;
    end

    // Two dummy lines of zeros to flush the last output lines
    @(posedge clk);
    imgDataValid <= 1'b0;
    @(posedge intr);
    for (i = 0; i < `IMG_WIDTH; i = i + 1)
    begin
        @(posedge clk);
        imgData <= 0;
        imgDataValid <= 1'b1;

        // Added: write dummy zero to imageData.h
        $fwrite(file2, "%0d,", 0);
    end
    @(posedge clk);
    imgDataValid <= 1'b0;
    @(posedge intr);
    for (i = 0; i < `IMG_WIDTH; i = i + 1)
    begin
        @(posedge clk);
        imgData <= 0;
        imgDataValid <= 1'b1;

        // Added: write dummy zero to imageData.h
        $fwrite(file2, "%0d,", 0);
    end
    @(posedge clk);
    imgDataValid <= 1'b0;

    $fclose(file);

    // Added: close imageData.h
    $fclose(file2);
 end

 // --------------------------------------------------------------------
 // Watchdog: the full image needs about 5.3 ms of simulated time.
 // If the output is not complete after 20 ms (e.g. o_intr never arrives),
 // report the progress, close the output file and stop.
 // --------------------------------------------------------------------
 initial
 begin
    #20_000_000;
    $display("TIMEOUT: enviados %0d pixels, recebidos %0d de %0d",
             sentSize, receivedData, `imageSize);
    $fclose(file1);
    $fclose(file2);
    $stop;
 end

 // Progress report every 64 output lines
 always @(posedge clk)
 begin
     if (outDataValid && receivedData % (64*`IMG_WIDTH) == 0 && receivedData > 0)
         $display("Progresso: %0d de %0d linhas recebidas (t = %0t)",
                  receivedData / `IMG_WIDTH, `IMG_HEIGHT, $time);
 end

 always @(posedge clk)
 begin
     if (outDataValid)
     begin
         $fwrite(file1, "%c", outData);
         receivedData = receivedData + 1;
     end
     if (receivedData == `imageSize)
     begin
        $fclose(file1);
        $display("Imagem salva: %0d pixels + %0d bytes de cabecalho = %0d bytes",
                 receivedData, headerBytes, receivedData + headerBytes);
        $stop;
     end
 end

 imageProcessTop dut(
    .axi_clk(clk),
    .axi_reset_n(reset),
    //slave interface
    .i_data_valid(imgDataValid),
    .i_data(imgData),
    .o_data_ready(),
    //master interface
    .o_data_valid(outDataValid),
    .o_data(outData),
    .i_data_ready(1'b1),
    //interrupt
    .o_intr(intr)
);

endmodule