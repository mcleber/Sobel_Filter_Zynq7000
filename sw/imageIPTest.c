/*
 * imageIPTest.c
 *
 *  Created on: Apr 4, 2020
 *      Author: VIPIN
 *      Modified: CLEBER - Oct. 06. 2026
 */

#include "xaxidma.h"
#include "xparameters.h"
#include "sleep.h"
#include "xil_cache.h"
#include "xil_io.h"
#include "xscugic.h"
#include "imageData.h"
#include "xuartps.h"
#include "xil_printf.h"

#define IMAGEPROC_INTR_ID   61U   // IRQ_F2P[0] -> o_intr do imageProcess
#define DMA_S2MM_INTR_ID    62U   // IRQ_F2P[1] -> s2mm_introut do DMA

#define IMAGE_WIDTH         512
#define IMAGE_HEIGHT        512
#define IMAGE_SIZE          (IMAGE_WIDTH * IMAGE_HEIGHT)

#define UART_BAUDRATE       115200
#define UART_CHUNK_SIZE     1024

u32 checkIdle(u32 baseAddress, u32 offset);

XScuGic IntcInstance;

static void imageProcISR(void *CallBackRef);
static void dmaReceiveISR(void *CallBackRef);

volatile int done = 0;


int main()
{
    u32 status;

    u32 totalTransmittedBytes = 0;
    u32 transmittedBytes = 0;

    XUartPs_Config *myUartConfig;
    XUartPs myUart;

    XAxiDma_Config *myDmaConfig;
    XAxiDma myDma;

    XScuGic_Config *IntcConfig;


    /*
     * ------------------------------------------------------------
     * UART INITIALIZATION
     * ------------------------------------------------------------
     */

    xil_printf("\r\n");
    xil_printf("========================================\r\n");
    xil_printf("       imageIPTest START\r\n");
    xil_printf("========================================\r\n");

    myUartConfig = XUartPs_LookupConfig(XPAR_XUARTPS_0_BASEADDR);

    if (myUartConfig == NULL)
    {
        xil_printf("UART configuration not found!\r\n");
        return -1;
    }

    status = XUartPs_CfgInitialize(
        &myUart,
        myUartConfig,
        myUartConfig->BaseAddress
    );

    if (status != XST_SUCCESS)
    {
        xil_printf("UART initialization failed!\r\n");
        return -1;
    }

    status = XUartPs_SetBaudRate(
        &myUart,
        UART_BAUDRATE
    );

    if (status != XST_SUCCESS)
    {
        xil_printf("UART baudrate initialization failed!\r\n");
        return -1;
    }

    xil_printf("UART initialized: %d baud\r\n", UART_BAUDRATE);


    /*
     * ------------------------------------------------------------
     * DMA INITIALIZATION
     * ------------------------------------------------------------
     */

    xil_printf("Initializing DMA...\r\n");

    myDmaConfig = XAxiDma_LookupConfig(
        XPAR_AXI_DMA_0_BASEADDR
    );

    if (myDmaConfig == NULL)
    {
        xil_printf("DMA configuration not found!\r\n");
        return -1;
    }

    status = XAxiDma_CfgInitialize(
        &myDma,
        myDmaConfig
    );

    if (status != XST_SUCCESS)
    {
        xil_printf("DMA initialization failed!\r\n");
        return -1;
    }

    xil_printf("DMA initialized successfully.\r\n");


    /*
     * Enable S2MM interrupt.
     */
    XAxiDma_IntrEnable(
        &myDma,
        XAXIDMA_IRQ_IOC_MASK,
        XAXIDMA_DEVICE_TO_DMA
    );


    /*
     * ------------------------------------------------------------
     * INTERRUPT CONTROLLER INITIALIZATION
     * ------------------------------------------------------------
     */

    xil_printf("Initializing interrupt controller...\r\n");

    IntcConfig = XScuGic_LookupConfig(
        XPAR_XSCUGIC_0_BASEADDR
    );

    if (IntcConfig == NULL)
    {
        xil_printf("Interrupt controller configuration not found!\r\n");
        return -1;
    }

    status = XScuGic_CfgInitialize(
        &IntcInstance,
        IntcConfig,
        IntcConfig->CpuBaseAddress
    );

    if (status != XST_SUCCESS)
    {
        xil_printf("Interrupt controller initialization failed!\r\n");
        return -1;
    }

    xil_printf("Interrupt controller initialized.\r\n");


    /*
     * ------------------------------------------------------------
     * IMAGE PROCESSOR INTERRUPT
     * ------------------------------------------------------------
     */

    XScuGic_SetPriorityTriggerType(
        &IntcInstance,
        IMAGEPROC_INTR_ID,
        0xA0,
        3
    );

    status = XScuGic_Connect(
        &IntcInstance,
        IMAGEPROC_INTR_ID,
        (Xil_InterruptHandler)imageProcISR,
        (void *)&myDma
    );

    if (status != XST_SUCCESS)
    {
        xil_printf("Image processor interrupt connection failed!\r\n");
        return -1;
    }

    XScuGic_Enable(
        &IntcInstance,
        IMAGEPROC_INTR_ID
    );


    /*
     * ------------------------------------------------------------
     * DMA S2MM INTERRUPT
     * ------------------------------------------------------------
     */

    XScuGic_SetPriorityTriggerType(
        &IntcInstance,
        DMA_S2MM_INTR_ID,
        0xA1,
        3
    );

    status = XScuGic_Connect(
        &IntcInstance,
        DMA_S2MM_INTR_ID,
        (Xil_InterruptHandler)dmaReceiveISR,
        (void *)&myDma
    );

    if (status != XST_SUCCESS)
    {
        xil_printf("DMA S2MM interrupt connection failed!\r\n");
        return -1;
    }

    XScuGic_Enable(
        &IntcInstance,
        DMA_S2MM_INTR_ID
    );


    /*
     * ------------------------------------------------------------
     * ENABLE CPU INTERRUPTS
     * ------------------------------------------------------------
     */

    Xil_ExceptionInit();

    Xil_ExceptionRegisterHandler(
        XIL_EXCEPTION_ID_INT,
        (Xil_ExceptionHandler)XScuGic_InterruptHandler,
        (void *)&IntcInstance
    );

    Xil_ExceptionEnable();

    xil_printf("Interrupts enabled.\r\n");


    /*
     * ------------------------------------------------------------
     * START S2MM TRANSFER
     *
     * Receive the processed image from the hardware.
     * ------------------------------------------------------------
     */

    xil_printf("Starting S2MM transfer...\r\n");

    status = XAxiDma_SimpleTransfer(
        &myDma,
        (UINTPTR)imageData,
        IMAGE_SIZE,
        XAXIDMA_DEVICE_TO_DMA
    );

    if (status != XST_SUCCESS)
    {
        xil_printf("S2MM transfer failed: %d\r\n", status);
        return -1;
    }

    xil_printf("S2MM transfer started.\r\n");


    /*
     * ------------------------------------------------------------
     * START MM2S TRANSFER
     *
     * Send the first four image lines to the image processor.
     * ------------------------------------------------------------
     */

    xil_printf("Starting MM2S transfer...\r\n");

    status = XAxiDma_SimpleTransfer(
        &myDma,
        (UINTPTR)imageData,
        4 * IMAGE_WIDTH,
        XAXIDMA_DMA_TO_DEVICE
    );

    if (status != XST_SUCCESS)
    {
        xil_printf("MM2S transfer failed: %d\r\n", status);
        return -1;
    }

    xil_printf("MM2S transfer started.\r\n");


    /*
     * ------------------------------------------------------------
     * WAIT FOR IMAGE PROCESSING TO FINISH
     * ------------------------------------------------------------
     */

    xil_printf("Waiting for image processing...\r\n");

    while (!done)
    {
        /*
         * The DMA S2MM interrupt sets done = 1.
         */
    }

    xil_printf("Image processing completed.\r\n");


    /*
     * ------------------------------------------------------------
     * TRANSMIT IMAGE THROUGH UART
     *
     * imageData is a char[] containing one 8-bit grayscale
     * pixel per element.
     *
     * IMAGE_SIZE = 512 * 512 = 262144 bytes.
     * ------------------------------------------------------------
     */

    xil_printf("Starting image transmission...\r\n");
    xil_printf("Image size: %d bytes\r\n", IMAGE_SIZE);

    totalTransmittedBytes = 0;

    while (totalTransmittedBytes < IMAGE_SIZE)
    {
        u32 remainingBytes;
        u32 chunkSize;

        remainingBytes = IMAGE_SIZE - totalTransmittedBytes;

        if (remainingBytes > UART_CHUNK_SIZE)
        {
            chunkSize = UART_CHUNK_SIZE;
        }
        else
        {
            chunkSize = remainingBytes;
        }

        transmittedBytes = XUartPs_Send(
            &myUart,
            (u8 *)&imageData[totalTransmittedBytes],
            chunkSize
        );

        totalTransmittedBytes += transmittedBytes;
    }

    xil_printf("\r\n");
    xil_printf("Image transmission completed.\r\n");
    xil_printf("Total bytes transmitted: %d\r\n",
               totalTransmittedBytes);

    xil_printf("========================================\r\n");
    xil_printf("       imageIPTest FINISHED\r\n");
    xil_printf("========================================\r\n");


    return 0;
}


