module statement.data_stmt;

import std.array, std.conv, std.range, std.format, std.string;

import pegged.grammar;

import language.statement, compiler.petscii, compiler.variable,
        compiler.compiler, compiler.type, compiler.number, compiler.intermediatecode;

import globals;

class Data_stmt : Statement
{
    private Type type;

    // Store pending labels for bank mode (same pattern as incbin_stmt)
    private string pendingLabels;

    /** Class constructor */
    this(ParseTree node, Compiler compiler)
    {
        super(node, compiler);
    }

    public void process()
    {
        const ParseTree varTypeNode = node.children[0].children[0];
        string typeName = varTypeNode.children[0].matches.join("");
        if(!compiler.getTypes().defined(typeName)) {
            compiler.displayError("Unknown type: " ~ typeName);
        }
        type = compiler.getTypes().get(typeName);
        if(!type.isPrimitive) {
            compiler.displayError("Only primitive types are allowed in a DATA statement");
        }
        ubyte strLen;
        if(type.name == Type.STRING) {
            if(varTypeNode.children.length < 2) {
                compiler.displayError("String length must be specified");
            }
            immutable int len = to!int(join(varTypeNode.children[1].matches)[1..$]);
            if(len < 1 || len > stringMaxLength) {
                compiler.displayError("String length must be between 1 and " ~ to!string(stringMaxLength));
            }
            strLen = to!ubyte(len);
        }

        // --- Bank mode: accumulate raw bytes into bankData[] ---
        if(currentBank >= 0) {
            const ParseTree dataListNode = node.children[0].children[1];
            ubyte[] rawBytes;

            foreach (datum; dataListNode.children) {
                switch (datum.name) {
                    case "XCBASIC.String":
                        if (type.name != Type.STRING) {
                            compiler.displayError("Type mismatch: expected number, label reference or constant, got string");
                        }
                        {
                            // Convert string to PETSCII/ASCII bytes and pad/truncate to strLen
                            ubyte[] strBytes = asciiToPetsciiBytes(join(datum.matches[1..$-1]));
                            // Length byte first (same format as normal DATA AS STRING)
                            ubyte actualLen = cast(ubyte)(strBytes.length > strLen ? strLen : strBytes.length);
                            rawBytes ~= actualLen;
                            // String content, padded with zeroes to strLen
                            for(ubyte si = 0; si < strLen; si++) {
                                rawBytes ~= (si < strBytes.length) ? strBytes[si] : cast(ubyte)0;
                            }
                        }
                    break;

                    case "XCBASIC.Number":
                        if (type.name == Type.STRING) {
                            compiler.displayError("Type mismatch: expected string, got number");
                        }
                        Number num = new Number(datum, compiler, type.name == Type.FLOAT);
                        rawBytes ~= numberToRawBytes(num.intVal, num.floatVal, type);
                    break;

                    case "XCBASIC.Varname":
                        if (type.name == Type.STRING) {
                            compiler.displayError("Type mismatch: expected string, got constant");
                        }
                        Variable var = compiler.getVars().findVisible(datum.matches.join);
                        if (var !is null) {
                            if (!var.isConst) {
                                compiler.displayError("DATA must be constant");
                            }
                            rawBytes ~= numberToRawBytes(to!int(var.constVal), var.constVal, type);
                        }
                        else {
                            compiler.displayError("Unknown constant \"" ~ datum.matches.join ~ "\"");
                        }
                    break;

                    case "XCBASIC.Label_deref":
                        compiler.displayError("Label references in DATA are not supported in bank mode");
                    break;

                    default:
                        assert(0);
                }
            }

            if(rawBytes.length > 0) {
                int offset = cast(int)bankData[currentBank].length;
                bankData[currentBank] ~= rawBytes;
                int bankAddr = 0x8000 + offset;

                // Emit EQU for any pending labels so @label resolves to bank address
                if(pendingLabels.length > 0) {
                    foreach(line; pendingLabels.split("\n")) {
                        string lbl = line.strip();
                        if(lbl.length > 0 && lbl[$-1] == ':') {
                            string labelName = lbl[0..$-1];
                            appendCode(format("%s EQU $%04X  ; BANK %d data\n",
                                            labelName, bankAddr, currentBank));
                        }
                    }
                    pendingLabels = null;
                }

                appendCode(format("; DATA -> BANK %d at $%04X (%d bytes)\n",
                                 currentBank, bankAddr, rawBytes.length));
            }
            return;
        }

        // --- Normal mode: emit DC.B to assembler ---
        const ParseTree dataListNode = node.children[0].children[1];
        string[] listItems;
        bool truncated;
        ulong finalLength;

        foreach (datum; dataListNode.children) {
            switch (datum.name) {
                case "XCBASIC.String":
                    if (type.name != Type.STRING) {
                        compiler.displayError("Type mismatch: expected number, label reference or constant, got string");
                    }
                    compiler.getImCode().appendSegment(
                        inlineData ? IntermediateCode.PROGRAM_SEGMENT : IntermediateCode.DATA_SEGMENT,
                        "    "  ~ asciiToPetsciiHex(join(datum.matches[1..$-1]), strLen, truncated, finalLength) ~ "\n"
                    );
                    if(truncated) {
                        compiler.displayWarning("String truncated to " ~ to!string(strLen) ~ " characters");
                    }
                break;

                case "XCBASIC.Number":
                    if (type.name == Type.STRING) {
                        compiler.displayError("Type mismatch: expected string, got number");
                    }
                    Number num = new Number(datum, compiler, type.name == Type.FLOAT);
                    listItems ~= getNumberAsString(num.intVal, num.floatVal, type);
                break;

                case "XCBASIC.Varname":
                    if (type.name == Type.STRING) {
                        compiler.displayError("Type mismatch: expected string, got constant");
                    }
                    Variable var = compiler.getVars().findVisible(datum.matches.join);
                    if (var !is null) {
                        if (!var.isConst) {
                            compiler.displayError("DATA must be constant");
                        }
                        listItems ~= getNumberAsString(to!int(var.constVal), var.constVal, type);
                    }
                    else {
                        compiler.displayError("Unknown constant \"" ~ datum.matches.join ~ "\"");
                    }
                break;

                case "XCBASIC.Label_deref":
                    if (type.name == Type.STRING) {
                        compiler.displayError("Type mismatch: expected string, got label reference");
                    }
                    if (type.name != Type.UINT16 && type.name != Type.INT16) {
                        compiler.displayError("Type mismatch: a label reference can only be part of INT or WORD data");
                    }
                    immutable string identifier = join(datum.children[0].matches);
                    if (compiler.getLabels().exists(identifier, false)) {
                        immutable string localLabel = compiler.getLabels().toAsmLabel(identifier);
                        listItems ~= "<" ~ localLabel;
                        listItems ~= ">" ~ localLabel;
                    } else {
                        compiler.displayError("Unknown label \"" ~ identifier ~ "\"");
                    }
                break;

                default:
                    assert(0);
            }
        }
            
        if (listItems.length > 0) {
            foreach(chunk; chunks(listItems, 8)) {
                compiler.getImCode().appendSegment(
                    inlineData ? IntermediateCode.PROGRAM_SEGMENT : IntermediateCode.DATA_SEGMENT,
                    "    DC.B " ~ chunk.join(",") ~ "\n"
                );
            }
        }
    }

