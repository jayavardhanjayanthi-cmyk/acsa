
module ALU (
    input wire [31:0] SrcA, SrcB,
    input wire [2:0] ALUControl,
    output reg [31:0] ALUResult,
    output wire Zero
);
always @(*) begin
    case (ALUControl)
        3'b000: ALUResult = SrcA + SrcB;
        3'b001: ALUResult = SrcA - SrcB;
        3'b010: ALUResult = SrcA & SrcB;
        3'b011: ALUResult = SrcA | SrcB;
        3'b101: ALUResult = ($signed(SrcA) < $signed(SrcB)) ? 32'd1 : 32'd0;
        default: ALUResult = 32'd0;
    endcase
end
assign Zero = (ALUResult == 32'd0);
endmodule

module ALUDecoder (
    input wire [1:0] ALUOp,
    input wire [2:0] funct3,
    input wire opb5, funct7b5,
    output reg [2:0] ALUControl
);
always @(*) begin
    case (ALUOp)
        2'b00: ALUControl = 3'b000;
        2'b01: ALUControl = 3'b001;
        2'b10: begin
            case (funct3)
                3'b010: ALUControl = 3'b101;
                3'b110: ALUControl = 3'b011;
                3'b111: ALUControl = 3'b010;
                3'b000: ALUControl = (opb5 && funct7b5) ? 3'b001 : 3'b000;
                default: ALUControl = 3'b000;
            endcase
        end
        default: ALUControl = 3'b000;
    endcase
end
endmodule

module MainDecoder (
    input wire [6:0] op,
    output reg Branch, ResultSrc, MemWrite, ALUSrc,
    output reg [1:0] ImmSrc,
    output reg RegWrite,
    output reg [1:0] ALUOp
);
always @(*) begin
    Branch=0; ResultSrc=0; MemWrite=0; ALUSrc=0;
    ImmSrc=2'b00; RegWrite=0; ALUOp=2'b00;
    case(op)
        7'b0000011: begin RegWrite=1; ALUSrc=1; ResultSrc=1; ImmSrc=2'b00; end // lw
        7'b0100011: begin MemWrite=1; ALUSrc=1; ImmSrc=2'b01; end             // sw
        7'b0110011: begin RegWrite=1; ALUOp=2'b10; end                       // R
        7'b1100011: begin Branch=1; ALUOp=2'b01; ImmSrc=2'b10; end           // beq
        7'b0010011: begin RegWrite=1; ALUSrc=1; ALUOp=2'b10; ImmSrc=2'b00; end// I ALU
        default: ;
    endcase
end
endmodule

module CU (
    input wire [6:0] op,
    input wire [2:0] funct3,
    input wire funct7b5,
    output wire ResultSrc, MemWrite, ALUSrc, RegWrite, Branch,
    output wire [1:0] ImmSrc,
    output wire [2:0] ALUControl
);
wire [1:0] ALUOp;
MainDecoder md(.op(op),.Branch(Branch),.ResultSrc(ResultSrc),.MemWrite(MemWrite),
               .ALUSrc(ALUSrc),.ImmSrc(ImmSrc),.RegWrite(RegWrite),.ALUOp(ALUOp));
ALUDecoder ad(.ALUOp(ALUOp),.funct3(funct3),.opb5(op[5]),.funct7b5(funct7b5),
              .ALUControl(ALUControl));
endmodule

module Extend (
    input wire [31:7] Instr,
    input wire [1:0] ImmSrc,
    output reg [31:0] ImmExt
);
always @(*) begin
    case(ImmSrc)
        2'b00: ImmExt = {{20{Instr[31]}},Instr[31:20]};
        2'b01: ImmExt = {{20{Instr[31]}},Instr[31:25],Instr[11:7]};
        2'b10: ImmExt = {{19{Instr[31]}},Instr[31],Instr[7],Instr[30:25],Instr[11:8],1'b0};
        default: ImmExt = 32'd0;
    endcase
end
endmodule

module RegisterFile (
    input wire CLK,
    input wire [4:0] A1,A2,A3,
    input wire [31:0] WD3,
    input wire WE3,
    output wire [31:0] RD1,RD2
);
reg [31:0] regfile [0:31];
assign RD1 = (A1==0) ? 32'd0 : regfile[A1];
assign RD2 = (A2==0) ? 32'd0 : regfile[A2];
always @(negedge CLK) begin
    if (WE3 && (A3 != 0)) regfile[A3] <= WD3;
