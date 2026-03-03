/**
 * XC=BASIC
 *
 * A BASIC cross compiler for MOS 6502-based machines
 *
 * Author: Csaba Fekete <feketecsaba@gmail.com>
 */

import std.stdio, std.string, std.getopt, std.file, std.path,
        std.conv, std.random, std.process, std.algorithm, std.format;
import core.stdc.stdlib;

import pegged.grammar;
import language.grammar;

import compiler.compiler, compiler.library, compiler.sourcefile;

import globals, optimizer;

// Program version
const string APP_VERSION = "v3.1.12-gt-1.3";

/** Possible target options */
const string[] targetOpts = [
    "c64",      // Commodore-64
    "vic20",    // Commodore VIC-20 (unexpanded)
    "vic20_3k", // Commodore VIC-20 with 3k RAM expansion
    "vic20_8k", // Commodore VIC-20 with 8k RAM expansion
    "cplus4",   // Commodore Plus/4
    "c16",      // Commodore-16,
    "c128",     // Commodore-128
    "pet2001",  // Commodore PET2001
    "pet3008",  // Commodore PET3000 series (8k RAM)
    "pet3016",  // Commodore PET3000 series (16k RAM)
    "pet3032",  // Commodore PET3000 series (32k RAM)
    "pet4016",  // Commodore PET4000 series (16k RAM)
    "pet4032",  // Commodore PET4000 series (32k RAM)
    "pet8032",  // Commodore PET8000 series
    "gametank"  // GameTank console
];

// Command line options
private bool optimize = true;
private bool keepImCode = false;
private string outputFormat = "prg";  // prg, raw, or gtr (GameTank ROM)
version(Windows) {
	private string dasm = "dasm.exe";
}
else {
	private string dasm = "dasm";
}
private string symbolfile="";
private string listfile="";
private int verbosity = VERBOSITY_INFO;

private GetoptResult helpInformation;

/**
 * Application entry point
 */
