"""cocotb testbench for json_parser.

Every document is fed to the hardware one byte at a time and also parsed by
Python's own `json` module. The two must agree on whether the document is
valid and, if it is, on the exact sequence of events.
"""

import json
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, Timer

MAX_DEPTH = 16
INT32_MIN, INT32_MAX = -(2**31), 2**31 - 1

EV_NAMES = [
    "OBJ_START", "OBJ_END", "ARR_START", "ARR_END", "KEY_START", "STR_START",
    "STR_CHAR", "STR_END", "NUMBER", "TRUE", "FALSE", "NULL",
]


# --------------------------------------------------------------- reference

class Obj(list):
    """A JSON object kept as an ordered list of (key, value) pairs."""


class Unsupported(Exception):
    pass


def _reject(_text):
    raise Unsupported


def reference(text):
    """Return the expected event list, or None if the parser must reject."""
    try:
        tree = json.loads(
            text,
            object_pairs_hook=Obj,     # keep key order and duplicate keys
            parse_float=_reject,       # 1.5 and 1e3 are not supported
            parse_constant=_reject,    # NaN and Infinity are not JSON
        )
    except (ValueError, Unsupported, RecursionError):
        return None

    events = []

    def walk(node, depth):
        if isinstance(node, Obj):
            if depth == MAX_DEPTH:
                raise Unsupported
            events.append(("OBJ_START",))
            for key, value in node:
                events.append(("KEY", key))
                walk(value, depth + 1)
            events.append(("OBJ_END",))
        elif isinstance(node, list):
            if depth == MAX_DEPTH:
                raise Unsupported
            events.append(("ARR_START",))
            for value in node:
                walk(value, depth + 1)
            events.append(("ARR_END",))
        elif isinstance(node, str):
            events.append(("STR", node))
        elif node is True:
            events.append(("TRUE",))
        elif node is False:
            events.append(("FALSE",))
        elif node is None:
            events.append(("NULL",))
        else:
            if not INT32_MIN <= node <= INT32_MAX:
                raise Unsupported
            events.append(("NUMBER", node))

    try:
        walk(tree, 0)
    except Unsupported:
        return None
    return events


# ------------------------------------------------------------------ driver

async def run_doc(dut, data, gap_prob=0.0):
    """Feed one document. Returns (raw hardware events, error flag)."""
    events = []
    i = 0
    for _ in range(20 * len(data) + 200):
        if i < len(data) and random.random() >= gap_prob:
            dut.in_valid.value = 1
            dut.in_byte.value = data[i]
            dut.in_last.value = int(i == len(data) - 1)
            await Timer(1, unit="ns")              # let in_ready settle
            accepted = dut.in_ready.value == 1
        else:
            dut.in_valid.value = 0                 # idle: inputs must be ignored
            dut.in_byte.value = random.randrange(256)
            dut.in_last.value = random.randrange(2)
            accepted = False

        await FallingEdge(dut.clk)                 # the rising edge is in between
        if accepted:
            i += 1
        if dut.ev_valid.value == 1:
            events.append((EV_NAMES[int(dut.ev_type.value)], dut.ev_data.value))
        if dut.done.value == 1:
            assert i == len(data), "done before the last byte was taken"
            dut.in_valid.value = 0
            return events, dut.error.value == 1
    raise AssertionError(f"parser never finished: {data!r}")


def fold(raw_events):
    """Turn raw hardware events into the reference's form (strings joined)."""
    out = []
    kind = None
    chars = bytearray()
    for name, data in raw_events:
        if name in ("KEY_START", "STR_START"):
            assert kind is None, "string started inside a string"
            kind = "KEY" if name == "KEY_START" else "STR"
            chars = bytearray()
        elif name == "STR_CHAR":
            assert kind is not None, "STR_CHAR outside a string"
            chars.append(int(data) & 0xFF)
        elif name == "STR_END":
            assert kind is not None, "STR_END outside a string"
            # The hardware passes escapes through untouched; decode them here.
            out.append((kind, json.loads('"' + chars.decode("utf-8") + '"')))
            kind = None
        elif name == "NUMBER":
            out.append(("NUMBER", data.to_signed()))
        else:
            out.append((name,))
    assert kind is None, "string never ended"
    return out


