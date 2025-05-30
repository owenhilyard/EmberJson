from .utils import *
from memory import UnsafePointer
from math import iota
from .simd import *
from .tables import *
from memory import memcpy
from memory.unsafe import bitcast, pack_bits, _uint
from bit import count_trailing_zeros
from sys.info import bitwidthof
from sys.intrinsics import _type_is_eq

alias smallest_power: Int64 = -342
alias largest_power: Int64 = 308


alias TRUE: UInt32 = 0x65757274
alias ALSE: UInt32 = 0x65736C61
alias NULL: UInt32 = 0x6C6C756E
alias SOL = to_byte("/")
alias B = to_byte("b")
alias F = to_byte("f")
alias N = to_byte("n")
alias R = to_byte("r")
alias T = to_byte("t")
alias U = to_byte("u")
alias acceptable_escapes = ByteVec[16](QUOTE, RSOL, SOL, B, F, N, R, T, U, U, U, U, U, U, U, U)
alias DOT = to_byte(".")
alias PLUS = to_byte("+")
alias NEG = to_byte("-")
alias ZERO_CHAR = to_byte("0")


@always_inline
fn append_digit(v: Scalar, to_add: Scalar) -> __type_of(v):
    return (10 * v) + to_add.cast[v.element_type]()


fn isdigit(char: Byte) -> Bool:
    alias ord_0 = to_byte("0")
    alias ord_9 = to_byte("9")
    return ord_0 <= char <= ord_9


@always_inline
fn is_numerical_component(char: Byte) -> Bool:
    return isdigit(char) or char == PLUS or char == NEG


alias Bits_T = Scalar[_uint(SIMD8_WIDTH)]


@always_inline
fn get_non_space_bits(s: SIMD8xT) -> Bits_T:
    var vec = (s == SPACE) | (s == NEWLINE) | (s == TAB) | (s == CARRIAGE)
    return ~pack_into_integer(vec)


@always_inline
fn pack_into_integer(simd: SIMDBool) -> Bits_T:
    return Bits_T(pack_bits(simd))


@always_inline
fn first_true(simd: SIMDBool) -> Bits_T:
    return count_trailing_zeros(pack_into_integer(simd))


@always_inline
fn ptr_dist(start: BytePtr, end: BytePtr) -> Int:
    return Int(end) - Int(start)


@register_passable("trivial")
struct StringBlock:
    alias BitMask = SIMD[DType.bool, SIMD8_WIDTH]

    var bs_bits: Bits_T
    var quote_bits: Bits_T
    var unescaped_bits: Bits_T

    fn __init__(out self, bs: Self.BitMask, qb: Self.BitMask, un: Self.BitMask):
        self.bs_bits = pack_into_integer(bs)
        self.quote_bits = pack_into_integer(qb)
        self.unescaped_bits = pack_into_integer(un)

    @always_inline
    fn quote_index(self) -> Bits_T:
        return count_trailing_zeros(self.quote_bits)

    @always_inline
    fn bs_index(self) -> Bits_T:
        return count_trailing_zeros(self.bs_bits)

    @always_inline
    fn unescaped_index(self) -> Bits_T:
        return count_trailing_zeros(self.unescaped_bits)

    @always_inline
    fn has_quote_first(self) -> Bool:
        return count_trailing_zeros(self.quote_bits) < count_trailing_zeros(self.bs_bits) and not self.has_unescaped()

    @always_inline
    fn has_backslash(self) -> Bool:
        return count_trailing_zeros(self.bs_bits) < count_trailing_zeros(self.quote_bits)

    @always_inline
    fn has_unescaped(self) -> Bool:
        return count_trailing_zeros(self.unescaped_bits) < count_trailing_zeros(self.quote_bits)

    @staticmethod
    @always_inline
    fn find(out block: StringBlock, src: BytePtr):
        var v = src.load[width=SIMD8_WIDTH]()
        alias LAST_ESCAPE_CHAR: UInt8 = 31
        block = StringBlock(v == RSOL, v == QUOTE, v <= LAST_ESCAPE_CHAR)


@always_inline
fn hex_to_u32(p: BytePtr) -> UInt32:
    var v = p.load[width=4]().cast[DType.uint32]()
    v = (v & 0xF) + 9 * (v >> 6)
    alias shifts = SIMD[DType.uint32, 4](12, 8, 4, 0)
    v <<= shifts
    return v.reduce_or()