end
endmodule

module InstructionMemory (
    input wire [31:0] A,
    output wire [31:0] RD
);
reg [31:0] memory [0:255];
assign RD = memory[A[9:2]];
endmodule

module DataMemory (
    input wire CLK, WE,
    input wire [31:0] A, WD,
    output wire [31:0] RD
);
reg [31:0] memory [0:255];
assign RD = memory[A[9:2]];
always @(posedge CLK)
    if (WE) memory[A[9:2]] <= WD;
endmodule

module ProgramCounter (
    input wire CLK,
    input wire [31:0] PCNext,
    output reg [31:0] PC
);
initial PC = 32'd0;
always @(posedge CLK) PC <= PCNext;
endmodule

// 256-entry BTB + 256-entry 2-bit BHT.
// BHT state: 00 SN, 01 WN, 10 WT, 11 ST.
module BranchPredictor (
    input wire CLK,
    input wire [31:0] PCF,
    output wire PredTakenF,
    output wire [31:0] PredTargetF,
    output wire BTBHitF,

    input wire UpdateE,
    input wire ActualTakenE,
    input wire [31:0] BranchPCE,
    input wire [31:0] ActualTargetE
);
reg btb_valid [0:255];
reg [21:0] btb_tag [0:255];
reg [31:0] btb_target [0:255];
reg [1:0] bht [0:255];

wire [7:0] idxF = PCF[9:2];
wire [21:0] tagF = PCF[31:10];
wire hitF = btb_valid[idxF] && (btb_tag[idxF] == tagF);

assign BTBHitF = hitF;
assign PredTargetF = btb_target[idxF];
assign PredTakenF = hitF && bht[idxF][1];

integer i;
initial begin
    for(i=0;i<256;i=i+1) begin
        btb_valid[i] = 1'b0;
        btb_tag[i] = 22'd0;
        btb_target[i] = 32'd0;
        bht[i] = 2'b01; // weakly not taken
    end
end

wire [7:0] idxE = BranchPCE[9:2];

