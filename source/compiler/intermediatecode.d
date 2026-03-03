module compiler.intermediatecode;

import std.conv, std.string;

import globals, compiler.compiler, compiler.library;

/** This class builds the intermediate assembly code */
class IntermediateCode
{
    /** Code segments */
    enum PROGRAM_SEGMENT = 0;
    enum ROUTINE_SEGMENT = 1;
    enum LIBRARY_SEGMENT = 2;
    enum DATA_SEGMENT    = 3;
    enum VAR_SEGMENT     = 4;
    
    /** Code segments as strings */
    private string[int] segments;

    /** Reference to the Compiler object */
    private Compiler compiler;

    /** Class constructor */
    this(Compiler compiler)
    {
        this.compiler = compiler;
        this.segments =  [
            PROGRAM_SEGMENT : "prg_start:\n    SEG \"PROGRAM\"\n    ORG prg_start\nFPUSH SET 0\nFPULL SET 0\n    xbegin\n    ; !!opt_start!!\n",
            ROUTINE_SEGMENT : "\nroutines_start:\n",
            LIBRARY_SEGMENT : "\n    ; !!opt_end!!\nlibrary_start:\n    SEG \"LIBRARY\"\n    ORG library_start\n" ~ getIncludes() ~ "\n",
            DATA_SEGMENT    : "\ndata_start:\n",
            VAR_SEGMENT     : getVarSegmentHeader()
        ];
    }

    /** Generate variable segment header - uses variableAddress if specified */
    private string getVarSegmentHeader()
    {
        if(variableAddress != -1) {
            // Explicit variable address - place variables at specified location
            return "vars_start:\n    SEG.U \"VARIABLES\"\n    ORG $" ~ 
                   to!string(variableAddress, 16) ~ "\n";
        } else {
            // Default behavior - variables follow code
            return "vars_start:\n    SEG.U \"VARIABLES\"\n    ORG vars_start\n";
        }
    }

    /** Appends code or data to a segment */
    public void appendSegment(int segmentId, string contents)
    {
        this.segments[segmentId] ~= contents;
    }

    /** Shortcut for appending program or routine segments */
    public void appendProgramSegment(string code)
    {
        // GameTank code banking: if inside a banked routine, route code to
        // bank-specific buffer. currentBank is only set >= 0 by the BANK
        // statement, which guards for target == "gametank".
        if(this.compiler.inProcedure && currentBank >= 0) {
            if(currentBank !in bankCode) {
                bankCode[currentBank] = "";
            }
            bankCode[currentBank] ~= code;
        } else {
            immutable int segment = this.compiler.inProcedure ? ROUTINE_SEGMENT : PROGRAM_SEGMENT;
            this.appendSegment(segment, code);
        }
    }

    /** Getter method to any segment */
    public string getSegment(int segmentId)
    {
        return this.segments[segmentId];
    }

    private string getStartUp()
    {
        // Target machine bits meaning
        // Bits 15-8: base machine
        // Bits 7-0: machine config 
        string startUpCode =
`    PROCESSOR 6502
c64      EQU %0000000100000000
vic20    EQU %0000001000000000
vic20_3k EQU %0000001000000001
vic20_8k EQU %0000001000000010
c264     EQU %0000010000000000
cplus4   EQU %0000010000000001
c16      EQU %0000010000000010
c128     EQU %0000100000000000
pet      EQU %0001000000000000
pet2001  EQU %0001000000001001
pet3     EQU %0001000000010000
pet3008  EQU %0001000000010001
pet3016  EQU %0001000000010010
pet3032  EQU %0001000000010100
pet4     EQU %0001000000100000
pet4016  EQU %0001000000100010
pet4032  EQU %0001000000100100
pet8032  EQU %0001000001000100
gametank EQU %0010000000000000
TARGET   EQU ` ~ target ~ `
USEIRQ   EQU ` ~ (useIrqs ? "1" : "0") ~ `
FASTIRQ  EQU ` ~ (fastIrqs ? "1" : "0") ~ `
USESPR   EQU ` ~ (useSprites ? "1" : "0") ~ `
USESFX   EQU ` ~ (useSound ? "1" : "0") ~ `
    SEG "UPSTART"
    ORG $` ~ to!string(startAddress, 16) ~ "\n";
        if(basicLoader) {
            startUpCode ~= 
`    DC.W next_line, 2021
    DC.B $9e, [prg_start]d, 0
next_line:
    DC.W 0

`;
        }
        return startUpCode;
    }

