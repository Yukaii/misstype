"""Compare two parity.tsv files: exact, except hex doubles in touch cases.

Touch distances come from libm `hypot`, whose last bit differs between libc
builds (macOS, glibc on x86_64 and aarch64), and the scores derived from them
inherit a few ulps (relative 1e-12 allowed). Lines of non-touch cases, and everything that is not a
16-digit hex double (text, indices, tags), must be identical. Prints the
differing lines and exits 1.
"""
import re
import struct
import sys

REL = 1e-12
HEX = re.compile(r'(?<![0-9a-f])([0-9a-f]{16})(?![0-9a-f])')


def value(h):
    return struct.unpack('>d', struct.pack('>Q', int(h, 16)))[0]


def close(a, b):
    if a == b:
        return True
    if '-touch-' not in a.split('\t')[1:2].__str__():
        return False
    if HEX.sub('#', a) != HEX.sub('#', b):
        return False
    return all(abs(value(x) - value(y)) <= REL * max(1.0, abs(value(x)))
               for x, y in zip(HEX.findall(a), HEX.findall(b)))


def main(golden, actual):
    with open(golden) as f, open(actual) as g:
        a, b = f.read().split('\n'), g.read().split('\n')
    bad = int(len(a) != len(b))
    if bad:
        print(f'line count {len(a)} != {len(b)}')
    for i, (x, y) in enumerate(zip(a, b), 1):
        if not close(x, y):
            bad += 1
            if bad <= 40:
                print(f'{i}: -{x}\n{i}: +{y}')
    return 1 if bad else 0


sys.exit(main(*sys.argv[1:3]))