    // Convert a numeric value to raw bytes for bank storage (little-endian)
    private ubyte[] numberToRawBytes(int intVal, float floatVal, Type type)
    {
        ubyte[] result;
        switch(type.name) {
            case Type.UINT8:
                result ~= cast(ubyte)(intVal & 0xFF);
                break;
            case Type.UINT16:
            case Type.INT16:
                result ~= cast(ubyte)(intVal & 0xFF);         // low byte
                result ~= cast(ubyte)((intVal >> 8) & 0xFF);  // high byte
                break;
            case Type.INT24:
                result ~= cast(ubyte)(intVal & 0xFF);
                result ~= cast(ubyte)((intVal >> 8) & 0xFF);
                result ~= cast(ubyte)((intVal >> 16) & 0xFF);
                break;
            case Type.FLOAT:
                // Use the same 5-byte format as Number.floatToHex
                string hex = Number.floatToHex(floatVal, "");
                // Parse comma-separated hex bytes like "$XX,$XX,..."
                foreach(h; hex.split(",")) {
                    string s = h.strip();
                    if(s.length > 1 && s[0] == '$') s = s[1..$];
                    result ~= to!ubyte(to!int(s, 16) & 0xFF);
                }
                break;
            case Type.DEC:
                string hex = Number.getDecimalAsHex(intVal, "");
                foreach(h; hex.split(",")) {
                    string s = h.strip();
                    if(s.length > 1 && s[0] == '$') s = s[1..$];
                    result ~= to!ubyte(to!int(s, 16) & 0xFF);
                }
                break;
            default:
                result ~= cast(ubyte)(intVal & 0xFF);
                break;
        }
        return result;
    }

    // Translates a numeric value to its string representation
    private string getNumberAsString(int intVal, float floatVal, Type type)
    {
        switch(type.name) {
            case Type.FLOAT:
                return Number.floatToHex(floatVal, "$");

            case Type.DEC:
                return Number.getDecimalAsHex(intVal, "$");

            default:
                return Number.integralToHex(intVal, type, true, "$");
        }
    }

    // In bank mode: save labels for EQU emission; normal mode: emit to DATA segment
    override protected void dumpLabels()
    {
        if(currentBank >= 0) {
            pendingLabels = compiler.getAndClearCurrentLabels();
        } else {
            compiler.getImCode().appendSegment(
                inlineData ? IntermediateCode.PROGRAM_SEGMENT : IntermediateCode.DATA_SEGMENT,
                compiler.getAndClearCurrentLabels()
            );
        }
    }
}