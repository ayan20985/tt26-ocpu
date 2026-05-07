#!/usr/bin/env python3

import sys
from pathlib import Path

OPCODES = {
    ("lda", "imm"): 0x00,
    ("lda", "abs"): 0x01,
    ("lda", "abs_x"): 0x02,
    ("lda", "ind_y"): 0x03,
    ("ldx", "imm"): 0x04,
    ("ldx", "abs"): 0x05,
    ("ldy", "imm"): 0x06,
    ("ldy", "abs"): 0x07,
    ("sta", "abs"): 0x08,
    ("sta", "abs_x"): 0x09,
    ("sta", "ind_y"): 0x0A,
    ("stx", "abs"): 0x0B,
    ("sty", "abs"): 0x0C,
    ("adc", "abs"): 0x0D,
    ("sbc", "abs"): 0x0E,
    ("and", "abs"): 0x0F,
    ("eor", "abs"): 0x10,
    ("ora", "abs"): 0x11,
    ("asl", "imp"): 0x12,
    ("lsr", "imp"): 0x13,
    ("inx", "imp"): 0x14,
    ("dex", "imp"): 0x15,
    ("iny", "imp"): 0x16,
    ("dey", "imp"): 0x17,
    ("tax", "imp"): 0x18,
    ("txa", "imp"): 0x19,
    ("tay", "imp"): 0x1A,
    ("tya", "imp"): 0x1B,
    ("sec", "imp"): 0x1C,
    ("clc", "imp"): 0x1D,
    ("sei", "imp"): 0x1E,
    ("cli", "imp"): 0x1F,
    ("jmp", "abs"): 0x20,
    ("jsr", "abs"): 0x21,
    ("rts", "imp"): 0x22,
    ("rti", "imp"): 0x23,
    ("pha", "imp"): 0x24,
    ("pla", "imp"): 0x25,
    ("beq", "rel"): 0x26,
    ("bne", "rel"): 0x27,
    ("bcs", "rel"): 0x28,
    ("bcc", "rel"): 0x29,
}


def parse_number(token):
    token = token.strip()
    if token.startswith("$"):
        return int(token[1:], 16)
    if token.startswith("0x"):
        return int(token[2:], 16)
    if token.startswith("%"):
        return int(token[1:], 2)
    return int(token, 10)


def split_tokens(line):
    if ";" in line:
        line = line.split(";", 1)[0]
    line = line.strip()
    if not line:
        return []
    return line.split()


def parse_operand(text):
    text = text.strip()
    if text.startswith("#"):
        return "imm", text[1:].strip()
    if text.startswith("(") and text.endswith("),y"):
        inner = text[1:-3].strip()
        return "ind_y", inner
    if text.endswith(",x"):
        return "abs_x", text[:-2].strip()
    if text.startswith("(") and text.endswith(")"):
        return "ind", text[1:-1].strip()
    return "abs", text


def first_pass(lines):
    labels = {}
    pc = 0
    for line in lines:
        if ";" in line:
            line = line.split(";", 1)[0]
        line = line.strip()
        if not line:
            continue
        if ":" in line:
            label, rest = line.split(":", 1)
            labels[label.strip().lower()] = pc
            line = rest.strip()
            if not line:
                continue
        tokens = line.split()
        if not tokens:
            continue
        op = tokens[0].lower()
        if op == ".org" and len(tokens) > 1:
            pc = parse_number(tokens[1])
            continue
        if op == ".byte" and len(tokens) > 1:
            data = " ".join(tokens[1:]).split(",")
            pc += len([x for x in data if x.strip() != ""])
            continue
        if op in ("rts", "rti", "pha", "pla", "tax", "txa", "tay", "tya", "inx", "dex", "iny", "dey", "sec", "clc", "sei", "cli", "asl", "lsr"):
            pc += 1
            continue
        if op in ("beq", "bne", "bcs", "bcc"):
            pc += 2
            continue
        if len(tokens) > 1 and tokens[1].startswith("#"):
            pc += 2
        else:
            mode, _ = parse_operand(" ".join(tokens[1:]))
            if mode in ("abs", "abs_x"):
                pc += 3
            elif mode in ("ind_y",):
                pc += 2
            else:
                pc += 2
    return labels