void main(string[] args)
{ 
    checkLibrary();
    
    // Read and validate command line options
    try {
        helpInformation = getopt(args,
            "target|t", &target,
            "basic-loader|b", &basicLoader,
            "start-address|o", &startAddress,
            "max-address|m", &topAddress,
            "output-format|f", &outputFormat,
            "dasm|d", &dasm,
            "symbol|s", &symbolfile,
            "list|l", &listfile,
            "optimize|p", &optimize,
            "keep-imcode|k", &keepImCode,
            "verbosity|v", &verbosity,
            "inline-data|i", &inlineData
        );
    }
	catch(Exception e) {
        stderr.writeln(e.msg);
        exit(1);
    }

    if(helpInformation.helpWanted) {
        displayHelp(0);
    }

	validateOptions(args);

    // GameTank has no BASIC ROM, disable loader by default
    // Also set default variable address if compiling to ROM
    if(target == "gametank") {
        basicLoader = false;
        // For GTR output, default to ROM address and set up properly
        if(outputFormat == "gtr") {
            if(startAddress == -1) {
                startAddress = 0xC100;  // Code after init stub
            }
            if(variableAddress == -1) {
                variableAddress = 0x0200;  // Variables in RAM
            }
        }
        // If code starts in ROM ($C000+) and no variable address specified,
        // default variables to RAM at $0200
        else if(variableAddress == -1 && startAddress >= 0xC000) {
            variableAddress = 0x0200;
        }
    }

    setStartAddress();
    setEndAddress();
    
    const string fileName = args[1];
    string outName;
    if(args.length >= 3) {
        outName = args[2];
    }
    else {
        outName = to!string(fileName.withExtension("prg"));
        if(verbosity >= VERBOSITY_NOTICE) {
            stdout.writeln("** NOTICE ** Output file not specified, defaulting to " ~ outName);
        }
    }

    Compiler compiler = new Compiler();
    // Compile standard headers
    const string stdHeadersName = getLibraryDir() ~ "/headers.bas";
    SourceFile source = SourceFile.get(stdHeadersName);
    compiler.compileSourceFile(source);
    // Compile the program
    compiler.compilingUserCode = true;
    immutable string currentDir = getcwd();
    chdir(dirName(fileName));
    source = SourceFile.get(baseName(fileName));
    compiler.compileSourceFile(source);
    compiler.doPostChecks();
    chdir(currentDir);
        
     // Write intermediate code to temp file
    auto rnd = Random(unpredictableSeed);
    auto u = uniform!uint(rnd);

    version(Windows) {
        const string tmpdir = tempDir();
    }
    else {
        const string tmpdir = tempDir() ~ dirSeparator;
    }

    string asmFilename = tmpdir ~ "xcbtmp_" ~ to!string(u, 16) ~ ".asm";
    string tmpSymbolfile = tmpdir ~ "xcbtmp_" ~ to!string(u, 16) ~ ".sym";

    File outfile = File(asmFilename, "w");
    if(optimize) {
        OptimizerPass optimizer = new Optimizer();
        optimizer.setInCode(compiler.getImCode().getCode());
        optimizer.run();
        outfile.write(optimizer.getOutCode());
    } else {
        outfile.write(compiler.getImCode().getCode());
    }
    
    outfile.close();

    // Call DASM to compile intermediate code to exacutable
    version(Windows) {
        dasm = `"` ~ dasm ~ `"`;
        asmFilename = `"` ~ asmFilename ~ `"`;
        outName = `"` ~ outName ~ `"`;
        if(listfile != "") {
            listfile = `"` ~ listfile ~ `"`;
        }
    }

    string cmd = dasm ~ " " ~ asmFilename ~ " -o" ~ outName ~ " -s" ~ tmpSymbolfile;

    // GameTank target outputs raw binary (no PRG header)
    if(target == "gametank") {
        cmd ~= " -f3";
    }

    if(listfile != "") {
        cmd ~= " -l" ~ listfile;
    }
    auto dasm_cmd = executeShell(cmd);
    
    if(!keepImCode) {
        try {
            remove(asmFilename);
        }
        catch(Exception e) {
            // There has been an error while removing the file
            // it's okay, since it's in a temp dir, it'll be removed anyway
        }
        
    } else {
        stdout.writeln("File containing intermediate code kept in " ~ asmFilename);
    }
    
    if(dasm_cmd.status != 0) {
        stderr.writeln("** ERROR ** There has been an error while trying to execute DASM, please see the bellow message.");
        stderr.writeln("Tried to execute: " ~ cmd);
        stderr.writeln(dasm_cmd.output);
        stderr.writeln("Please submit this bug to https://github.com/neilsf/xc-basic3/issues");
        exit(1);
    }
    else {
        // For GameTank GTR format, post-process into complete ROM
        if(target == "gametank" && outputFormat == "gtr") {
            version(Windows) {
                // Remove quotes added earlier for Windows shell
                outName = outName[1..$-1];
            }
            buildGameTankRom(outName, tmpSymbolfile);
        }
        
        if(verbosity == VERBOSITY_INFO) {
            displayInformation(tmpSymbolfile);
        }
        if(symbolfile != "") {
            copy(tmpSymbolfile, symbolfile);
        }
        remove(tmpSymbolfile);
        exit(0);
    }
}

/**
 * Checks if provided options are valid
 */
private void validateOptions(string[] args)
{
    if(args.length < 2) {
        stderr.writeln("Too few command line options. Use --help for more information.");
        exit(1);
    }

    if(!canFind(targetOpts, target)) {
        stderr.writeln("'" ~ target ~"' is not a valid target. Possible values are: " ~ targetOpts.join(", "));
        exit(1);
    }

    if(topAddress < -1 || topAddress > 0xffff) {
        stderr.writeln("Invalid max address: " ~ to!string(topAddress));
        exit(1);
    }
}

/**
 * Set implicit start address based on other options
 */
public void setStartAddress()
{
    if(basicLoader) {
        switch(target) {
            case "vic20_3k":
                startAddress = 0x0401;
                break;
            
            case "c64":
                startAddress = 0x0801;
                break;

            case "c128":
                startAddress = 0x1c01;
                break;

            case "vic20":
            case "cplus4":
            case "c16":
                startAddress = 0x1001;
                break;

            case "pet2001":
            case "pet3008":
            case "pet3016":
            case "pet3032":
            case "pet4016":
            case "pet4032":
            case "pet8032":
                startAddress = 0x0401;
                break;

            case "vic20_8k":
            default:
                startAddress = 0x1201;
                break;
        }
    }
    else if(startAddress == -1) {
        // GameTank: default to RAM start when not using GTR output format
        if(target == "gametank") {
            startAddress = 0x0200;
        } else {
            startAddress = 0x1000;
        }
    }

     if(startAddress < 0 || startAddress > 0xffff) {
        stderr.writeln("Invalid start address: " ~ to!string(startAddress));
        exit(1);
    }
}

