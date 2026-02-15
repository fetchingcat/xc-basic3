module statement.screen_stmt;

import language.statement, language.expression;

import compiler.compiler, compiler.type;
import pegged.grammar;

import globals;

/** Parses and compiles a SCREEN statement */
class Screen_stmt : Statement
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
            compiler.displayError("SCREEN is not supported on GameTank target. See the GameTank BASIC SDK documentation for alternatives.");
            return;
        }
        ParseTree arg = this.node.children[0].children[0];
        Expression e = new Expression(arg, compiler);
        e.setExpectedType(compiler.getTypes().get(Type.UINT8));
        e.eval();
        appendCode(e.toString());
        appendCode("    screen\n");
    }
}