`timescale 1ns/1ps

// ============================================================================
// Testbench for Top5_stage_Hazard_BranchPredictor.v
//
// Loads a small hand-assembled RV32I program that exercises:
//   - addi / add / sub / and / or / slt              (ALU + all forwarding paths)
//   - sw / lw                                          (memory + EX/MEM & MEM/WB forward)
//   - a load immediately followed by a dependent add   (load-use hazard / stall)
//   - a beq that is always taken, with a "wrong-path"
//     instruction right after it that must be squashed (branch misprediction flush)
//
// At the end it checks the architectural register file and data memory
// against a golden (hand-computed) result and reports PASS/FAIL.
//
// NOTE: Top has no reset port -- PC/BTB/BHT are reset via `initial` blocks
// inside the design itself, so none is driven here either.
// ============================================================================

module tb_Top5_stage_Hazard_BranchPredictor;

    reg CLK;
    wire [31:0] dbg_PCF, dbg_InstrD, dbg_ALUResultE, dbg_ALUResultM;
    wire [31:0] dbg_ReadDataW, dbg_ResultW;
    wire [4:0]  dbg_RdW;
    wire        dbg_RegWriteW;
    wire [7:0]  dbg_flags;

    integer pass_count;
    integer fail_count;
    integer cycle;

    // ------------------------------------------------------------------
    // DUT
    // ------------------------------------------------------------------
    Top dut (
        .CLK(CLK),
        .dbg_PCF(dbg_PCF),
        .dbg_InstrD(dbg_InstrD),
        .dbg_ALUResultE(dbg_ALUResultE),
        .dbg_ALUResultM(dbg_ALUResultM),
        .dbg_ReadDataW(dbg_ReadDataW),
        .dbg_ResultW(dbg_ResultW),
        .dbg_RdW(dbg_RdW),
        .dbg_RegWriteW(dbg_RegWriteW),
        .dbg_flags(dbg_flags)
    );

    // ------------------------------------------------------------------
    // Clock: 10 ns period
    // ------------------------------------------------------------------
    initial CLK = 1'b0;
    always #5 CLK = ~CLK;

    // ------------------------------------------------------------------
    // Program (machine code generated + cross-checked with a small Python
    // encoder/ISS, see the source instructions in the comments below)
    //
    //   addr   0: addi x1, x0, 5
    //   addr   4: addi x2, x0, 10
    //   addr   8: add  x3, x1, x2          -> 15
    //   addr  12: sub  x4, x2, x1          -> 5
    //   addr  16: and  x5, x1, x2          -> 0
    //   addr  20: or   x6, x1, x2          -> 15
    //   addr  24: slt  x7, x1, x2          -> 1
    //   addr  28: sw   x3, 0(x0)           -> mem[0] = 15
    //   addr  32: lw   x8, 0(x0)           -> 15
    //   addr  36: add  x9, x8, x1          -> 20  (load-use hazard: x8 not ready
    //                                                until one cycle after the lw)
    //   addr  40: beq  x1, x1, +8          -> always taken, target = addr 48
    //   addr  44: addi x10, x0, 99         -> WRONG PATH: must be squashed,
    //                                                x10 must stay 0
    //   addr  48: addi x11, x0, 111        -> branch target, -> 111
    //   addr  52..60: nop (addi x0,x0,0)   -> let the pipeline drain
    // ------------------------------------------------------------------
    initial begin
        dut.F.IM.memory[0]  = 32'h00500093; // addi x1,x0,5
        dut.F.IM.memory[1]  = 32'h00A00113; // addi x2,x0,10
        dut.F.IM.memory[2]  = 32'h002081B3; // add  x3,x1,x2
        dut.F.IM.memory[3]  = 32'h40110233; // sub  x4,x2,x1
        dut.F.IM.memory[4]  = 32'h0020F2B3; // and  x5,x1,x2
        dut.F.IM.memory[5]  = 32'h0020E333; // or   x6,x1,x2
        dut.F.IM.memory[6]  = 32'h0020A3B3; // slt  x7,x1,x2
        dut.F.IM.memory[7]  = 32'h00302023; // sw   x3,0(x0)
        dut.F.IM.memory[8]  = 32'h00002403; // lw   x8,0(x0)
        dut.F.IM.memory[9]  = 32'h001404B3; // add  x9,x8,x1
        dut.F.IM.memory[10] = 32'h00108463; // beq  x1,x1,8
        dut.F.IM.memory[11] = 32'h06300513; // addi x10,x0,99  (wrong path)
        dut.F.IM.memory[12] = 32'h06F00593; // addi x11,x0,111 (target)
        dut.F.IM.memory[13] = 32'h00000013; // nop
        dut.F.IM.memory[14] = 32'h00000013; // nop
        dut.F.IM.memory[15] = 32'h00000013; // nop

        // Data memory doesn't need pre-loading for this test (sw writes it).
    end

    // ------------------------------------------------------------------
    // Optional per-cycle trace - handy when a check fails and you need to
    // see what the pipeline actually did.
    // ------------------------------------------------------------------
    initial begin
        cycle = 0;
    end

    always @(posedge CLK) begin
        cycle = cycle + 1;
        $display("cyc=%0d PCF=%0d InstrD=%h ALUResultE=%h ALUResultM=%h WB(rd=%0d,we=%0b,val=%0d) flags(Branch,MemW,RegWM,ALUSrc,ResSrcM,Mispred,StallF,Taken)=%b",
                  cycle, dbg_PCF, dbg_InstrD, dbg_ALUResultE, dbg_ALUResultM,
                  dbg_RdW, dbg_RegWriteW, dbg_ResultW, dbg_flags);
    end

    // ------------------------------------------------------------------
    // Self-check task: compares the architectural register file
    // (hierarchical reference into Decode->RF) against an expected value.
    // ------------------------------------------------------------------
    task check_reg(input [4:0] idx, input [31:0] expected);
        reg [31:0] actual;
        begin
            actual = dut.D.RF.regfile[idx];
            if (actual === expected) begin
                $display("  PASS: x%0d = %0d (expected %0d)", idx, actual, expected);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL: x%0d = %0d (expected %0d)", idx, actual, expected);
                fail_count = fail_count + 1;
            end
        end
    endtask

    task check_mem(input [31:0] addr, input [31:0] expected);
        reg [31:0] actual;
        begin
            actual = dut.M.DM.memory[addr[9:2]];
            if (actual === expected) begin
                $display("  PASS: mem[%0d] = %0d (expected %0d)", addr, actual, expected);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL: mem[%0d] = %0d (expected %0d)", addr, actual, expected);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // ------------------------------------------------------------------
    // Main test sequence
    // ------------------------------------------------------------------
    initial begin
        pass_count = 0;
        fail_count = 0;

        // Run long enough for all 13 instructions plus the 3 trailing nops
        // to retire, including the load-use stall (+1 cyc) and the branch
        // misprediction flush (+2 cyc). 16 instructions * ~1 cyc + 5-stage
        // fill/drain + hazard penalties comfortably fits in 60 cycles.
        repeat (60) @(posedge CLK);
        #1; // settle after the last edge

        $display("\n================ RESULTS ================");
        check_reg(1, 32'd5);     // addi
        check_reg(2, 32'd10);    // addi
        check_reg(3, 32'd15);    // add
        check_reg(4, 32'd5);     // sub
        check_reg(5, 32'd0);     // and
        check_reg(6, 32'd15);    // or
        check_reg(7, 32'd1);     // slt
        check_reg(8, 32'd15);    // lw
        check_reg(9, 32'd20);    // add, depends on load-use stall working
        check_reg(10, 32'd0);    // MUST be 0: wrong-path instr after taken beq
        check_reg(11, 32'd111); // addi at branch target
        check_mem(0, 32'd15);    // sw result

        $display("===========================================");
        if (fail_count == 0)
            $display("ALL %0d CHECKS PASSED", pass_count);
        else
            $display("%0d PASSED, %0d FAILED", pass_count, fail_count);
        $display("===========================================\n");

        $finish;
    end

    // Safety timeout in case something hangs (e.g. permanent stall)
    initial begin
        #2000;
        $display("TIMEOUT: simulation did not finish in time");
        $finish;
    end

endmodule