    private string getIncludes()
    {
        return `
    INCDIR "` ~ getLibraryDir() ~ `"
    INCLUDE "` ~ LIBRARY_FILENAME ~ `"

`;
    }

    public string getCode()
    {
        string programSeg = getSegment(PROGRAM_SEGMENT);

        // GameTank code banking: inject bank variable initialization after xbegin
        if(bankCode.length > 0 && target == "gametank") {
            string bankInit =
                "    ; Initialize ROM banking\n" ~
                "    lda #127\n" ~
                "    sta xcb_current_bank\n" ~
                "    lda #0\n" ~
                "    sta xcb_bank_sp\n";
            programSeg = programSeg.replace("; !!opt_start!!", "; !!opt_start!!\n" ~ bankInit);
        }

        string code = "";

        // GameTank code banking: bank code section at ORG $8000 must come
        // FIRST in the assembly output (lower address than main code at $C100)
        if(bankCode.length > 0 && target == "gametank") {
            code ~= generateBankCodeSection();
        }

        code ~= getStartUp() ~
                programSeg ~ "    xend\n\n" ~
                getSegment(ROUTINE_SEGMENT);

        // GameTank code banking: add trampolines and banking support routines
        if(bankCode.length > 0 && target == "gametank") {
            code ~= generateTrampolines();
            code ~= generateBankingSupportCode();
        }

        code ~= getSegment(LIBRARY_SEGMENT) ~
                getSegment(DATA_SEGMENT) ~
                getSegment(VAR_SEGMENT);

        // GameTank code banking: add banking variables to VAR segment
        if(bankCode.length > 0 && target == "gametank") {
            code ~= "xcb_current_bank DS 1\n" ~
                     "xcb_bank_sp DS 1\n" ~
                     "xcb_bank_stack DS 8\n";
        }

        code ~= "vars_end:\n";

        return code;
    }

    /**
     * Generate trampoline stubs for all banked routines.
     * Each trampoline pushes the current bank, switches to target bank,
     * calls the routine, then restores the previous bank.
     */
    private string generateTrampolines()
    {
        string code = "\n; ===== ROM Bank Trampolines =====\n";
        foreach(label, bankNum; routineBankMap) {
            code ~= "TRAMP_" ~ label ~ " SUBROUTINE\n" ~
                     "    lda #" ~ to!string(bankNum) ~ "\n" ~
                     "    jsr xcb_push_set_bank\n" ~
                     "    jsr " ~ label ~ "\n" ~
                     "    jsr xcb_pop_bank\n" ~
                     "    rts\n\n";
        }
        return code;
    }

