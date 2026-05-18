/*
 * sum_arr.c - tiny worked example for the c -> 6502 -> ocpu pipeline.
 *
 * keep it small: cc65 + this translator + the 8-slot iram limit make
 * anything beyond a few statements painful to map. this is intended to
 * verify the toolchain shape end-to-end, not to be a useful program.
 */

unsigned char arr[4] = {1, 2, 3, 4};
unsigned char sum;

void main(void) {
    sum = 0;
    sum += arr[0];
    sum += arr[1];
    sum += arr[2];
    sum += arr[3];
}