/*
 * ------------------------------------------------------------
 * Check whether the DMA channel is idle.
 * ------------------------------------------------------------
 */

u32 checkIdle(u32 baseAddress, u32 offset)
{
    u32 status;

    status = XAxiDma_ReadReg(
        baseAddress,
        offset
    ) & XAXIDMA_IDLE_MASK;

    return status;
}


/*
 * ------------------------------------------------------------
 * IMAGE PROCESSOR INTERRUPT SERVICE ROUTINE
 * ------------------------------------------------------------
 */

static void imageProcISR(void *CallBackRef)
{
    static int i = 4;

    int status;

    XScuGic_Disable(
        &IntcInstance,
        IMAGEPROC_INTR_ID
    );


    /*
     * Wait until the previous MM2S transfer becomes idle.
     */

    status = checkIdle(
        XPAR_AXI_DMA_0_BASEADDR,
        0x4
    );

    while (status == 0)
    {
        status = checkIdle(
            XPAR_AXI_DMA_0_BASEADDR,
            0x4
        );
    }


    /*
     * Send the next image line.
     */

    if (i < 514)
    {
        status = XAxiDma_SimpleTransfer(
            (XAxiDma *)CallBackRef,
            (UINTPTR)&imageData[i * IMAGE_WIDTH],
            IMAGE_WIDTH,
            XAXIDMA_DMA_TO_DEVICE
        );

        i++;
    }


    XScuGic_Enable(
        &IntcInstance,
        IMAGEPROC_INTR_ID
    );
}


/*
 * ------------------------------------------------------------
 * DMA S2MM INTERRUPT SERVICE ROUTINE
 * ------------------------------------------------------------
 */

static void dmaReceiveISR(void *CallBackRef)
{
    /*
     * Disable the S2MM interrupt while handling it.
     */

    XAxiDma_IntrDisable(
        (XAxiDma *)CallBackRef,
        XAXIDMA_IRQ_IOC_MASK,
        XAXIDMA_DEVICE_TO_DMA
    );


    /*
     * Acknowledge the interrupt.
     */

    XAxiDma_IntrAckIrq(
        (XAxiDma *)CallBackRef,
        XAXIDMA_IRQ_IOC_MASK,
        XAXIDMA_DEVICE_TO_DMA
    );


    /*
     * Image processing is finished.
     */

    done = 1;


    /*
     * Re-enable the S2MM interrupt.
     */

    XAxiDma_IntrEnable(
        (XAxiDma *)CallBackRef,
        XAXIDMA_IRQ_IOC_MASK,
        XAXIDMA_DEVICE_TO_DMA
    );
}