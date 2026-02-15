module statement.scroll_stmt;

import language.statement, language.expression;

import compiler.compiler, compiler.type;
import pegged.grammar;

import std.string;

import globals;

/** Parses and compiles a HSCROLL/VSCROLL statement */
class Scroll_stmt : Statement
{
    /** Class constructor */
    this(ParseTree node, Compiler compiler)
	{
		super(node, compiler);
	}

    /** Compile */
    void process()
    {
        if(target == "gametank") {
            compiler.displayError(toUpper(node.matches[0]) ~ "SCROLL is not supported on GameTank target. See the GameTank BASIC SDK documentation for alternatives.");
            return;
        }
        ParseTree arg = node.children[0].children[0];
        Expression e = new Expression(arg, compiler);
        e.setExpectedType(compiler.getTypes().get(Type.UINT8));
        e.eval();
        appendCode(e.toString());
        appendCode("    " ~ toLower(node.matches[0]) ~ "scroll\n");
    }
}