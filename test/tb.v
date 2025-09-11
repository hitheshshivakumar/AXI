`default_nettype none
`timescale 1ns / 1ps

/* This testbench just instantiates the module and makes some convenient wires
   that can be driven / tested by the cocotb test.py.
*/
`timescale 1ns/1ps
module tb;

    // DUT pins
    reg  [7:0] ui_in;
    wire [7:0] uo_out;
    reg  [7:0] uio_in;
    wire [7:0] uio_out;
    wire [7:0] uio_oe;
    reg        ena;
    reg        clk;
    reg        rst_n;

    // Instantiate the DUT (TinyTapeout top)
    tt_um_axi8_lite_proc dut (
        .ui_in (ui_in),
        .uo_out(uo_out),
        .uio_in(uio_in),
        .uio_out(uio_out),
        .uio_oe(uio_oe),
        .ena   (ena),
        .clk   (clk),
        .rst_n (rst_n)
    );

    // Clock: 100 MHz
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    // Helpers to access bits
    localparam AWREADY_IDX = 0;
    localparam WREADY_IDX  = 1;
    localparam BVALID_IDX  = 2;
    localparam ARREADY_IDX = 3;
    localparam RVALID_IDX  = 4;

    // Drive reset and run a basic write->read check
    reg [7:0] wbyte, exp_rbyte;

    initial begin
        // Init
        ena   = 1'b0;
        rst_n = 1'b0;
        ui_in = 8'h00;
        uio_in = 8'h00;

        // Bring up
        repeat (5) @(posedge clk);
        ena   = 1'b1;
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // --- WRITE: to address 0 (input reg) with byte 0x5A
        wbyte     = 8'h5A;
        exp_rbyte = ~wbyte;  // processing result

        // Set data on input bus
        uio_in    = wbyte;

        // ui_in map:
        // [0]=AWVALID, [1]=ARVALID, [2]=WVALID, [3]=RREADY, [4]=BREADY
        // [5]=ADDR(0/1), [6]=WSTRB, [7]=unused
        ui_in[5] = 1'b0; // ADDR=0
        ui_in[6] = 1'b1; // WSTRB=1
        ui_in[4] = 1'b1; // BREADY=1 (always ready)
        ui_in[3] = 1'b1; // RREADY=1 (always ready)
        ui_in[2] = 1'b1; // WVALID
        ui_in[0] = 1'b1; // AWVALID

        // Wait for AWREADY then drop AWVALID
        @(posedge clk);
        while (uo_out[AWREADY_IDX] == 1'b0) @(posedge clk);
        ui_in[0] = 1'b0; // drop AWVALID

        // Wait for WREADY then drop WVALID
        @(posedge clk);
        while (uo_out[WREADY_IDX] == 1'b0) @(posedge clk);
        ui_in[2] = 1'b0; // drop WVALID

        // Wait for BVALID handshake (BREADY already 1)
        @(posedge clk);
        while (uo_out[BVALID_IDX] == 1'b0) @(posedge clk);
        // one more cycle for response to be consumed
        @(posedge clk);

        // --- READ: from address 1 (output reg)
        ui_in[5] = 1'b1; // ADDR=1
        ui_in[1] = 1'b1; // ARVALID=1
        @(posedge clk);
        while (uo_out[ARREADY_IDX] == 1'b0) @(posedge clk);
        ui_in[1] = 1'b0; // drop ARVALID

        // Wait for RVALID, DUT will drive uio_out with result and set uio_oe=FF
        @(posedge clk);
        while (uo_out[RVALID_IDX] == 1'b0) @(posedge clk);

        if (uio_oe !== 8'hFF) begin
            $display("ERROR: Expected uio_oe=FF during RVALID, got %02X", uio_oe);
            $stop;
        end
        if (uio_out !== exp_rbyte) begin
            $display("ERROR: Read data mismatch. Got %02X, Expected %02X", uio_out, exp_rbyte);
            $stop;
        end else begin
            $display("PASS: Read data %02X matches expected %02X", uio_out, exp_rbyte);
        end

        // Finish
        repeat (5) @(posedge clk);
        $finish;
    end
endmodule