def resolve_operand(value, labels):
    value = value.strip()
    key = value.lower()
    if key in labels:
        return labels[key]
    return parse_number(value)


def second_pass(lines, labels):
    pc = 0
    output = bytearray()
    for line in lines:
        raw = line
        if ";" in line:
            line = line.split(";", 1)[0]
        line = line.strip()
        if not line:
            continue
        if ":" in line:
            _, line = line.split(":", 1)
            line = line.strip()
            if not line:
                continue
        tokens = line.split()
        if not tokens:
            continue
        op = tokens[0].lower()
        if op == ".org" and len(tokens) > 1:
            pc = parse_number(tokens[1])
            if pc > len(output):
                output.extend(b"\x00" * (pc - len(output)))
            continue
        if op == ".byte" and len(tokens) > 1:
            data = " ".join(tokens[1:]).split(",")
            for item in data:
                item = item.strip()
                if item == "":
                    continue
                output.append(resolve_operand(item, labels) & 0xff)
                pc += 1
            continue
        if op in ("rts", "rti", "pha", "pla", "tax", "txa", "tay", "tya", "inx", "dex", "iny", "dey", "sec", "clc", "sei", "cli", "asl", "lsr"):
            output.append(OPCODES[(op, "imp")])
            pc += 1
            continue
        if op in ("beq", "bne", "bcs", "bcc"):
            if len(tokens) < 2:
                raise ValueError(f"missing branch target on line: {raw}")
            target = resolve_operand(tokens[1], labels)
            offset = target - (pc + 2)
            if offset < -128 or offset > 127:
                raise ValueError(f"branch out of range on line: {raw}")
            output.append(OPCODES[(op, "rel")])
            output.append(offset & 0xff)
            pc += 2
            continue

        if len(tokens) < 2:
            raise ValueError(f"missing operand on line: {raw}")
        mode, operand_text = parse_operand(" ".join(tokens[1:]))
        if mode == "imm":
            opcode = OPCODES.get((op, "imm"))
            if opcode is None:
                raise ValueError(f"unsupported immediate form on line: {raw}")
            value = resolve_operand(operand_text, labels) & 0x3f
            output.append(opcode)
            output.append(value)
            pc += 2
        elif mode == "abs_x":
            opcode = OPCODES.get((op, "abs_x"))
            if opcode is None:
                raise ValueError(f"unsupported abs,x form on line: {raw}")
            value = resolve_operand(operand_text, labels) & 0x0fff
            output.append(opcode)
            output.append(value & 0x3f)
            output.append((value >> 6) & 0x3f)
            pc += 3
        elif mode == "ind_y":
            opcode = OPCODES.get((op, "ind_y"))
            if opcode is None:
                raise ValueError(f"unsupported (addr),y form on line: {raw}")
            value = resolve_operand(operand_text, labels) & 0x3f
            output.append(opcode)
            output.append(value)
            pc += 2
        else:
            opcode = OPCODES.get((op, "abs"))
            if opcode is None:
                raise ValueError(f"unsupported absolute form on line: {raw}")
            value = resolve_operand(operand_text, labels) & 0x0fff
            output.append(opcode)
            output.append(value & 0x3f)
            output.append((value >> 6) & 0x3f)
            pc += 3
    return bytes(output)


def main():
    if len(sys.argv) < 3:
        print("usage: ocpu_asm.py <input.ocpu> <output.mach>")
        return 1
    src_path = Path(sys.argv[1])
    out_path = Path(sys.argv[2])
    lines = src_path.read_text().splitlines()
    labels = first_pass(lines)
    data = second_pass(lines, labels)
    out_path.write_bytes(data)
    txt_path = Path(str(out_path) + ".txt")
    with txt_path.open("w") as handle:
        for offset in range(0, len(data), 16):
            chunk = data[offset:offset + 16]
            hex_bytes = " ".join(f"{b:02x}" for b in chunk)
            handle.write(f"{offset:04x}: {hex_bytes}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
