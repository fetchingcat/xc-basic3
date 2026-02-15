module statement.incbin_stmt;

import std.file, std.path, std.string, std.format, std.conv;

import pegged.grammar;

import compiler.compiler;
import language.statement, language.expression;

import globals;

class Incbin_stmt : Statement
{
    // Store pending labels for bank mode
    private string pendingLabels;
    
     /** Class constructor */
    this(ParseTree node, Compiler compiler)
	{
		super(node, compiler);
	}

    // Override to handle labels specially in bank mode
    override protected void dumpLabels()
    {
        if(currentBank >= 0) {
            // Bank mode: save labels but don't emit yet
            pendingLabels = compiler.getAndClearCurrentLabels();
        } else {
            // Normal mode: dump labels as usual
            compiler.dumpLabels();
        }
    }

    /** Compiles the statement */
    void process()
    {
        const string fileName = getcwd() ~ dirSeparator ~ join(this.node.children[0].children[0].matches[1..$-1]);
        if(!exists(fileName)) {
            compiler.displayError("File cannot be read: " ~ fileName);
            return;
        }

        // If we're in a bank, store to bankData; otherwise output INCBIN to ASM
        if(currentBank >= 0) {
            // Bank mode: read file and store raw bytes to bankData
            ubyte[] fileData;
            try {
                fileData = cast(ubyte[])read(fileName);
            } catch(Exception e) {
                compiler.displayError("Error reading file: " ~ e.msg);
                return;
            }
            
            int offset = cast(int)bankData[currentBank].length;
            bankData[currentBank] ~= fileData;
            
            int bankAddr = 0x8000 + offset;
            
            // Emit EQU for any pending labels so @label resolves to the bank address
            if(pendingLabels.length > 0) {
                import std.array : split;
                foreach(line; pendingLabels.split("\n")) {
                    string lbl = line.strip();
                    if(lbl.length > 0 && lbl[$-1] == ':') {
                        // Remove trailing colon and emit EQU
                        string labelName = lbl[0..$-1];
                        appendCode(format("%s EQU $%04X  ; BANK %d data\n", 
                                        labelName, bankAddr, currentBank));
                    }
                }
            }
            
            appendCode(format("; INCBIN \"%s\" -> BANK %d at $%04X (%d bytes)\n", 
                             fileName, currentBank, bankAddr, fileData.length));
        } else {
            // Normal mode: output INCBIN to ASM
            appendCode("    INCBIN \"" ~ fileName ~ "\"\n");
        }
    }
}