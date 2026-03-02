module statement.gosub_stmt;

import pegged.grammar;

import compiler.compiler;
import language.statement;

import std.array;

/** Compiles a GOSUB statement */
class Gosub_stmt : Statement
{
    /** Class constructor */
    this(ParseTree node, Compiler compiler)
	{
		super(node, compiler);
	}

    /** Compiles the statement */
    void process()
    {
        // GameTank code banking: GOSUB across banks would jump into
        // unmapped memory. Only SUB/FUNCTION calls use safe trampolines.
        if(compiler.inProcedure && compiler.currentProc !is null && compiler.currentProc.bankNum >= 0) {
            compiler.displayError("GOSUB is not allowed inside a banked routine. Use CALL instead.");
        }

        string lbl = join(this.node.children[0].children[0].matches);
        if(!compiler.getLabels().exists(lbl)) {
            compiler.displayError("Label \"" ~ lbl ~ "\" unknown in this scope");
        }

        appendCode("    jsr " ~ compiler.getLabels().toAsmLabel(lbl) ~ "\n");
    }
}