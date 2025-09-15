/*
 * Copyright (c) 2024 Your Name
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

// ------------------------------------------------------------
// TinyTapeout top-level wrapper + simplified AXI4-Lite 8-bit
// Processing: on write to address 0, reg_out <= ~WDATA
// Read from address 1 to get processed result.
// ------------------------------------------------------------

module tt_um_axi8_lite_proc (
    input  wire [7:0] ui_in,    // 8x dedicated inputs  (controls)
    output wire [7:0] uo_out,   // 8x dedicated outputs (status/debug)
    input  wire [7:0] uio_in,   // 8x IOs: input path   (data bus IN)
    output wire [7:0] uio_out,  // 8x IOs: output path  (data bus OUT)
    output wire [7:0] uio_oe,   // 8x IOs: output enable (1=drive)
    input  wire       ena,      // design enable
    input  wire       clk,      // clock
    input  wire       rst_n     // async reset, active low
);

    // Map TinyTapeout pins to simplified AXI-Lite signals (single-bit fields)
    wire        AWVALID = ui_in[0];
    wire        ARVALID = ui_in[1];
    wire        WVALID  = ui_in[2];
    wire        RREADY  = ui_in[3];
    wire        BREADY  = ui_in[4];
    wire [0:0]  ADDR    = { ui_in[5] };  // 1-bit address (0 or 1)
    wire        WSTRB   = ui_in[6];

    // Data bus: master drives uio_in -> WDATA
    wire [7:0] WDATA = uio_in;
    wire [7:0] RDATA;

    // AXI-lite slave internal signals (connected to instance)
    wire        AWREADY, WREADY, BVALID, ARREADY, RVALID;
    wire [1:0]  BRESP, RRESP;

    // Active-low reset from harness
    wire ARESETN = rst_n;

    // Instantiate the minimal AXI-Lite 8-bit slave (keeps your original implementation)
    tiny_axi_lite_8bit #(
        .ADDR_WIDTH(1),
        .DATA_WIDTH(8)
    ) dut_axi (
        .ACLK   (clk),
        .ARESETN(ARESETN),

        .AWADDR (ADDR),
        .AWVALID(AWVALID),
        .AWREADY(AWREADY),

        .WVALID (WVALID),
        .WREADY (WREADY),
        .WDATA  (WDATA),
        .WSTRB  ({WSTRB}),

        .BVALID (BVALID),
        .BREADY (BREADY),
        .BRESP  (BRESP),

        .ARADDR (ADDR),
        .ARVALID(ARVALID),
        .ARREADY(ARREADY),

        .RVALID (RVALID),
        .RREADY (RREADY),
        .RDATA  (RDATA),
        .RRESP  (RRESP)
    );

    // Drive the bidirectional IOs only when enabled and during read-data valid
    wire drive_read_bus = ena & RVALID;

    assign uio_out = drive_read_bus ? RDATA : 8'h00;
    assign uio_oe  = drive_read_bus ? 8'hFF  : 8'h00;

    // Heartbeat for quick bring-up (divided clock)
    reg [23:0] hb;
    always @(posedge clk or negedge ARESETN) begin
        if (!ARESETN) hb <= 24'd0;
        else          hb <= hb + 24'd1;
    end

    // Outputs masked by ena (best practice for TinyTapeout)
    // Map status signals into uo_out for debug/observability
    assign uo_out[0] = ena ? AWREADY      : 1'b0;
    assign uo_out[1] = ena ? WREADY       : 1'b0;
    assign uo_out[2] = ena ? BVALID       : 1'b0;
    assign uo_out[3] = ena ? ARREADY      : 1'b0;
    assign uo_out[4] = ena ? RVALID       : 1'b0;
    assign uo_out[5] = ena ? RDATA[0]     : 1'b0; // debug: LSB of processed data
    assign uo_out[6] = 1'b0;
    assign uo_out[7] = ena ? hb[23]       : 1'b0; // slow heartbeat

endmodule


// ------------------------------------------------------------
// Simplified AXI4-Lite 8-bit slave (single-beat, 2 registers)
//   - Address 0 (write): reg_in <= WDATA; reg_out <= ~WDATA
//   - Address 1 (read):  RDATA  <= reg_out
// BRESP/RRESP are always OKAY (2'b00).
// ------------------------------------------------------------
module tiny_axi_lite_8bit #(
    parameter ADDR_WIDTH = 1,  // two locations: 0 and 1
    parameter DATA_WIDTH = 8
)(
    input  wire                     ACLK,
    input  wire                     ARESETN,

    // Write address
    input  wire [ADDR_WIDTH-1:0]    AWADDR,
    input  wire                     AWVALID,
    output reg                      AWREADY,

    // Write data
    input  wire                     WVALID,
    output reg                      WREADY,
    input  wire [DATA_WIDTH-1:0]    WDATA,
    input  wire [(DATA_WIDTH/8)-1:0] WSTRB,

    // Write response
    output reg                      BVALID,
    input  wire                     BREADY,
    output wire [1:0]               BRESP,

    // Read address
    input  wire [ADDR_WIDTH-1:0]    ARADDR,
    input  wire                     ARVALID,
    output reg                      ARREADY,

    // Read data
    output reg                      RVALID,
    input  wire                     RREADY,
    output reg  [DATA_WIDTH-1:0]    RDATA,
    output wire [1:0]               RRESP
);
    // Fixed OKAY responses
    assign BRESP = 2'b00;
    assign RRESP = 2'b00;

    // Internal registers
    reg [DATA_WIDTH-1:0] reg_in;
    reg [DATA_WIDTH-1:0] reg_out;

    // Write FSM
    localparam WIDLE  = 2'd0,
               WDATA_S = 2'd1,
               WRESP  = 2'd2;
    reg [1:0] wstate;
    reg       awaddr_q;

    // Read FSM
    localparam RIDLE  = 1'b0,
               RDATA_S = 1'b1;
    reg       rstate;
    reg       araddr_q;

    // Combinational handshakes (combinationally drive ready/valid)
    always @(*) begin
        AWREADY = (wstate == WIDLE);
        WREADY  = (wstate == WDATA_S);
        BVALID  = (wstate == WRESP);

        ARREADY = (rstate == RIDLE);
        RVALID  = (rstate == RDATA_S);
    end

    // Write channel (sequential)
    always @(posedge ACLK or negedge ARESETN) begin
        if (!ARESETN) begin
            wstate   <= WIDLE;
            awaddr_q <= 1'b0;
            reg_in   <= {DATA_WIDTH{1'b0}};
            reg_out  <= {DATA_WIDTH{1'b0}};
        end else begin
            case (wstate)
                WIDLE: begin
                    if (AWVALID) begin
                        awaddr_q <= AWADDR[0];
                        wstate   <= WDATA_S;
                    end
                end
                WDATA_S: begin
                    if (WVALID) begin
                        if (WSTRB[0]) begin
                            if (awaddr_q == 1'b0) begin
                                reg_in  <= WDATA;
                                reg_out <= ~WDATA;      // processing: invert
                            end else begin
                                reg_out <= WDATA;       // optional write to out reg
                            end
                        end
                        wstate <= WRESP;
                    end
                end
                WRESP: begin
                    if (BVALID && BREADY) begin
                        wstate <= WIDLE;
                    end
                end
            endcase
        end
    end

    // Provide BVALID behavior (simple single-cycle handshake)
    // BVALID is already set combinationally above; ensure BVALID clears when accepted
    always @(posedge ACLK or negedge ARESETN) begin
        if (!ARESETN) begin
            // nothing else needed; combinational logic handles BVALID
        end else begin
            // When in WRESP state and BREADY is seen, wstate transitions above clear BVALID
        end
    end

    // Read channel (sequential)
    always @(posedge ACLK or negedge ARESETN) begin
        if (!ARESETN) begin
            rstate   <= RIDLE;
            araddr_q <= 1'b0;
            RDATA    <= {DATA_WIDTH{1'b0}};
        end else begin
            case (rstate)
                RIDLE: begin
                    if (ARVALID) begin
                        araddr_q <= ARADDR[0];
                        RDATA    <= (ARADDR[0] == 1'b0) ? reg_in : reg_out;
                        rstate   <= RDATA_S;
                    end
                end
                RDATA_S: begin
                    if (RVALID && RREADY) begin
                        rstate <= RIDLE;
                    end
                end
            endcase
        end
    end

endmodule

`default_nettype wire