/**
 * Set implicit end address based on target setting
 */
private void setEndAddress()
{
    if(topAddress == -1) {
         switch(target) {
            case "vic20_3k":
            case "vic20":
                topAddress = 0x1e00;
                break;
            
            case "c64":
                topAddress = 0xd000;
                break;

            case "c128":
                topAddress = 0xc000;
                break;

            case "cplus4":
            case "pet3032":
            case "pet4032":
            case "pet8032":
                topAddress = 0x8000;
                break;

            case "pet2001":
            case "pet3008":
                topAddress = 0x2000;
                break;

            case "vic20_8k":
            case "c16":
            case "pet3016":
            case "pet4016":
                topAddress = 0x4000;
                break;

            case "gametank":
                topAddress = 0x1F00;  // Stack frame at $1F00
                break;
                
            default:
                topAddress = 0x10000;
        }
    }
    
    if(topAddress < 0 || topAddress > 0xffff) {
        stderr.writeln("Invalid max address: " ~ to!string(topAddress));
        exit(1);
    }
}

/**
 * Display help message and exit
 */
private void displayHelp(int exitCode, string errorMsg = "")
{
    stdout.writeln(errorMsg ~
`
XC=BASIC compiler version ` ~ APP_VERSION ~ " (" ~ __DATE__ ~ ")" ~ `
(GameTank Edition)
Copyright (c) 2019-2022 by Csaba Fekete (see LICENSE)
Usage: xcbasic3 [options] <inputfile> <outputfile> [options]
Options:
   -t
  --target=         Target machine. Possible values: ` ~ targetOpts.join(", ") ~ `.
                    Defaults to "c64".

   -b
  --basic-loader=   Include a BASIC loader. Turned on by default (true).

   -o
  --start-address=  Change the default start address. Please provide a decimal number. Has no effect if
                    --basic-loader=true.

   -m
  --max-address=    Change the default top address.
                    If the program and its data overgrow the top address, a warning will be emitted.
                    Please provide a decimal number.

   -k
  --keep-imcode=    By default, the intermediate assembly code will be deleted after successful
                    assembly. Set this to TRUE if you wan to keep it.

   -d
  --dasm=           Path to the DASM executable.
                    Not required if DASM is in your PATH or in the working dir.

   -s
  --symbol=         Symbol dump file name. Provide a file name if you want to generate a symbol dump.

   -l
  --list=           List file name. This is passed to DASM as it is.

   -p
  --optimize        Output optimized (faster and smaller) code. Turned on by default (true).

   -h
  --help            Show this help

   -i
  --inline-data=    If set to true, DATA statements are compiled at the current origin.
                    Otherwise, they get compiled after code. Defaults to false.
`
    );
    exit(exitCode);
}

/**
 * Check if XC=BASIC library exists, display error message if it doesn't
 */
private void checkLibrary()
{   
    if(!exists(getLibraryPath())) {
        stderr.writeln("XC=BASIC library was not found in \"" ~ getLibraryDir() ~ "\". Please make sure the directory exists and contains the library files.");
        exit(1);
    }
}

/**
 * Fetch symbol addresses from the symbol list provided by DASM
 * Extend the list in symbolNames to get more
 */
private int[string] getSymbols(string tmpSymbolfile)
{
    const string[] symbolNames = ["prg_start", "library_start", "data_start", "vars_start", "vars_end"];
    int[string] symbols;
    auto lines = slurp!(string, string, string)(tmpSymbolfile, "%s %s %s");
    foreach (key, value; lines) {
        if(canFind(symbolNames, value[0])) {
            symbols[value[0]] = to!int(value[1], 16);
        }
    }
    return symbols;
}

/**
 * Display information about the compiled program
 */
