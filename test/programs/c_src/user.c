/*
 * user.c allows you to write a program that runs on the ocpu using the cc65 pipeline.
 * 
 * write your program here, then run:
 * tools\run_c.ps1
 *
 * the run_c.ps1 wrapper does three things:
 *   1. compiles this file with cc65 + translate_6502.py + ocpu_asm.py
 *   2. runs it in cocotb on the actual ocpu rtl
 *   3. prints the full final state: a/x/y/sp/sr, the current iram page,
 *      every page the fpga model shipped to the cpu, and the entire
 *      dram contents (initial + everything the program wrote).
 *
 * working:
 *   - global `unsigned char` variables and arrays (DATA / BSS)
 *   - straight-line code: assignments, `+`, `-`, `&`, `|`, `^`
 *   - `if` / `else` with a single comparison (`>`, `<`, `==`, `!=`,
 *     `>=`, `<=`) — the translator auto-routes cross-page branches
 *     through inverted-skip + FARJMP bridges
 *   - indexed reads/writes on global arrays where the index is a
 *     literal (`arr[3] = arr[5];`) — cc65 lowers these to plain
 *     absolute loads/stores
 *   - unrolled fixed-count loops (copy-paste the body N times)
 *
 * not working yet:
 *   - local variables and function parameters (cc65 spills them onto
 *     a software stack reached via `c_sp` indirect-Y; we have no port
 *     of cc65's runtime)
 *   - `for (i = ...; i < N; i++)` loops, because `i` ends up on that
 *     same software stack
 *   - multiplication / division / modulo / shifts (`*`, `/`, `%`,
 *     `<<`, `>>`). these are NOT 6502 instructions — cc65 emits
 *     `jsr mulax`/`jsr divax`/`jsr shrax1` runtime calls, and our cpu
 *     has neither a barrel shifter (the ALU literally has no shift
 *     path wired into ST_DECODE) nor a port of the runtime library
 *   - 16-bit ints, signed comparisons of large values, pointers, and
 *     calls into your own helper functions
 *
 * stick to globals plus arithmetic and the example pattern below.
 */

// example program below
// this program is a simple sensor fusion algorithm that:
// - computes a checksum across all sensor values
// - tracks the maximum and minimum sensor readings
// - generates warnings for high sensor values
// - generates errors for critical sensor values
// - sets status flags based on sensor thresholds
// - computes a parity value from sensor data
// - performs a simple average-style accumulation
// - writes diagnostic results into a framebuffer
// - updates a small control-state machine
// - exercises array accesses, branching, and global-state updates 
unsigned char sensors[16] = {
    12, 44, 91, 3,
    77, 18, 200, 5,
    66, 99, 101, 42,
    88, 1, 250, 17
};

unsigned char framebuffer[32] = {
    0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0
};

unsigned char checksum;
unsigned char warnings;
unsigned char errors;
unsigned char state;
unsigned char temp;
unsigned char temp2;
unsigned char max_value;
unsigned char min_value;
unsigned char average;
unsigned char parity;
unsigned char control;
unsigned char counter;
unsigned char status;

/* helper globals */
unsigned char a0;
unsigned char a1;
unsigned char a2;
unsigned char a3;
unsigned char a4;
unsigned char a5;
unsigned char a6;
unsigned char a7;

