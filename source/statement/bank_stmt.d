module statement.bank_stmt;

import std.conv;
import std.array : join;

import pegged.grammar;

import compiler.compiler;
import language.statement;

import globals;

/**
 * BANK statement - switches to a ROM bank for data output (GameTank only)
 * 
 * Usage:
 *   BANK 0        - Switch to bank 0 (data output to $8000 in bank 0)
 *   BANK 5        - Switch to bank 5
 *   BANK FIXED    - Switch back to fixed bank (normal code output)
 * 
 * After BANK n, any INCBMP statements will place data in that bank
 * instead of the fixed code bank.
 */
class Bank_stmt : Statement
{
    this(ParseTree node, Compiler compiler)
    {
        super(node, compiler);
    }

    void process()
    {
        // Only valid for gametank target
        if(target != "gametank") {
            compiler.displayError("BANK is only supported for GameTank target");
            return;
        }

        // Get the bank specifier from parse tree
        // The grammar is: BANK WS (Number / "FIXED")
        // matches[] concatenates all terminal matches: ["bank", ...digits/fixed...]
        // For multi-digit numbers, each digit is a separate match entry,
        // so we must join all matches after the keyword.
        string bankSpec;
        
        if(node.children.length > 0 && node.children[0].matches.length >= 2) {
            // Join all matches after "bank" to handle multi-digit numbers
            // e.g. ["bank","1","0"] -> "10", ["bank","fixed"] -> "fixed"
            bankSpec = join(node.children[0].matches[1..$]);
        } else if(node.children.length > 0 && node.children[0].children.length > 0) {
            // Fallback: extract from child node
            auto child = node.children[0].children[0];
            if(child.matches.length > 0) {
                bankSpec = join(child.matches);
            }
        }
        
        if(bankSpec.length == 0) {
            compiler.displayError("BANK requires a bank number (0-127) or FIXED");
            return;
        }

        import std.string : toLower, strip;
        bankSpec = bankSpec.strip().toLower();

        if(bankSpec == "fixed") {
            // Return to code segment
            currentBank = -1;
            appendCode("; BANK FIXED (return to code segment)\n");
        } else {
            // Parse bank number
            try {
                int bankNum = to!int(bankSpec);
                if(bankNum < 0 || bankNum > 126) {
                    compiler.displayError("BANK number must be 0-126 (bank 127 is fixed code bank)");
                    return;
                }
                currentBank = bankNum;
                
                // Initialize bank data array if not exists
                if(bankNum !in bankData) {
                    bankData[bankNum] = [];
                }
                
                appendCode("; BANK " ~ to!string(bankNum) ~ " (data at $8000 + offset " ~ 
                          to!string(bankData[bankNum].length) ~ ")\n");
            } catch(Exception e) {
                compiler.displayError("Invalid BANK specifier: " ~ bankSpec ~ ". Use 0-126 or FIXED");
                return;
            }
        }
    }

    // Override dumpLabels to NOT dump labels during bank switch
    // (labels in bank sections need special handling)
    override protected void dumpLabels()
    {
        // Don't dump labels here - bank labels handled separately
    }
}