async def check(dut, text, gap_prob=0.0):
    """Run one document and compare against the reference. Returns validity."""
    expected = reference(text)
    raw, error = await run_doc(dut, text.encode("utf-8"), gap_prob)
    if expected is None:
        assert error, f"accepted an invalid document: {text!r}"
    else:
        assert not error, f"rejected a valid document: {text!r}"
        got = fold(raw)
        assert got == expected, f"wrong events for {text!r}\n got {got}\n exp {expected}"
    return expected is not None


async def start(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst.value = 1
    dut.in_valid.value = 0
    dut.in_byte.value = 0
    dut.in_last.value = 0
    for _ in range(3):
        await FallingEdge(dut.clk)
    dut.rst.value = 0
    await FallingEdge(dut.clk)


# ------------------------------------------------------- random documents

STRING_ALPHABET = list("abcXYZ019 _-{}[]:,\"\\/\n\t\r\b\f\x01\x1f") + ["é", "あ", "😀"]
INTERESTING_INTS = [0, 1, -1, 9, 10, 127, -128, 2**31 - 1, -(2**31), 1000000007]


def random_string():
    return "".join(random.choice(STRING_ALPHABET) for _ in range(random.randrange(8)))


def random_value(depth):
    kinds = ["int", "int", "str", "true", "false", "null"]
    if depth < 5:
        kinds += ["arr", "obj", "arr", "obj"]
    kind = random.choice(kinds)
    if kind == "int":
        if random.random() < 0.4:
            return random.choice(INTERESTING_INTS)
        return random.randint(INT32_MIN, INT32_MAX)
    if kind == "str":
        return random_string()
    if kind == "arr":
        return [random_value(depth + 1) for _ in range(random.randrange(4))]
    if kind == "obj":
        return {random_string(): random_value(depth + 1) for _ in range(random.randrange(4))}
    return {"true": True, "false": False, "null": None}[kind]


def random_document():
    text = json.dumps(
        random_value(0),
        indent=random.choice([None, None, 0, 1, 3, "\t"]),
        separators=random.choice([None, (",", ":"), (" , ", " : ")]),
        ensure_ascii=random.choice([True, False]),
    )
    pad = " \t\r\n"
    return (
        "".join(random.choice(pad) for _ in range(random.randrange(3)))
        + text
        + "".join(random.choice(pad) for _ in range(random.randrange(3)))
    )


MUTATION_CHARS = list('{}[]":,\\ \n0123456789-+.eEtfnrualsxAF\x00\x1f')


def mutate(text):
    """Damage a document slightly: most results are invalid, some stay valid."""
    chars = list(text)
    for _ in range(random.choice([1, 1, 1, 2, 3])):
        op = random.choice(["delete", "insert", "replace", "truncate"])
        pos = random.randrange(len(chars)) if chars else 0
        if op == "delete" and len(chars) > 1:
            del chars[pos]
        elif op == "insert":
            chars.insert(pos, random.choice(MUTATION_CHARS))
        elif op == "replace" and chars:
            chars[pos] = random.choice(MUTATION_CHARS)
        elif op == "truncate" and len(chars) > 1:
            del chars[max(1, pos):]
    return "".join(chars) or " "


# ------------------------------------------------------------------- tests

VALID = [
    "0", "7", "-0", "-12", "2147483647", "-2147483648",
    "true", "false", "null", '""', '"hi"',
    "[]", "{}", "[ ]", "{ }", " [1] ", "[1,2,3]", "[1 , 2\n,\t3]",
    '{"a":1}', '{"a": [1, true]}', '{"a":{"b":{"c":[]}}}',
    '{"a":1,"a":2}', '{"":""}',
    '["\\"", "\\\\", "\\/", "\\b\\f\\n\\r\\t", "\\u00e9", "\\uD83D\\uDE00", "\\uabCD"]',
    '["{", "}", "[", "]", ":", ",", "tru", "12"]',
    '[[[[[[[[[[[[[[[[1]]]]]]]]]]]]]]]]',                    # depth 16: the limit
    '[true,false,null,-1,0,"x",[],{}]',
    "[10,200,3000]", "12 ", "[0]", "[-0]", "é".join(['"', '"']),
]

INVALID = [
    " ", "\n", "[", "]", "{", "}", "[1", "[1,", "[1,]", "[,1]", "[1 2]", "[1]]", "[}",
    "{]", '{"a"}', '{"a":}', '{"a":1,}', '{,}', "{1:2}", '{"a" 1}', '{"a":1 "b":2}',
    '{"a":1}}', '"abc', '"a\\x"', '"a\\u12"', '"a\\u12g4"', '"\\', '"tab\there"',
    '"line\nbreak"', "tru", "truee", "True", "nul", "fals", "falsy", "nulll",
    "-", "--1", "+1", "01", "-01", "00", "1.5", "1e3", "1E3", "-1.0", ".5", "1.",
    "2147483648", "-2147483649", "99999999999", "4294967296", "12345678901234567890",
    "1 2", "[] []", "{} x", "NaN", "Infinity", "-Infinity", "'a'", "[1,2,3",
    "[[[[[[[[[[[[[[[[[1]]]]]]]]]]]]]]]]]",                  # depth 17: too deep
    '[{"a":[{"b":[{"c":[{"d":[{"e":[{"f":[{"g":[{"h":[{"i":1}]}]}]}]}]}]}]}]}]',
    "[1,2}", '{"a":[1,2}', "\x00", "[\x0b]",
]


@cocotb.test()
async def directed_valid(dut):
    """Hand-written valid documents."""
    await start(dut)
    for text in VALID:
        assert reference(text) is not None, f"test bug, reference rejects {text!r}"
        await check(dut, text)


@cocotb.test()
async def directed_invalid(dut):
    """Hand-written invalid documents, each followed by a valid one."""
    await start(dut)
    for text in INVALID:
        assert reference(text) is None, f"test bug, reference accepts {text!r}"
        await check(dut, text)
        await check(dut, '{"ok":[1]}')     # the parser must recover by itself


@cocotb.test()
async def example_events(dut):
    """The example from the top of json_parser.sv, checked event by event."""
    await start(dut)
    raw, error = await run_doc(dut, b'{"a": [1, true]}')
    assert not error
    assert [(name, int(data)) for name, data in raw] == [
        ("OBJ_START", 0), ("KEY_START", 0), ("STR_CHAR", ord("a")), ("STR_END", 0),
        ("ARR_START", 0), ("NUMBER", 1), ("TRUE", 0), ("ARR_END", 0), ("OBJ_END", 0),
    ]


@cocotb.test()
async def random_valid(dut):
    """Random documents, with and without pauses in the input."""
    await start(dut)
    random.seed(1)
    for n in range(1500):
        await check(dut, random_document(), gap_prob=random.choice([0.0, 0.3, 0.7]))
    dut._log.info("1500 random valid documents agree with Python's json")


@cocotb.test()
async def random_mutated(dut):
    """Damaged documents: accept or reject exactly as the reference does."""
    await start(dut)
    random.seed(2)
    valid = 0
    total = 4000
    for n in range(total):
        valid += await check(dut, mutate(random_document()), gap_prob=random.choice([0.0, 0.3]))
    dut._log.info(f"{total} mutated documents: {valid} still valid, {total - valid} rejected")
    assert 0 < valid < total


@cocotb.test()
async def reset_mid_document(dut):
    """Reset halfway through a document discards it completely."""
    await start(dut)
    for byte in b'{"a":[[[12':
        dut.in_valid.value = 1
        dut.in_byte.value = byte
        dut.in_last.value = 0
        await FallingEdge(dut.clk)
    dut.in_valid.value = 0
    dut.rst.value = 1
    await FallingEdge(dut.clk)
    dut.rst.value = 0
    await FallingEdge(dut.clk)
    await check(dut, "[1]")