private void displayInformation(string tmpSymbolfile)
{
    bool hasVars = false;
    string asHex(int number) {
        return to!string(rightJustifier(to!string(number, 16), 4, '0'));
    }    

    int[string] symbols = getSymbols(tmpSymbolfile);
    
    // GameTank code banking: collect code bank end symbols for segment table
    import std.algorithm : sort;
    int[int] codeBankEndAddrs;
    if(bankCode.length > 0) {
        auto bankSymLines = File(tmpSymbolfile).byLine();
        foreach(line; bankSymLines) {
            auto lineStr = to!string(line);
            auto parts = lineStr.split();
            if(parts.length >= 2) {
                import std.string : startsWith, endsWith;
                if(startsWith(parts[0], "xcb_cbank_") && endsWith(parts[0], "_end")) {
                    try {
                        auto bankStr = parts[0]["xcb_cbank_".length .. $ - "_end".length];
                        int bNum = to!int(bankStr);
                        int endAddr = to!int(parts[1], 16);
                        codeBankEndAddrs[bNum] = endAddr;
                    } catch(Exception e) {}
                }
            }
        }
    }
    
    const string separator = "+---------------+-------+-------+"; 
    stdout.writeln("Complete. (0)");
    stdout.writeln(separator ~ "\n|    Segment    | Start |  End  |\n" ~ separator);
    if(basicLoader) {
        stdout.writeln("|BASIC Loader   | $" ~ asHex(startAddress) ~ " | $" ~ asHex(symbols["prg_start"] - 1) ~ " |");
    }
    stdout.writeln("|Program code   | $" ~ asHex(symbols["prg_start"]) ~ " | $" ~ asHex(symbols["library_start"] - 1) ~ " |");
    // GameTank code banking: show code bank segments in the table
    if(codeBankEndAddrs.length > 0) {
        int[] sortedBanks;
        foreach(bNum, _; codeBankEndAddrs) {
            sortedBanks ~= bNum;
        }
        sort(sortedBanks);
        foreach(bNum; sortedBanks) {
            import std.format : format;
            string label = format("Code bank %-4d", bNum);
            stdout.writeln("|" ~ label ~ " | $" ~ asHex(0x8000) ~ " | $" ~ asHex(codeBankEndAddrs[bNum] - 1) ~ " |");
        }
    }
    if(symbols["data_start"] > symbols["library_start"]) {
        stdout.writeln("|Library        | $" ~ asHex(symbols["library_start"]) ~ " | $" ~ asHex(symbols["data_start"] - 1) ~ " |");
    }
    if(symbols["vars_start"] > symbols["data_start"]) {
        stdout.writeln("|Data & Strings | $" ~ asHex(symbols["data_start"]) ~ " | $" ~ asHex(symbols["vars_start"] - 1) ~ " |");
    }
    if(symbols["vars_end"] > symbols["vars_start"]) {
        stdout.writeln("|Variables*     | $" ~ asHex(symbols["vars_start"]) ~ " | $" ~ asHex(symbols["vars_end"] - 1) ~ " |");
        hasVars = true;
    }
    stdout.writeln(separator);
    if(hasVars) {
        stdout.writeln("(*) Uninitialized segment.");
    }
    if(symbols["vars_end"] >= topAddress) {
        stdout.writeln(
            "WARNING: The program has been successfully compiled, but it can't fit between $" 
            ~ asHex(startAddress) ~ " and $" ~ asHex(topAddress) ~ ". Use the -m option to change the top address.");
    }
}

/**
 * Build a complete GameTank ROM (.gtr) from compiled binary
 * Creates init stub, sets vectors, pads to 2MB
 */
