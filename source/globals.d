module globals;

/** The target machine */
string target = "c64";
/** Whether to assemble a basic loader */
bool basicLoader = true;
/** Program start address */
int startAddress = -1;
/** Variable segment start address (-1 = follows code) */
int variableAddress = -1;
/** If the program exceeds this limit, compilation will fail */
int topAddress = -1;
/** Maximum allowed string length */
const int stringMaxLength = 96;
/** Whether to compile DATA statements at the current origin */
bool inlineData = false;
/** Whether the program uses custom irq routines */
bool useIrqs = false;
/** Fast IRQ option bypasses saving virtual registers before entering the ISR */
bool fastIrqs = false;
/** Whether the program uses sprite routines */
bool useSprites = false;
/** Whether the program uses sound routines */
bool useSound = false;

/** ROM Banking support (GameTank).
  * currentBank tracks which bank the BANK statement has selected (-1 = fixed/code bank).
  * Only set by bank_stmt, which guards for target == "gametank". */
int currentBank = -1;
/** Bank data storage: bankData[bankNum] = raw bytes for INCBMP/INCBIN in that bank */
ubyte[][int] bankData;
/** Banked code storage: bankCode[bankNum] = assembly text for SUB/FUNCTION definitions in that bank */
string[int] bankCode;
/** Maps routine labels to their bank number for trampoline generation */
int[string] routineBankMap;