    /**
     * Generate banking support assembly routines (GameTank).
     * Uses serial shift register on port $2801 to set ROM bank.
     */
    private string generateBankingSupportCode()
    {
        return
`
; ===== ROM Banking Support (GameTank) =====

; xcb_bank_shift_out: Set ROM bank via serial shift register
; Input: A = bank number (0-127)
; Clobbers: A, Y
xcb_bank_shift_out SUBROUTINE
    sta xcb_current_bank
    lda #0
    sta $2801
    lda xcb_current_bank
    clc
    rol
    rol
    rol
    tay
    REPEAT 7
    tya
    and #2
    sta $2801
    ora #1
    sta $2801
    tya
    rol
    tay
    REPEND
    tya
    and #2
    sta $2801
    ora #1
    sta $2801
    ora #4
    sta $2801
    lda #0
    sta $2801
    rts

; xcb_push_set_bank: Push current bank onto stack and switch to bank in A
; Input: A = target bank number
xcb_push_set_bank SUBROUTINE
    pha
    ldx xcb_bank_sp
    lda xcb_current_bank
    sta xcb_bank_stack,x
    inx
    stx xcb_bank_sp
    pla
    jsr xcb_bank_shift_out
    rts

; xcb_pop_bank: Pop previous bank from stack and restore it
xcb_pop_bank SUBROUTINE
    dec xcb_bank_sp
    ldx xcb_bank_sp
    lda xcb_bank_stack,x
    jsr xcb_bank_shift_out
    rts

`;
    }

    /**
     * Generate the bank code section using RORG $8000 blocks (switchable ROM window).
     * Each code bank gets its own 16KB-aligned block in the binary output.
     * DASM's RORG lets each block assemble as if at $8000, while the actual
     * file offset advances sequentially. The ROM builder extracts each 16KB
     * chunk by its position in the binary.
     *
     * The section starts at ORG $0 to avoid physical address conflicts with
     * the main code at $C100. DASM's 16-bit address space limits us to
     * floor(startAddress / 16384) code banks in a single pass.
     *
     * Binary layout (before main code):
     *   Offset 0x0000: bank N1 code (RORG $8000, padded to 16KB)
     *   Offset 0x4000: bank N2 code (RORG $8000, padded to 16KB)
     *   ...
     *   Offset startAddress: main code (ORG $C100)
     *
     * Banks are emitted in sorted order so the ROM builder can map
     * file position -> bank number deterministically.
     */
    private string generateBankCodeSection()
    {
        import std.algorithm : sort;

        // Collect and sort bank numbers for deterministic output order
        int[] bankNums;
        foreach(bNum, _; bankCode) {
            bankNums ~= bNum;
        }
        sort(bankNums);

        // GameTank code banking: verify that N banks x 16KB fits below startAddress.
        // DASM's 16-bit address space means all bank RORG blocks and main code
        // must coexist without overlapping physical addresses.
        int maxBanks = startAddress / 16384;
        if(bankNums.length > maxBanks) {
            import core.stdc.stdlib : exit;
            import std.stdio : stderr;
            stderr.writeln("** ERROR ** Too many code banks (" ~ to!string(bankNums.length) ~
                          "). Maximum " ~ to!string(maxBanks) ~
                          " code banks fit below start address $" ~
                          to!string(startAddress, 16) ~ ".");
            exit(1);
        }

        // Start bank code at ORG $0 so Nx16KB blocks don't collide
        // with main code at startAddress ($C100).
        string code = "\n; ===== Banked Code Sections (RORG) =====\n" ~
                       "    SEG \"BANK_CODE\"\n" ~
                       "    ORG $0\n";

        foreach(idx, bNum; bankNums) {
            code ~= "\n; --- Bank " ~ to!string(bNum) ~ " code ---\n";

            if(idx > 0) {
                // Advance to next 16KB boundary for subsequent banks
                code ~= "    ALIGN 16384\n";
            }

            // RORG: assemble following code as if at $8000 (virtual origin)
            // while actual file offset continues from the ALIGN position
            code ~= "    RORG $8000\n" ~
                     "FPUSH SET 0\n" ~
                     "FPULL SET 0\n";
            code ~= bankCode[bNum];
            // GameTank code banking: end-of-bank label for size reporting.
            // The ROM builder reads xcb_cbank_N_end from the symbol file
            // to compute actual code size = xcb_cbank_N_end - $8000.
            code ~= "xcb_cbank_" ~ to!string(bNum) ~ "_end\n";
            code ~= "    REND\n";
        }

        return code;
    }
}