private void buildGameTankRom(string binFile, string symFile)
{
    import std.file : read, write;
    import std.algorithm : sort;
    
    string asHex(int number) {
        return to!string(rightJustifier(to!string(number, 16), 4, '0'));
    }
    
    // Read the compiled binary
    auto fullBinary = cast(ubyte[])read(binFile);
    
    // Determine if we have banked code
    bool hasBankCode = bankCode.length > 0;
    
    // Collect and sort bank numbers (must match order in generateBankCodeSection)
    int[] codeBankNums;
    foreach(bNum, _; bankCode) {
        codeBankNums ~= bNum;
    }
    sort(codeBankNums);
    
    // Validate: no bank has both code and data
    foreach(bNum; codeBankNums) {
        if(bNum in bankData && bankData[bNum].length > 0) {
            stderr.writeln("** ERROR ** Bank " ~ to!string(bNum) ~ 
                          " has both code and data. Use separate banks for code and data.");
            exit(1);
        }
    }
    
    // Extract main code and per-bank code from binary
    ubyte[] mainCodeData;
    ubyte[][] bankCodeChunks;  // One 16KB chunk per code bank, in sorted order
    
    if(hasBankCode) {
        // Binary layout: Nx16KB bank code blocks at $8000, then main code at startAddress.
        // Each bank block is 16KB (ALIGN 16384 in assembly).
        // Main code starts at offset (N * 16384) + (startAddress - $8000).
        int numBanks = cast(int)codeBankNums.length;
        
        // Extract each bank's 16KB chunk
        foreach(idx, bNum; codeBankNums) {
            int chunkOffset = cast(int)(idx * 16384);
            ubyte[] chunk = new ubyte[16384];
            chunk[] = 0xFF;
            
            if(chunkOffset < fullBinary.length) {
                size_t available = fullBinary.length - chunkOffset;
                size_t copyLen = available >= 16384 ? 16384 : available;
                chunk[0..copyLen] = fullBinary[chunkOffset..chunkOffset + copyLen];
            }
            bankCodeChunks ~= chunk;
        }
        
        // Main code starts after all bank code blocks.
        // Bank code starts at ORG $0, so binary offset of main code
        // equals startAddress directly.
        int mainOffset = startAddress;
        if(mainOffset < fullBinary.length) {
            mainCodeData = fullBinary[mainOffset..$].dup;
        } else {
            mainCodeData = [];
        }
    } else {
        // No bank code - binary starts at startAddress as before
        mainCodeData = fullBinary.dup;
    }
    
    auto codeSize = mainCodeData.length;
    
    // Find NMI and IRQ handlers from symbol file
    int nmiAddr = startAddress;      // Default to code start
    int irqAddr = startAddress + 8;  // Default offset
    bool nmiExact = false, irqExact = false;
    
    // GameTank code banking: track end addresses for size reporting
    int[int] codeBankEndAddrs;  // bank number to end address (virtual, relative to $8000)
    
    // Parse symbol file to find handler addresses and code bank sizes
    auto symLines = File(symFile).byLine();
    foreach(line; symLines) {
        auto lineStr = to!string(line);
        auto parts = lineStr.split();
        if(parts.length >= 2) {
            import std.string : endsWith, startsWith;
            if(parts[0] == "nmi_entry") {
                try {
                    nmiAddr = to!int(parts[1], 16);
                    nmiExact = true;
                } catch(Exception e) {}
            } else if(!nmiExact && parts[0].endsWith(".nmi_entry")) {
                try {
                    nmiAddr = to!int(parts[1], 16);
                } catch(Exception e) {}
            }
            if(parts[0] == "irq_entry") {
                try {
                    irqAddr = to!int(parts[1], 16);
                    irqExact = true;
                } catch(Exception e) {}
            } else if(!irqExact && parts[0].endsWith(".irq_entry")) {
                try {
                    irqAddr = to!int(parts[1], 16);
                } catch(Exception e) {}
            }
            // GameTank code banking: parse xcb_cbank_N_end symbols for size reporting
            if(startsWith(parts[0], "xcb_cbank_") && endsWith(parts[0], "_end")) {
                try {
                    // Extract bank number from "xcb_cbank_N_end"
                    auto bankStr = parts[0]["xcb_cbank_".length .. $ - "_end".length];
                    int bNum = to!int(bankStr);
                    int endAddr = to!int(parts[1], 16);
                    codeBankEndAddrs[bNum] = endAddr;
                } catch(Exception e) {}
            }
        }
    }
    
    // Create 16KB bank filled with $FF
    ubyte[] bank = new ubyte[16384];
    bank[] = 0xFF;
    
    // Init stub at $C000 (offset 0 in bank)
    ubyte[] initStub = [
        0x78,             // SEI
        0xD8,             // CLD
        0xA2, 0xFF,       // LDX #$FF
        0x9A,             // TXS
        0xA2, 0x00,       // LDX #0 (VIA wake delay)
        0xE8,             // INX
        0xD0, 0xFD,       // BNE -3
        0xA9, 0x07,       // LDA #$07
        0x8D, 0x03, 0x28, // STA $2803 (VIA_DDRA)
        0xA9, 0xFF,       // LDA #$FF
        0x8D, 0x01, 0x28, // STA $2801 (VIA_ORA)
        0xA9, 0x05,       // LDA #5 (DMA_ENABLE | DMA_NMI)
        0x8D, 0x07, 0x20, // STA $2007 (DMA_FLAGS)
        0xA9, 0x08,       // LDA #8
        0x8D, 0x05, 0x20, // STA $2005 (BANK_REG)
        0x58,             // CLI
        0x4C,             // JMP
        cast(ubyte)(startAddress & 0xFF),
        cast(ubyte)((startAddress >> 8) & 0xFF)
    ];
    
    // Copy init stub to bank start
    bank[0..initStub.length] = initStub[];
    
    // Copy main code at $C100 (offset $100 in bank)
    int codeOffset = startAddress - 0xC000;
    if(codeOffset + codeSize <= 16384 - 6) {  // Leave room for vectors
        bank[codeOffset..codeOffset + codeSize] = mainCodeData[];
    } else {
        stderr.writeln("** ERROR ** Code too large for single ROM bank (fixed bank)");
        exit(1);
    }
    
    // Set vectors at $FFFA (offset $3FFA in bank)
    bank[0x3FFA] = cast(ubyte)(nmiAddr & 0xFF);
    bank[0x3FFB] = cast(ubyte)((nmiAddr >> 8) & 0xFF);
    bank[0x3FFC] = 0x00;  // Reset -> $C000
    bank[0x3FFD] = 0xC0;
    bank[0x3FFE] = cast(ubyte)(irqAddr & 0xFF);
    bank[0x3FFF] = cast(ubyte)((irqAddr >> 8) & 0xFF);
    
    // Create 2MB ROM filled with $FF
    ubyte[] rom = new ubyte[2 * 1024 * 1024];
    rom[] = 0xFF;
    
    // Place fixed code bank at position 127 (last 16KB, where reset vector is read from)
    int bankOffset = 127 * 16384;
    rom[bankOffset..bankOffset + 16384] = bank[];
    
    // Place banked code in ROM (one 16KB chunk per code bank)
    if(hasBankCode) {
        foreach(idx, bNum; codeBankNums) {
            int codeBankOffset = bNum * 16384;
            rom[codeBankOffset..codeBankOffset + 16384] = bankCodeChunks[idx][];
            
            if(verbosity >= VERBOSITY_NOTICE) {
                // GameTank code banking: show size if end symbol was found
                if(bNum in codeBankEndAddrs) {
                    int codeBytes = codeBankEndAddrs[bNum] - 0x8000;
                    stdout.writeln("  Code bank " ~ to!string(bNum) ~ ": " ~
                                  to!string(codeBytes) ~ " bytes at $8000-$" ~
                                  asHex(codeBankEndAddrs[bNum] - 1));
                } else {
                    stdout.writeln("  Code bank " ~ to!string(bNum) ~ ": code at $8000");
                }
            }
        }
    }
    
    // Place data banks from BANK statements
    foreach(bankNum, data; bankData) {
        if(data.length > 0) {
            if(data.length > 16384) {
                stderr.writeln("** WARNING ** Bank " ~ to!string(bankNum) ~ " data (" ~ 
                              to!string(data.length) ~ " bytes) exceeds 16KB, truncating");
            }
            int offset = bankNum * 16384;
            size_t copyLen = data.length > 16384 ? 16384 : data.length;
            rom[offset..offset + copyLen] = data[0..copyLen];
            
            if(verbosity >= VERBOSITY_NOTICE) {
                stdout.writeln("  Bank " ~ to!string(bankNum) ~ ": " ~ to!string(data.length) ~ " bytes at $8000");
            }
        }
    }
    
    // Write the final ROM
    write(binFile, rom);
    
    if(verbosity >= VERBOSITY_NOTICE) {
        stdout.writeln("GameTank ROM: " ~ binFile ~ " (2MB)");
        stdout.writeln("  NMI: $" ~ format("%04X", nmiAddr) ~ ", IRQ: $" ~ format("%04X", irqAddr));
    }
}