fn handle_unicode_codepoint(mut p: BytePtr, mut dest: String) raises:
    var c1 = hex_to_u32(p)
    p += 4
    if c1 >= 0xD800 and c1 < 0xDC00:
        if unlikely(p[] != RSOL and (p + 1)[] != U):
            raise Error("Bad unicode codepoint")

        p += 2
        var c2 = hex_to_u32(p)

        if unlikely(Bool((c1 | c2) >> 16)):
            raise Error("Bad unicode codepoint")

        c1 = (((c1 - 0xD800) << 10) | (c2 - 0xDC00)) + 0x10000
        p += 4
    if c1 <= 0x7F:
        dest.append_byte(c1.cast[DType.uint8]())
        return
    elif c1 <= 0x7FF:
        dest.append_byte(((c1 >> 6) + 192).cast[DType.uint8]())
        dest.append_byte(((c1 & 63) + 128).cast[DType.uint8]())
        return
    elif c1 <= 0xFFFF:
        dest.append_byte(((c1 >> 12) + 224).cast[DType.uint8]())
        dest.append_byte((((c1 >> 6) & 63) + 128).cast[DType.uint8]())
        dest.append_byte(((c1 & 63) + 128).cast[DType.uint8]())
        return
    elif c1 <= 0x10FFFF:
        dest.append_byte(((c1 >> 18) + 240).cast[DType.uint8]())
        dest.append_byte((((c1 >> 12) & 63) + 128).cast[DType.uint8]())
        dest.append_byte((((c1 >> 6) & 63) + 128).cast[DType.uint8]())
        dest.append_byte(((c1 & 63) + 128).cast[DType.uint8]())
        return
    else:
        raise Error("Invalid unicode")


@always_inline
fn copy_to_string[
    ignore_unicode: Bool = False
](out s: String, start: BytePtr, end: BytePtr, found_unicode: Bool = True) raises:
    var length = ptr_dist(start, end)

    @parameter
    fn decode_unicode(out res: String) raises:
        # This will usually slightly overallocate if the string contains
        # escaped unicode
        var l = String(capacity=length + 1)
        var p = start

        while p < end:
            if p[] == RSOL and p + 1 != end and (p + 1)[] == U:
                p += 2
                handle_unicode_codepoint(p, l)
            else:
                l.append_byte(p[])
                p += 1
        l.append_byte(0)
        res = l^

    @parameter
    fn bulk_copy(out res: String):
        var slice = StringSlice(ptr=start, length=length)
        res = String(bytes=slice.as_bytes())

    @parameter
    if not ignore_unicode:
        if found_unicode:
            return decode_unicode()
        else:
            return bulk_copy()
    else:
        return bulk_copy()


@always_inline
fn is_exp_char(char: Byte) -> Bool:
    return char == LOW_E or char == UPPER_E


@always_inline
fn is_sign_char(char: Byte) -> Bool:
    return char == PLUS or char == NEG


@always_inline
fn is_made_of_eight_digits_fast(src: BytePtr) -> Bool:
    """Don't ask me how this works."""
    var val: UInt64 = 0
    unsafe_memcpy(val, src)
    return ((val & 0xF0F0F0F0F0F0F0F0) | (((val + 0x0606060606060606) & 0xF0F0F0F0F0F0F0F0) >> 4)) == 0x3333333333333333


@always_inline
fn to_double(out d: Float64, owned mantissa: UInt64, real_exponent: UInt64, negative: Bool):
    alias `1 << 52` = 1 << 52
    mantissa &= ~(`1 << 52`)
    mantissa |= real_exponent << 52
    mantissa |= Int(negative) << 63
    d = bitcast[DType.float64](mantissa)


@always_inline
fn parse_eight_digits(out val: UInt64, p: BytePtr):
    """Don't ask me how this works."""
    val = 0
    unsafe_memcpy(val, p)
    val = (val & 0x0F0F0F0F0F0F0F0F) * 2561 >> 8
    val = (val & 0x00FF00FF00FF00FF) * 6553601 >> 16
    val = (val & 0x0000FFFF0000FFFF) * 42949672960001 >> 32


@always_inline
fn parse_digit(out dig: Bool, p: BytePtr, mut i: Scalar):
    dig = isdigit(p[])
    i = branchless_ternary(dig, i * 10 + (p[] - ZERO_CHAR).cast[i.dtype](), i)


@always_inline
fn significant_digits(p: BytePtr, digit_count: Int) -> Int:
    var start = p
    while start[] == ZERO_CHAR or start[] == DOT:
        start += 1

    return digit_count - ptr_dist(p, start)
