### Estrutura de diretórios para o projeto

O maior perigo com Vivado/Vitis é misturar **o que você escreveu** (precioso, pequeno) com **o que as ferramentas geram** (gigante, regenerável, e que quebra quando você move de pasta). A estrutura abaixo separa isso desde o dia 1:

```
sobel-zynq/
├── README.md                  # anotações do que funciona, versões usadas
├── docs/
│   ├── tutorial_axi_sobel.md  # os 3 tutoriais
│   ├── adendo_hdmi_sobel.md
│   └── adendo2_sobel.md
│
├── hls/                       # ---- Vitis HLS ----
│   ├── src/
│   │   ├── sobel.cpp
│   │   ├── sobel.h
│   │   └── sobel_tb.cpp
│   └── proj/                  # projeto HLS gerado (descartável)
│
├── hw/                        # ---- Vivado ----
│   ├── hdl/                   # SEU RTL: dvi_transmitter_top.v,
│   │   └── ...                # dvi_encoder.v, serializer, top.v (B.1)...
│   ├── xdc/
│   │   └── pinos.xdc          # constraints TMDS etc.
│   ├── ip_repo/               # IP exportado do HLS (o .zip extraído)
│   ├── bd/                    # design_1.tcl exportado (leia abaixo!)
│   └── proj/                  # projeto Vivado gerado (descartável)
│
├── sw/                        # ---- Vitis ----
│   ├── src/
│   │   ├── main.c
│   │   ├── benchmark.c        # B.4
│   │   └── interrupts.c       # B.2
│   ├── xsa/                   # os .xsa exportados, com nome versionado:
│   │   ├── sobel_v1_dma.xsa
│   │   └── sobel_v2_hdmi.xsa
│   └── workspace/             # workspace Vitis gerado (descartável)
│
└── images/                    # imagens de teste e resultados capturados
```

Três hábitos que vão te salvar horas:

**1. Trate `proj/` e `workspace/` como descartáveis.** O que define seu hardware não é o projeto Vivado — são os fontes + o block design. Para o block design (que é binário/XML feio), exporte a "receita" em Tcl: com o BD aberto, `File → Export → Export Block Design` gera um `design_1.tcl` que recria o diagrama inteiro do zero. Salve em `hw/bd/` a cada marco. É seu backup de verdade.

**2. Use git com uma tag por marco, não pastas duplicadas.** Em vez de `projeto_v1/`, `projeto_v2_final/`, `projeto_v2_final_AGORA_VAI/`, faça:

```
git tag v1-tutorial      # DMA+Sobel funcionando
git tag v2-adendo1-vdma  # HDMI via VDMA
git tag v3-b2-irq        # interrupções
```

Com um `.gitignore` cortando o lixo gerado (`hw/proj/`, `sw/workspace/`, `hls/proj/`, `*.jou`, `*.log`, `*.str`, `.Xil/`), o repositório fica com uns poucos KB — só o que importa. E como Adendo 1 e B.1 são block designs alternativos, eles viram **branches**: `git checkout v2-adendo1-vdma` te devolve o estado exato daquele marco. Isso implementa na prática a regra de ouro que combinamos: sempre ter um estado funcionando para voltar.

**3. Um detalhe chato do Vivado:** evite espaços e acentos em qualquer caminho (`C:/Users/João Silva/Meus Projetos/` = dor). Use caminhos curtos tipo `C:/fpga/sobel-zynq/` ou `~/fpga/sobel-zynq/`.