void main(void)
{
    checksum = 0;
    warnings = 0;
    errors = 0;
    state = 0;
    average = 0;
    parity = 0;
    control = 0;
    counter = 0;
    status = 0;

    max_value = 0;
    min_value = 255;

    /* ---- load sensor cache ---- */

    a0 = sensors[0];
    a1 = sensors[1];
    a2 = sensors[2];
    a3 = sensors[3];
    a4 = sensors[4];
    a5 = sensors[5];
    a6 = sensors[6];
    a7 = sensors[7];

    /* ---- checksum block ---- */

    checksum = checksum + a0;
    checksum = checksum + a1;
    checksum = checksum + a2;
    checksum = checksum + a3;
    checksum = checksum + a4;
    checksum = checksum + a5;
    checksum = checksum + a6;
    checksum = checksum + a7;

    checksum = checksum ^ sensors[8];
    checksum = checksum ^ sensors[9];
    checksum = checksum ^ sensors[10];
    checksum = checksum ^ sensors[11];
    checksum = checksum ^ sensors[12];
    checksum = checksum ^ sensors[13];
    checksum = checksum ^ sensors[14];
    checksum = checksum ^ sensors[15];

    /* ---- max tracker ---- */

    if (a0 > max_value) { max_value = a0; }
    if (a1 > max_value) { max_value = a1; }
    if (a2 > max_value) { max_value = a2; }
    if (a3 > max_value) { max_value = a3; }
    if (a4 > max_value) { max_value = a4; }
    if (a5 > max_value) { max_value = a5; }
    if (a6 > max_value) { max_value = a6; }
    if (a7 > max_value) { max_value = a7; }

    if (sensors[8]  > max_value) { max_value = sensors[8];  }
    if (sensors[9]  > max_value) { max_value = sensors[9];  }
    if (sensors[10] > max_value) { max_value = sensors[10]; }
    if (sensors[11] > max_value) { max_value = sensors[11]; }
    if (sensors[12] > max_value) { max_value = sensors[12]; }
    if (sensors[13] > max_value) { max_value = sensors[13]; }
    if (sensors[14] > max_value) { max_value = sensors[14]; }
    if (sensors[15] > max_value) { max_value = sensors[15]; }

    /* ---- min tracker ---- */

    if (a0 < min_value) { min_value = a0; }
    if (a1 < min_value) { min_value = a1; }
    if (a2 < min_value) { min_value = a2; }
    if (a3 < min_value) { min_value = a3; }
    if (a4 < min_value) { min_value = a4; }
    if (a5 < min_value) { min_value = a5; }
    if (a6 < min_value) { min_value = a6; }
    if (a7 < min_value) { min_value = a7; }

    if (sensors[8]  < min_value) { min_value = sensors[8];  }
    if (sensors[9]  < min_value) { min_value = sensors[9];  }
    if (sensors[10] < min_value) { min_value = sensors[10]; }
    if (sensors[11] < min_value) { min_value = sensors[11]; }
    if (sensors[12] < min_value) { min_value = sensors[12]; }
    if (sensors[13] < min_value) { min_value = sensors[13]; }
    if (sensors[14] < min_value) { min_value = sensors[14]; }
    if (sensors[15] < min_value) { min_value = sensors[15]; }

    /* ---- warning/error logic ---- */

    if (a0 > 100) { warnings = warnings + 1; }
    if (a1 > 100) { warnings = warnings + 1; }
    if (a2 > 100) { warnings = warnings + 1; }
    if (a3 > 100) { warnings = warnings + 1; }

    if (sensors[10] > 120) { warnings = warnings + 1; }
    if (sensors[14] > 200) { errors = errors + 1; }

    if (sensors[6] > 180) {
        errors = errors + 1;
        state = state | 1;
    } else {
        state = state ^ 2;
    }

    if (max_value > 240) {
        status = status | 128;
    } else {
        status = status | 1;
    }

    if (min_value < 5) {
        status = status | 64;
    }

    /* ---- parity generation ---- */

    parity = parity ^ sensors[0];
    parity = parity ^ sensors[1];
    parity = parity ^ sensors[2];
    parity = parity ^ sensors[3];
    parity = parity ^ sensors[4];
    parity = parity ^ sensors[5];
    parity = parity ^ sensors[6];
    parity = parity ^ sensors[7];

    /* ---- fake averaging ---- */
    /* no division available, so approximate */

    average = 0;

    average = average + sensors[0];
    average = average + sensors[1];
    average = average + sensors[2];
    average = average + sensors[3];

    average = average + sensors[4];
    average = average + sensors[5];
    average = average + sensors[6];
    average = average + sensors[7];

    average = average + 8;

    /* ---- framebuffer writes ---- */

    framebuffer[0]  = checksum;
    framebuffer[1]  = warnings;
    framebuffer[2]  = errors;
    framebuffer[3]  = max_value;
    framebuffer[4]  = min_value;
    framebuffer[5]  = parity;
    framebuffer[6]  = average;
    framebuffer[7]  = status;

    framebuffer[8]  = sensors[0]  ^ checksum;
    framebuffer[9]  = sensors[1]  ^ checksum;
    framebuffer[10] = sensors[2]  ^ checksum;
    framebuffer[11] = sensors[3]  ^ checksum;

    framebuffer[12] = sensors[4]  + warnings;
    framebuffer[13] = sensors[5]  + warnings;
    framebuffer[14] = sensors[6]  + warnings;
    framebuffer[15] = sensors[7]  + warnings;

    framebuffer[16] = sensors[8]  | state;
    framebuffer[17] = sensors[9]  | state;
    framebuffer[18] = sensors[10] | state;
    framebuffer[19] = sensors[11] | state;

    framebuffer[20] = sensors[12] & 127;
    framebuffer[21] = sensors[13] & 127;
    framebuffer[22] = sensors[14] & 127;
    framebuffer[23] = sensors[15] & 127;

    framebuffer[24] = framebuffer[0] ^ framebuffer[8];
    framebuffer[25] = framebuffer[1] ^ framebuffer[9];
    framebuffer[26] = framebuffer[2] ^ framebuffer[10];
    framebuffer[27] = framebuffer[3] ^ framebuffer[11];

    framebuffer[28] = framebuffer[4] + framebuffer[12];
    framebuffer[29] = framebuffer[5] + framebuffer[13];
    framebuffer[30] = framebuffer[6] + framebuffer[14];
    framebuffer[31] = framebuffer[7] + framebuffer[15];

    /* ---- control state machine ---- */

    control = 0;

    if (errors > 0) {
        control = control | 128;
    } else {
        control = control | 1;
    }

    if (warnings > 2) {
        control = control | 64;
    }

    if (checksum == 0) {
        control = control | 32;
    } else {
        control = control ^ 4;
    }

    counter = 0;

    counter = counter + 1;
    counter = counter + 1;
    counter = counter + 1;
    counter = counter + 1;
    counter = counter + 1;
    counter = counter + 1;
    counter = counter + 1;
    counter = counter + 1;

    framebuffer[0] = framebuffer[0] ^ control;
    framebuffer[1] = framebuffer[1] + counter;
    framebuffer[2] = framebuffer[2] | state;
    framebuffer[3] = framebuffer[3] & 254;
}