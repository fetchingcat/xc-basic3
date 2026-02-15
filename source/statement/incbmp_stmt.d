module statement.incbmp_stmt;

import std.file, std.path, std.string, std.conv, std.array;

import pegged.grammar;

import compiler.compiler;
import language.statement;

import globals;

class Incbmp_stmt : Statement
{
    // Store pending labels for bank mode
    private string pendingLabels;
    
    this(ParseTree node, Compiler compiler)
    {
        super(node, compiler);
    }

    // Override to handle labels specially in bank mode
    override protected void dumpLabels()
    {
        if(currentBank >= 0) {
            // Bank mode: save labels but don't emit yet
            // We'll emit EQU after we know the offset
            pendingLabels = compiler.getAndClearCurrentLabels();
        } else {
            // Normal mode: dump labels as usual
            compiler.dumpLabels();
        }
    }

    void process()
    {
        // Only valid for gametank target
        if(target != "gametank") {
            compiler.displayError("INCBMP is only supported for GameTank target");
            return;
        }

        const string fileName = getcwd() ~ dirSeparator ~ join(this.node.children[0].children[0].matches[1..$-1]);
        if(!exists(fileName)) {
            compiler.displayError("BMP file cannot be read: " ~ fileName);
            return;
        }

        // Read BMP file
        ubyte[] fileData;
        try {
            fileData = cast(ubyte[])read(fileName);
        } catch(Exception e) {
            compiler.displayError("Error reading BMP file: " ~ e.msg);
            return;
        }

        // Parse BMP header
        if(fileData.length < 54) {
            compiler.displayError("Invalid BMP file (too small): " ~ fileName);
            return;
        }

        // Check BMP magic
        if(fileData[0] != 'B' || fileData[1] != 'M') {
            compiler.displayError("Invalid BMP file (bad magic): " ~ fileName);
            return;
        }

        // Get image dimensions from DIB header
        int width = fileData[18] | (fileData[19] << 8) | (fileData[20] << 16) | (fileData[21] << 24);
        int height = fileData[22] | (fileData[23] << 8) | (fileData[24] << 16) | (fileData[25] << 24);
        int bitsPerPixel = fileData[28] | (fileData[29] << 8);
        uint dataOffset = fileData[10] | (fileData[11] << 8) | (fileData[12] << 16) | (fileData[13] << 24);

        // Handle negative height (top-down DIB)
        bool topDown = height < 0;
        if(topDown) height = -height;

        // Only 8-bit indexed BMPs are supported
        // Artists must export with GameTank's 256-color HSL palette
        if(bitsPerPixel != 8) {
            compiler.displayError("INCBMP requires 8-bit indexed BMP files. Got " ~ to!string(bitsPerPixel) ~ "-bit. " ~
                "Please export your image as 8-bit indexed BMP with the GameTank HSL palette.");
            return;
        }

        if(width > 128 || height > 128) {
            compiler.displayError("INCBMP: Image too large (" ~ to!string(width) ~ "x" ~ to!string(height) ~ "), max 128x128");
            return;
        }

        // Calculate row size (rows are padded to 4-byte boundaries)
        int rowSize = ((width + 3) / 4) * 4;

        // Collect pixel data
        ubyte[] pixels;
        pixels.reserve(width * height);

        // BMP stores rows bottom-to-top (unless top-down)
        for(int y = 0; y < height; y++) {
            int srcY = topDown ? y : (height - 1 - y);
            int rowOffset = dataOffset + srcY * rowSize;

            for(int x = 0; x < width; x++) {
                int pixelOffset = rowOffset + x;

                if(pixelOffset >= fileData.length) {
                    compiler.displayError("INCBMP: Unexpected end of pixel data");
                    return;
                }

                // 8-bit indexed: use palette index directly as GameTank HSL color
                ubyte gtColor = fileData[pixelOffset];
                pixels ~= gtColor;
            }
        }

        // If we're in a bank, store to bankData; otherwise output to ASM
        if(currentBank >= 0) {
            // Bank mode: store raw bytes to bankData
            int offset = cast(int)bankData[currentBank].length;
            bankData[currentBank] ~= pixels;
            
            import std.format;
            int bankAddr = 0x8000 + offset;
            
            // Emit EQU for any pending labels so @label resolves to the bank address
            if(pendingLabels.length > 0) {
                // Convert "labelname:\n" to "labelname EQU $XXXX\n"
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
            
            appendCode(format("; INCBMP \"%s\" (%dx%d) -> BANK %d at $%04X (%d bytes)\n", 
                             fileName, width, height, currentBank, bankAddr, pixels.length));

        } else {
            // Normal mode: output HEX to ASM
            string hexData = "";
            int pixelCount = 0;
            
            import std.format;
            foreach(gtColor; pixels) {
                if(pixelCount > 0 && pixelCount % 16 == 0) {
                    hexData ~= "\n    HEX ";
                } else if(pixelCount == 0) {
                    hexData ~= "    HEX ";
                }
                hexData ~= format("%02X", gtColor);
                pixelCount++;
            }

            appendCode("; INCBMP \"" ~ fileName ~ "\" (" ~ to!string(width) ~ "x" ~ to!string(height) ~ ", 8-bit indexed)\n");
            appendCode(hexData ~ "\n");
        }
    }
}
