// Load/store alignment logic (purely combinational).
//  - store side: byte-enable mask and lane-shifted write data for SB/SH/SW
//  - load side:  select the byte/halfword lane from the 32-bit read word and sign/zero extend
//  - misaligned: halfword at an odd address, word not 4-byte aligned
module lsu (
  input  logic [2:0]  funct3,     // size in [1:0] (0=byte,1=half,2=word), unsigned in [2]
  input  logic [31:0] addr,
  input  logic [31:0] store_data, // rs2
  input  logic [31:0] load_word,  // aligned 32-bit word read from memory
  output logic [3:0]  wstrb,      // byte enables for a store (before gating by mem_we)
  output logic [31:0] wdata,
  output logic [31:0] load_data,  // extended load result
  output logic        misaligned
);
  logic [1:0] off;
  assign off = addr[1:0];

  always_comb begin
    unique case (funct3[1:0])
      2'b00:   misaligned = 1'b0;
      2'b01:   misaligned = off[0];
      default: misaligned = (off != 2'b00);
    endcase
  end

  // Stores: replicate the low bytes across lanes, enable only the addressed lane(s).
  always_comb begin
    unique case (funct3[1:0])
      2'b00: begin
        wdata = {4{store_data[7:0]}};
        wstrb = 4'b0001 << off;
      end
      2'b01: begin
        wdata = {2{store_data[15:0]}};
        wstrb = off[1] ? 4'b1100 : 4'b0011;
      end
      default: begin
        wdata = store_data;
        wstrb = 4'b1111;
      end
    endcase
  end

  // Loads: shift the addressed lane down, then extend.
  logic [31:0] shifted;
  assign shifted = load_word >> {off, 3'b000};
  always_comb begin
    unique case (funct3)
      3'b000:  load_data = {{24{shifted[7]}}, shifted[7:0]};    // LB
      3'b001:  load_data = {{16{shifted[15]}}, shifted[15:0]};  // LH
      3'b100:  load_data = {24'b0, shifted[7:0]};               // LBU
      3'b101:  load_data = {16'b0, shifted[15:0]};              // LHU
      default: load_data = load_word;                           // LW
    endcase
  end
endmodule