always @(posedge CLK) begin
    if (UpdateE) begin
        btb_valid[idxE] <= 1'b1;
        btb_tag[idxE] <= BranchPCE[31:10];
        btb_target[idxE] <= ActualTargetE;

        if (ActualTakenE) begin
            if (bht[idxE] != 2'b11) bht[idxE] <= bht[idxE] + 2'b01;
        end else begin
            if (bht[idxE] != 2'b00) bht[idxE] <= bht[idxE] - 2'b01;
        end
    end
end
endmodule

module Fetch (
    input wire CLK,
    input wire StallF,
    input wire MispredictE,
    input wire [31:0] CorrectPC_E,

    input wire BranchUpdateE,
    input wire ActualTakenE,
    input wire [31:0] BranchPCE,
    input wire [31:0] ActualTargetE,

    output wire [31:0] RD,
    output wire [31:0] PCF,
    output wire [31:0] PCPlus4F,
    output wire PredTakenF,
    output wire [31:0] PredTargetF,
    output wire BTBHitF
);
wire [31:0] PCNextNormal;
wire [31:0] PCNext;

BranchPredictor BP(
    .CLK(CLK),
    .PCF(PCF),
    .PredTakenF(PredTakenF),
    .PredTargetF(PredTargetF),
    .BTBHitF(BTBHitF),
    .UpdateE(BranchUpdateE),
    .ActualTakenE(ActualTakenE),
    .BranchPCE(BranchPCE),
    .ActualTargetE(ActualTargetE)
);

assign PCPlus4F = PCF + 32'd4;
assign PCNextNormal = PredTakenF ? PredTargetF : PCPlus4F;
assign PCNext = MispredictE ? CorrectPC_E :
                StallF ? PCF :
                PCNextNormal;

ProgramCounter PC(.CLK(CLK),.PCNext(PCNext),.PC(PCF));
InstructionMemory IM(.A(PCF),.RD(RD));
endmodule

module IF_ID (
    input wire CLK,
    input wire StallD,
    input wire FlushD,
    input wire [31:0] RD, PCF, PCPlus4F,
    input wire PredTakenF,
    input wire [31:0] PredTargetF,
    input wire BTBHitF,
    output reg [31:0] InstrD, PCD, PCPlus4D,
    output reg PredTakenD,
    output reg [31:0] PredTargetD,
    output reg BTBHitD
);
always @(posedge CLK) begin
    if (FlushD) begin
        InstrD <= 32'd0;
        PCD <= 32'd0;
        PCPlus4D <= 32'd0;
        PredTakenD <= 1'b0;
        PredTargetD <= 32'd0;
        BTBHitD <= 1'b0;
    end else if (!StallD) begin
        InstrD <= RD;
        PCD <= PCF;
        PCPlus4D <= PCPlus4F;
        PredTakenD <= PredTakenF;
        PredTargetD <= PredTargetF;
        BTBHitD <= BTBHitF;
    end
end
endmodule

module Decode (
    input wire CLK,
    input wire [31:0] InstrD, PCD, PCPlus4D,
    input wire RegWriteW,
    input wire [4:0] RdW,
    input wire [31:0] ResultW,
    output wire RegWriteD, ResultSrcD, MemWriteD, BranchD, ALUSrcD,
    output wire [2:0] ALUControlD,
    output wire [31:0] Pass_PCD, Pass_PCPlus4D, RD1D, RD2D, ImmExtD,
    output wire [4:0] RdD,
    output wire [4:0] Rs1D, Rs2D
);
wire [1:0] ImmSrcD;
CU cu(.op(InstrD[6:0]),.funct3(InstrD[14:12]),.funct7b5(InstrD[30]),
      .ResultSrc(ResultSrcD),.MemWrite(MemWriteD),.ALUSrc(ALUSrcD),
      .ImmSrc(ImmSrcD),.RegWrite(RegWriteD),.ALUControl(ALUControlD),
      .Branch(BranchD));
RegisterFile RF(.CLK(CLK),.A1(InstrD[19:15]),.A2(InstrD[24:20]),.A3(RdW),
                .WD3(ResultW),.WE3(RegWriteW),.RD1(RD1D),.RD2(RD2D));
Extend ex(.Instr(InstrD[31:7]),.ImmSrc(ImmSrcD),.ImmExt(ImmExtD));
assign RdD = InstrD[11:7];
assign Rs1D = InstrD[19:15];
assign Rs2D = InstrD[24:20];
assign Pass_PCD = PCD;
assign Pass_PCPlus4D = PCPlus4D;
endmodule

module ID_EX (
    input wire CLK, input wire FlushE,
    input wire RegWriteD,ResultSrcD,MemWriteD,BranchD,ALUSrcD,
    input wire [2:0] ALUControlD,
    input wire [31:0] Pass_PCD,Pass_PCPlus4D,RD1D,RD2D,ImmExtD,
    input wire [4:0] RdD,Rs1D,Rs2D,
    input wire PredTakenD,BTBHitD,
    input wire [31:0] PredTargetD,
    output reg RegWriteE,ResultSrcE,MemWriteE,BranchE,ALUSrcE,
    output reg [2:0] ALUControlE,
    output reg [31:0] PCE,PCPlus4E,RD1E,RD2E,ImmExtE,
    output reg [4:0] RdE,Rs1E,Rs2E,
    output reg PredTakenE,BTBE,
    output reg [31:0] PredTargetE
);
always @(posedge CLK) begin
    if (FlushE) begin
        RegWriteE<=0; ResultSrcE<=0; MemWriteE<=0; BranchE<=0;
        ALUSrcE<=0; ALUControlE<=0;
        PCE<=0; PCPlus4E<=0; RD1E<=0; RD2E<=0; ImmExtE<=0;
        RdE<=0; Rs1E<=0; Rs2E<=0;
        PredTakenE<=0; BTBE<=0; PredTargetE<=0;
    end else begin
        RegWriteE<=RegWriteD; ResultSrcE<=ResultSrcD; MemWriteE<=MemWriteD;
        BranchE<=BranchD; ALUSrcE<=ALUSrcD; ALUControlE<=ALUControlD;
        PCE<=Pass_PCD; PCPlus4E<=Pass_PCPlus4D; RD1E<=RD1D; RD2E<=RD2D;
        ImmExtE<=ImmExtD; RdE<=RdD; Rs1E<=Rs1D; Rs2E<=Rs2D;
        PredTakenE<=PredTakenD; BTBE<=BTBHitD; PredTargetE<=PredTargetD;
    end
end
endmodule

module ForwardingUnit (
    input wire RegWriteM, RegWriteW,
    input wire [4:0] RdM, RdW,
    input wire [4:0] Rs1E, Rs2E,
    output reg [1:0] ForwardAE, ForwardBE
);
always @(*) begin
    ForwardAE=2'b00;
    ForwardBE=2'b00;
    if (RegWriteM && (RdM!=0) && (RdM==Rs1E)) ForwardAE=2'b10;
    else if (RegWriteW && (RdW!=0) && (RdW==Rs1E)) ForwardAE=2'b01;
    if (RegWriteM && (RdM!=0) && (RdM==Rs2E)) ForwardBE=2'b10;
    else if (RegWriteW && (RdW!=0) && (RdW==Rs2E)) ForwardBE=2'b01;
end
endmodule


module Execute (
    input wire RegWriteE,ResultSrcE,MemWriteE,BranchE,ALUSrcE,
    input wire [2:0] ALUControlE,
    input wire [31:0] PCE,PCPlus4E,RD1E,RD2E,ImmExtE,
    input wire [4:0] RdE,Rs1E,Rs2E,

    input wire RegWriteM,ResultSrcM,
    input wire [4:0] RdM,
    input wire [31:0] ALUResultM,
    input wire [31:0] ForwardMValue,
    input wire RegWriteW,
    input wire [4:0] RdW,
    input wire [31:0] ResultW,

    input wire PredTakenE,BTBE,
    input wire [31:0] PredTargetE,

    output wire Pass_RegWriteE,Pass_ResultSrcE,Pass_MemWriteE,
    output wire [31:0] ALUResultE,WriteDataE,PCTargetE,
    output wire [4:0] Pass_RdE,
    output wire [31:0] Pass_PCPlus4E,
    output wire ActualTakenE,
    output wire MispredictE,
    output wire [31:0] CorrectPC_E
);
wire [1:0] ForwardAE,ForwardBE;
wire [31:0] SrcAE,ForwardedB,SrcBE;
wire ZeroE;

ForwardingUnit FU(
    .RegWriteM(RegWriteM),.RegWriteW(RegWriteW),
    .RdM(RdM),.RdW(RdW),
    .Rs1E(Rs1E),.Rs2E(Rs2E),
    .ForwardAE(ForwardAE),.ForwardBE(ForwardBE)
);

assign SrcAE = (ForwardAE==2'b10) ? ForwardMValue :
               (ForwardAE==2'b01) ? ResultW : RD1E;
assign ForwardedB = (ForwardBE==2'b10) ? ForwardMValue :
                    (ForwardBE==2'b01) ? ResultW : RD2E;
assign SrcBE = ALUSrcE ? ImmExtE : ForwardedB;

ALU alu(.SrcA(SrcAE),.SrcB(SrcBE),.ALUControl(ALUControlE),
        .ALUResult(ALUResultE),.Zero(ZeroE));

assign PCTargetE = PCE + ImmExtE;
assign ActualTakenE = BranchE && ZeroE;

// A prediction is correct if taken/not-taken agrees and, when taken,
// the predicted target is the actual target.
assign MispredictE = BranchE &&
                     ((PredTakenE != ActualTakenE) ||
                      (ActualTakenE && (PredTargetE != PCTargetE)));

assign CorrectPC_E = ActualTakenE ? PCTargetE : PCPlus4E;

assign WriteDataE = ForwardedB; // important for SW after a dependent ALU instruction
assign Pass_RdE = RdE;
assign Pass_PCPlus4E = PCPlus4E;
assign Pass_RegWriteE = RegWriteE;
assign Pass_ResultSrcE = ResultSrcE;
assign Pass_MemWriteE = MemWriteE;
endmodule

module EX_MEM (
    input wire CLK,
    input wire Pass_RegWriteE,Pass_ResultSrcE,Pass_MemWriteE,
    input wire [31:0] ALUResultE,WriteDataE,
    input wire [4:0] Pass_RdE,
    input wire [31:0] Pass_PCPlus4E,
    output reg RegWriteM,ResultSrcM,MemWriteM,
    output reg [31:0] ALUResultM,WriteDataM,
    output reg [4:0] RdM,
    output reg [31:0] PCPlus4M
);
always @(posedge CLK) begin
    RegWriteM<=Pass_RegWriteE; ResultSrcM<=Pass_ResultSrcE; MemWriteM<=Pass_MemWriteE;
    ALUResultM<=ALUResultE; WriteDataM<=WriteDataE; RdM<=Pass_RdE; PCPlus4M<=Pass_PCPlus4E;
end
endmodule

module Memory (
    input wire CLK,RegWriteM,ResultSrcM,MemWriteM,
    input wire [31:0] ALUResultM,WriteDataM,
    input wire [4:0] RdM,
    input wire [31:0] PCPlus4M,
    output wire Pass_RegWriteM,Pass_ResultSrcM,
    output wire [31:0] Pass_ALUResultM,RD,
    output wire [4:0] Pass_RdM,
    output wire [31:0] Pass_PCPlus4M
);
DataMemory DM(.CLK(CLK),.WE(MemWriteM),.A(ALUResultM),.WD(WriteDataM),.RD(RD));
assign Pass_RegWriteM=RegWriteM;
assign Pass_ResultSrcM=ResultSrcM;
assign Pass_ALUResultM=ALUResultM;
assign Pass_RdM=RdM;
assign Pass_PCPlus4M=PCPlus4M;
endmodule

module MEM_WB (
    input wire CLK,
    input wire Pass_RegWriteM,Pass_ResultSrcM,
    input wire [31:0] Pass_ALUResultM,RD,
    input wire [4:0] Pass_RdM,
    input wire [31:0] Pass_PCPlus4M,
    output reg RegWriteW,ResultSrcW,
    output reg [31:0] ALUResultW,ReadDataW,
    output reg [4:0] RdW,
    output reg [31:0] PCPlus4W
);
always @(posedge CLK) begin
    RegWriteW<=Pass_RegWriteM; ResultSrcW<=Pass_ResultSrcM;
    ALUResultW<=Pass_ALUResultM; ReadDataW<=RD; RdW<=Pass_RdM; PCPlus4W<=Pass_PCPlus4M;
end
endmodule

module ResultSrcMux (
    input wire ResultSrc,
    input wire [31:0] ALUResult,RD,
    output wire [31:0] Result
);
assign Result = ResultSrc ? RD : ALUResult;
endmodule

module WriteBack (
    input wire RegWriteW,ResultSrcW,
    input wire [31:0] ALUResultW,ReadDataW,
    input wire [4:0] RdW,
    input wire [31:0] PCPlus4W,
    output wire Pass_RegWriteW,
    output wire [4:0] Pass_RdW,
    output wire [31:0] ResultW
);
ResultSrcMux mux(.ResultSrc(ResultSrcW),.ALUResult(ALUResultW),.RD(ReadDataW),.Result(ResultW));
assign Pass_RegWriteW=RegWriteW;
assign Pass_RdW=RdW;
endmodule

module Top (
    input wire CLK,
    output wire [31:0] dbg_PCF,
    output wire [31:0] dbg_InstrD,
    output wire [31:0] dbg_ALUResultE,
    output wire [31:0] dbg_ALUResultM,
    output wire [31:0] dbg_ReadDataW,
    output wire [31:0] dbg_ResultW,
    output wire [4:0] dbg_RdW,
    output wire dbg_RegWriteW,
    output wire [7:0] dbg_flags
);

wire [31:0] RDI,PCF,PCPlus4F,InstrD,PCD,PCPlus4D;
wire [31:0] Pass_PCD,Pass_PCPlus4D,RD1D,RD2D,ImmExtD;
wire [31:0] PCE,PCPlus4E,RD1E,RD2E,ImmExtE;
wire [31:0] PCTargetE,ALUResultE,WriteDataE;
wire [31:0] ALUResultM,WriteDataM,PCPlus4M,RDD;
wire [31:0] ALUResultW,ReadDataW,PCPlus4W,ResultW;
wire [31:0] Pass_ALUResultM,Pass_PCPlus4M;
wire [31:0] PredTargetF,PredTargetD,PredTargetE;

wire RegWriteD,ResultSrcD,MemWriteD,BranchD,ALUSrcD;
wire RegWriteE,ResultSrcE,MemWriteE,BranchE,ALUSrcE;
wire RegWriteM,ResultSrcM,MemWriteM;
wire RegWriteW,ResultSrcW;
wire Pass_RegWriteW;
wire [2:0] ALUControlD,ALUControlE;
wire [4:0] RdD,Rs1D,Rs2D,RdE,Rs1E,Rs2E,RdM,RdW;
wire [4:0] Pass_RdE,Pass_RdM,Pass_RdW;

wire PredTakenF,PredTakenD,PredTakenE,BTBHitF,BTBHitD,BTBE;
wire ActualTakenE,MispredictE;
wire [31:0] CorrectPC_E;

wire [1:0] ForwardAE,ForwardBE;
wire StallF,StallD,FlushE;
wire UsesRs1D,UsesRs2D;
wire LoadUseHazard;

assign UsesRs1D = (InstrD[6:0]==7'b0110011) || // R
                  (InstrD[6:0]==7'b0010011) || // I ALU
                  (InstrD[6:0]==7'b0000011) || // LW
                  (InstrD[6:0]==7'b0100011) || // SW
                  (InstrD[6:0]==7'b1100011);   // BEQ
assign UsesRs2D = (InstrD[6:0]==7'b0110011) ||
                  (InstrD[6:0]==7'b0100011) ||
                  (InstrD[6:0]==7'b1100011);

// ResultSrcE=1 means the instruction in EX is a load.
// A dependent instruction currently in ID must wait one cycle.
assign LoadUseHazard = ResultSrcE && (RdE != 0) &&
                       ((UsesRs1D && (Rs1D==RdE)) ||
                        (UsesRs2D && (Rs2D==RdE)));
assign StallF = LoadUseHazard;
assign StallD = LoadUseHazard;
assign FlushE = LoadUseHazard || MispredictE;

Fetch F(
    .CLK(CLK),
    .StallF(StallF),
    .MispredictE(MispredictE),
    .CorrectPC_E(CorrectPC_E),
    .BranchUpdateE(BranchE),
    .ActualTakenE(ActualTakenE),
    .BranchPCE(PCE),
    .ActualTargetE(PCTargetE),
    .RD(RDI),.PCF(PCF),.PCPlus4F(PCPlus4F),
    .PredTakenF(PredTakenF),.PredTargetF(PredTargetF),.BTBHitF(BTBHitF)
);

IF_ID R1(
    .CLK(CLK),.StallD(StallD),.FlushD(MispredictE),
    .RD(RDI),.PCF(PCF),.PCPlus4F(PCPlus4F),
    .PredTakenF(PredTakenF),.PredTargetF(PredTargetF),.BTBHitF(BTBHitF),
    .InstrD(InstrD),.PCD(PCD),.PCPlus4D(PCPlus4D),
    .PredTakenD(PredTakenD),.PredTargetD(PredTargetD),.BTBHitD(BTBHitD)
);

Decode D(
    .CLK(CLK),.InstrD(InstrD),.PCD(PCD),.PCPlus4D(PCPlus4D),
    .RegWriteW(Pass_RegWriteW),.RdW(Pass_RdW),.ResultW(ResultW),
    .RegWriteD(RegWriteD),.ResultSrcD(ResultSrcD),.MemWriteD(MemWriteD),
    .BranchD(BranchD),.ALUControlD(ALUControlD),.ALUSrcD(ALUSrcD),
    .Pass_PCD(Pass_PCD),.Pass_PCPlus4D(Pass_PCPlus4D),
    .RD1D(RD1D),.RD2D(RD2D),.RdD(RdD),.Rs1D(Rs1D),.Rs2D(Rs2D),.ImmExtD(ImmExtD)
);

ID_EX R2(
    .CLK(CLK),.FlushE(FlushE),
    .RegWriteD(RegWriteD),.ResultSrcD(ResultSrcD),.MemWriteD(MemWriteD),
    .BranchD(BranchD),.ALUControlD(ALUControlD),.ALUSrcD(ALUSrcD),
    .Pass_PCD(Pass_PCD),.Pass_PCPlus4D(Pass_PCPlus4D),
    .RD1D(RD1D),.RD2D(RD2D),.RdD(RdD),.Rs1D(Rs1D),.Rs2D(Rs2D),.ImmExtD(ImmExtD),
    .PredTakenD(PredTakenD),.BTBHitD(BTBHitD),.PredTargetD(PredTargetD),
    .RegWriteE(RegWriteE),.ResultSrcE(ResultSrcE),.MemWriteE(MemWriteE),
    .BranchE(BranchE),.ALUControlE(ALUControlE),.ALUSrcE(ALUSrcE),
    .PCE(PCE),.PCPlus4E(PCPlus4E),.RD1E(RD1E),.RD2E(RD2E),.RdE(RdE),
    .Rs1E(Rs1E),.Rs2E(Rs2E),.ImmExtE(ImmExtE),
    .PredTakenE(PredTakenE),.BTBE(BTBE),.PredTargetE(PredTargetE)
);

Execute E(
    .RegWriteE(RegWriteE),.ResultSrcE(ResultSrcE),.MemWriteE(MemWriteE),
    .BranchE(BranchE),.ALUControlE(ALUControlE),.ALUSrcE(ALUSrcE),
    .PCE(PCE),.PCPlus4E(PCPlus4E),.RD1E(RD1E),.RD2E(RD2E),.ImmExtE(ImmExtE),
    .RdE(RdE),.Rs1E(Rs1E),.Rs2E(Rs2E),
    .RegWriteM(RegWriteM),.ResultSrcM(ResultSrcM),.RdM(RdM),
    .ALUResultM(ALUResultM),
    .ForwardMValue(ResultSrcM ? RDD : ALUResultM),
    .RegWriteW(RegWriteW),.RdW(RdW),.ResultW(ResultW),
    .PredTakenE(PredTakenE),.BTBE(BTBE),.PredTargetE(PredTargetE),
    .Pass_RegWriteE(Pass_RegWriteE),.Pass_ResultSrcE(Pass_ResultSrcE),
    .Pass_MemWriteE(Pass_MemWriteE),.ALUResultE(ALUResultE),
    .WriteDataE(WriteDataE),.PCTargetE(PCTargetE),.Pass_RdE(Pass_RdE),
    .Pass_PCPlus4E(Pass_PCPlus4E),.ActualTakenE(ActualTakenE),
    .MispredictE(MispredictE),.CorrectPC_E(CorrectPC_E)
);

EX_MEM R3(
    .CLK(CLK),.Pass_RegWriteE(Pass_RegWriteE),.Pass_ResultSrcE(Pass_ResultSrcE),
    .Pass_MemWriteE(Pass_MemWriteE),.ALUResultE(ALUResultE),.WriteDataE(WriteDataE),
    .Pass_RdE(Pass_RdE),.Pass_PCPlus4E(Pass_PCPlus4E),
    .RegWriteM(RegWriteM),.ResultSrcM(ResultSrcM),.MemWriteM(MemWriteM),
    .ALUResultM(ALUResultM),.WriteDataM(WriteDataM),.RdM(RdM),.PCPlus4M(PCPlus4M)
);

Memory M(
    .CLK(CLK),.RegWriteM(RegWriteM),.ResultSrcM(ResultSrcM),.MemWriteM(MemWriteM),
    .ALUResultM(ALUResultM),.WriteDataM(WriteDataM),.RdM(RdM),.PCPlus4M(PCPlus4M),
    .Pass_RegWriteM(Pass_RegWriteM),.Pass_ResultSrcM(Pass_ResultSrcM),
    .Pass_ALUResultM(Pass_ALUResultM),.RD(RDD),.Pass_RdM(Pass_RdM),
    .Pass_PCPlus4M(Pass_PCPlus4M)
);

MEM_WB R4(
    .CLK(CLK),.Pass_RegWriteM(Pass_RegWriteM),.Pass_ResultSrcM(Pass_ResultSrcM),
    .Pass_ALUResultM(Pass_ALUResultM),.RD(RDD),.Pass_RdM(Pass_RdM),
    .Pass_PCPlus4M(Pass_PCPlus4M),
    .RegWriteW(RegWriteW),.ResultSrcW(ResultSrcW),.ALUResultW(ALUResultW),
    .ReadDataW(ReadDataW),.RdW(RdW),.PCPlus4W(PCPlus4W)
);

WriteBack WB(
    .RegWriteW(RegWriteW),.ResultSrcW(ResultSrcW),.ALUResultW(ALUResultW),
    .ReadDataW(ReadDataW),.RdW(RdW),.PCPlus4W(PCPlus4W),
    .Pass_RegWriteW(Pass_RegWriteW),.Pass_RdW(Pass_RdW),.ResultW(ResultW)
);

assign dbg_PCF=PCF;
assign dbg_InstrD=InstrD;
assign dbg_ALUResultE=ALUResultE;
assign dbg_ALUResultM=ALUResultM;
assign dbg_ReadDataW=ReadDataW;
assign dbg_ResultW=ResultW;
assign dbg_RdW=RdW;
assign dbg_RegWriteW=RegWriteW;
assign dbg_flags={
    BranchE,MemWriteM,RegWriteM,ALUSrcE,ResultSrcM,
    MispredictE,StallF,ActualTakenE
};
endmodule
