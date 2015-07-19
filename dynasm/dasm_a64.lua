------------------------------------------------------------------------------
-- DynASM A64 module.
--
-- Copyright (C) 2005-2014 Mike Pall. All rights reserved.
-- See dynasm.lua for full copyright notice.
--
-- Modification:
-- 3.12.2014 Zenk Ju      Initial port to arm arch64
------------------------------------------------------------------------------

-- Module information:
local _info = {
    arch =        "a64",
    description =        "DynASM ARM64 module",
    version =        "1.3.0",
    vernum =         10300,
    release =        "2014-12-03",
    author =        "Mike Pall",
    license =        "MIT",
}

-- Exported glue functions for the arch-specific module.
local _M = { _info = _info }

-- Cache library functions.
local type, tonumber, pairs, ipairs = type, tonumber, pairs, ipairs
local assert, setmetatable, rawget = assert, setmetatable, rawget
local _s = string
local sub, format, byte, char = _s.sub, _s.format, _s.byte, _s.char
local match, gmatch, gsub = _s.match, _s.gmatch, _s.gsub
local concat, sort, insert = table.concat, table.sort, table.insert
local bit = bit or require("bit")
local band, bor, shl, shr, sar = bit.band, bit.bor, bit.lshift, bit.rshift, bit.arshift
local ror, tohex = bit.ror, bit.tohex

-- Inherited tables and callbacks.
local g_opt, g_arch
local wline, werror, wfatal, wwarn

-- Action name list.
--
-- Any a64 instruction has encoding greater than or equal to 0x08000000,
-- so there're planty of places for actions.
--
-- CHECK: Keep this in sync with the C code!
local action_names = {
    "STOP", "SECTION", "ESC", "REL_EXT",
    "ALIGN", "REL_LG", "LABEL_LG",
    "REL_PC", "LABEL_PC", "IMM",
    "IMMADDROFF", -- Address offset immediate, can be pimm12[10:21] or simm9[12:20]
    "IMMNSR", -- Logical immediate, for N, imms and immr
    "IMMLSB", -- Immediate for bits lsb, immr = -lsb%32
    "IMMWIDTH1", -- Immediate for bits width, imms = width-1
    "IMMWIDTH2", -- Immediate for bits width, imms = lsb + width -1
    "IMMSHIFT", -- immediate for lsl(imm) shift, immr=-shift%64, imms=63-shift(for 32bits, 64/63 is 32/31)
    "IMMMOV", -- immediate for mov instruction, remember to write op
    "IMMTBN", -- immediate for test bit number, b5 at [31] and b40 at [19:23]
    "IMMA2H", -- 8bit immediate encoded in abcdefgh
    "IMMA2H64", -- 64bit immediate encoded in abcdefgh
    "IMMA2HFP", -- floating point constant encoded in abcdefgh
    "IMM8FP", -- floating point constant encoded in imm8[13:20]
    "IMMHLM", -- immhlm with h[11], l[21], m[20], bit width is LSBs of action
    "IMMQSS", --immqss with q[30], s[12], size[10:11]
    "IMMHB", --uimm6[16:21] = 128 - (64+fbits6)/uimm5/uimm4/uimm3
    "IMMSCALE" --uimm6[10:15] = 64 - fbits6/uimm5[10:14] = 64-(32+fbits5)
}

-- Maximum number of section buffer positions for dasm_put().
-- CHECK: Keep this in sync with the C code!
local maxsecpos = 25 -- Keep this low, to avoid excessively long C lines.

-- Action name -> action number.
local map_action = {}
for n,name in ipairs(action_names) do
    map_action[name] = n-1
end

-- Action list buffer.
local actlist = {}

-- Argument list for next dasm_put(). Start with offset 0 into action list.
local actargs = { 0 }

-- Current number of section buffer positions for dasm_put().
local secpos = 1

------------------------------------------------------------------------------

-- Dump action names and numbers.
local function dumpactions(out)
   out:write("DynASM encoding engine action codes:\n")
   for n,name in ipairs(action_names) do
       local num = map_action[name]
       out:write(format("  %-10s %02X  %d\n", name, num, num))
   end
   out:write("\n")
end

-- Write action list buffer as a huge static C array.
local function writeactions(out, name)
    local nn = #actlist
    if nn == 0 then nn = 1; actlist[0] = map_action.STOP end
    out:write("static const unsigned int ", name, "[", nn, "] = {\n")
    for i = 1,nn-1 do
        assert(out:write("0x", tohex(actlist[i]), ",\n"))
    end
    assert(out:write("0x", tohex(actlist[nn]), "\n};\n\n"))
end

------------------------------------------------------------------------------

-- Add word to action list.
local function wputxw(n)
    assert(n >= 0 and n <= 0xffffffff and n % 1 == 0, "word out of range")
    actlist[#actlist+1] = n
end

-- Add action to list with optional arg. Advance buffer pos, too.
local function waction(action, val, a, num)
    local w = assert(map_action[action], "bad action name `"..action.."'")
    wputxw(w * 0x10000 + (val or 0))
    if a then actargs[#actargs+1] = a end
    if a or num then secpos = secpos + (num or 1) end
end

local function wactionl(action, val, a, num)
    waction(action, val, a and "(long)("..a..")" or a, num)
end

local function wactiond(action, val, a, num)
    waction(action, val, "d2l("..a..")", num)
end

-- Flush action list (intervening C code or buffer pos overflow).
local function wflush(term)
    if #actlist == actargs[1] then return end -- Nothing to flush.
    if not term then waction("STOP") end -- Terminate action list.
    wline(format("dasm_put(Dst, %s);", concat(actargs, ", ")), true)
    actargs = { #actlist } -- Actionlist offset is 1st arg to next dasm_put().
    secpos = 1 -- The actionlist offset occupies a buffer position, too.
end

-- Put escaped word.
local function wputw(n)
    if n <= 0x000fffff then waction("ESC") end
    wputxw(n)
end

-- Reserve position for word.
local function wpos()
    local pos = #actlist+1
    actlist[pos] = ""
    return pos
end

-- Store word to reserved position.
local function wputpos(pos, n)
    assert(n >= 0 and n <= 0xffffffff and n % 1 == 0, "word out of range")
    if n <= 0x000fffff then
        insert(actlist, pos+1, n)
        n = map_action.ESC * 0x10000
    end
    actlist[pos] = n
end

------------------------------------------------------------------------------

-- Global label name -> global label number. With auto assignment on 1st use.
local next_global = 20
local map_global = setmetatable({}, { __index = function(t, name)
    if not match(name, "^[%a_][%w_]*$") then werror("bad global label") end
    local n = next_global
    if n > 2047 then werror("too many global labels") end
    next_global = n + 1
    t[name] = n
    return n
  end})

-- Dump global labels.
local function dumpglobals(out, lvl)
    local t = {}
    for name, n in pairs(map_global) do t[n] = name end
    out:write("Global labels:\n")
    for i=20,next_global-1 do
        out:write(format("  %s\n", t[i]))
    end
    out:write("\n")
end

-- Write global label enum.
local function writeglobals(out, prefix)
    local t = {}
    for name, n in pairs(map_global) do t[n] = name end
    out:write("enum {\n")
    for i=20,next_global-1 do
        out:write("  ", prefix, t[i], ",\n")
    end
    out:write("  ", prefix, "_MAX\n};\n")
end

-- Write global label names.
local function writeglobalnames(out, name)
    local t = {}
    for name, n in pairs(map_global) do t[n] = name end
    out:write("static const char *const ", name, "[] = {\n")
    for i=20,next_global-1 do
        out:write("  \"", t[i], "\",\n")
    end
    out:write("  (const char *)0\n};\n")
end

------------------------------------------------------------------------------

-- Extern label name -> extern label number. With auto assignment on 1st use.
local next_extern = 0
local map_extern_ = {}
local map_extern = setmetatable({}, { __index = function(t, name)
                                         -- No restrictions on the name for now.
                                         local n = next_extern
                                         if n > 2047 then werror("too many extern labels") end
                                         next_extern = n + 1
                                         t[name] = n
                                         map_extern_[n] = name
                                         return n
                               end})

-- Dump extern labels.
local function dumpexterns(out, lvl)
    out:write("Extern labels:\n")
    for i=0,next_extern-1 do
        out:write(format("  %s\n", map_extern_[i]))
    end
    out:write("\n")
end

-- Write extern label names.
local function writeexternnames(out, name)
    out:write("static const char *const ", name, "[] = {\n")
    for i=0,next_extern-1 do
        out:write("  \"", map_extern_[i], "\",\n")
    end
    out:write("  (const char *)0\n};\n")
end

------------------------------------------------------------------------------

-- Arch-specific maps.
--
-- Ext. register name -> int. name.
local map_archdef = { ip0 = "x16", ip1 = "x17", fp = "x29", lr = "x30", }

-- Int. register name -> ext. name.
local map_reg_rev = { x16 = "ip0", x17 = "rip1", x29 = "fp", x30 = "lr", }

local map_type = {}                -- Type name -> { ctype, reg }
local ctypenum = 0                -- Type number (for Dt... macros).

-- Reverse defines for registers.
function _M.revdef(s)
  return map_reg_rev[s] or s
end


local map_cond = {
    eq = 0, ne = 1, cs = 2, cc = 3, mi = 4, pl = 5, vs = 6, vc = 7,
    hi = 8, ls = 9, ge = 10, lt = 11, gt = 12, le = 13, al = 14,
    hs = 2, lo = 3,
}

------------------------------------------------------------------------------
-- Template strings for A64 instructions.
-- G<n>[.<n1>]: general purpose registers
--    n variant numbers
--    n1 is size flag, 1 means 64bit, 0 means 32bit
--    n=0: Rd/Rt [0:4]   the destination register, 32/64bit gpr
--    n=1: Rn [5:9]   the first source register, 32/64bit gpr
--    n=2: Rm/Rs [16:20] the second source register, 32/64bit gpr
--    n=3: Rn and Rm, Rn = Rm, at [5:9] and [16:20]
--    n=4: Rt2/Ra [10:14] the second destination register 32/64bit gpr
--    n=5: Rn [5:9] where Rd=SP or Rn=SP
--    n1=0: 32bit registers(Wn/WSP/WZR)
--    n1=1: 64bit registers(Xn/SP/XZR)
--    n1 absent: 32bit or 64bit
-- E<n>: registers or immediate
--    n=1: Rm{, <extend>{#<amount>}}, or Rm{, <shift> #<amount>}
--    n=2: shifted Rm register, Rd and Rn can't be SP
--    n=3: barrier option name or immediate 4 bits for CRm, [8:11]
-- L<n>: label
--    n=0: label which is 21bit immediate, with low 2 bit at [29:30],
--         hight 19 bits at [5:23] label/4096
--    n=1: label which is 21bit immediate, with low 2 bit at [29:30],
--         hight 19 bits at [5:23] label
--    n=2: label which is 14bit immediate, [5:18] label/4
--    n=3: label which is 19bit immediate, [5:23] label/4
--    n=4: label which is 26bit immediate, [0:25] label/4
-- I<n>[.<n1>]: immediate
--    n=0: immediate zero: #0 or #0.0, or constant integer in n1
--    n=1: immr[16:21]
--    n=2: imms[10:15]
--    n=3: lsb where immr = -lsb % 32 or -lsb % 64, 0~31/0~63
--    n=4: width where imms = width-1       1~32-lsb/1~64-lsb
--    n=5: width where imms = immr + width-1 1~32-lsb/1~64-lsb
--    n=6: immediate 16 bits, at [5:20]
--    n=7: immediate 7 bits for CRm:op2, [5:11]
--    n=8: immediate 4 bits for CRm, [8:11]
--    n=9: lsl #<shift> encoded in hw [21:22]. <shift> can be 0,16,32,48
--    n=10: shifted uimm12: #<imm>{, <shift>} shift[22:23], uimm12[10:21]
--    n=11: immediate encoded in (N, immr, imms), n1 is 64bit flag
--      n1=0: 32bit
--      n1=1: 64bit
--    n=12: immediate 5 bits at [16:20]
--    n=13: shift immediate, where immr=-shift%32, imms=31-shift
--    n=14: inverted wide immediate/wide imm/bimask imm(for mov)
--      n1=0: 32bit
--      n1=1: 64bit
--    n=15: scaled immediate 7 bits at [15:21], n1 is scale
--    n=16: scaled immediate 9 bits at [12:20]
--    n=17: immediate 3 bits for op1, [16:18]
--    n=18: immediate 3 bits for op2, [5:7]
--    n=19: immediate 6 bits for test bit number, with b5 at [31] and b40 at[19:23]
--  SIMD&FP immediates:
--    n=20: imm8 in abcdefgh where abc at [16:18] and defgh at [5:9]
--    n=21: lsl #<amount> encoded in cmode<1> or cmode<2:1>
--          n1=0 lsl #0
--          n1=2 cmode<1> (lsl 0/8)
--          n1=4 means cmode<2:1>(lsl 0/8/16/24)
--    n=22: msl #<amount> encoded in cmode<0>, 8/16
--    n=23: imm64 encoded in abcdefgh 
--    n=24: imm4 [11:14] n1=0: 0~7, n1=1: 0~15
--    n=25: immh:immb, immh[19:22] immb[16:18]
--          n1=3: uimm3 [16:18] = 16 - (8+bits3) (1~8)
--          n1=4: uimm4 [16:19] = 32 - (16+bits4) (1~16)
--          n1=5: uimm5 [16:20] = 64 - (32+bits5) (1~32)
--          n1=6: uimm6 [16:21] = 128 - (64+bits6) (1~64)
--    n=26: scale [10:15]
--          n1=0: uimm5 [10:14] = 64 - (32+bits5)
--          n1=1: uimm6 [10:15] = 64 - bits6
--    n=27: floating point encoded in abcdefgh
--    n=28: floating point encoded in imm8[13:20] for fmov
--    n=29: immh:immb, immh[19:22] immb[16:18]
--          n1=3: uimm3 [16:18] = bits3 (0~7)
--          n1=4: uimm4 [16:19] = bits4 (0~15)
--          n1=5: uimm5 [16:20] = bits5 (0~31)
--          n1=6: uimm6 [16:21] = bits6 (0~63)
-- Sy<n>: system operations or system registers
--    n=1: address translate
--    n=2: data cache
--    n=3: instruction cache
--    n=4: TLB maintenance
--    n=5: system registers(general(101)+debug(27)+perf(18)+timer(18)+interrupt(33) = 197)
--    n=6: pstate
-- F: immediate 4 bits as flags, at [0:3]
-- Cd: condition string, at [12:15]
-- A<n>[.<n1>]: address description
--    n=0: [<Xn|SP>{,#0}], Xn in [5:9], no scale
--    n=1: [<Xn|SP>{, #<imm7>}], Xn in [5:9], imm7/4 or imm7/8 or imm7/16 in [15:21], with scale
--    n=2: [<Xn|SP>], no scale
--    n=3: [<Xn|SP>, #<imm7>]!, with scale
--    n=4: [<Xn|SP>, #<simm9>]!, no scale
--    n=5: [<Xn|SP>{, #<pimm12/simm9>}], pimm12 with scale, or simm9 if imm is negative or unaligned(in this case, bit24 need to be reset to 0)
--    n=6: [<Xn|SP>, <R><m>{, <extend> {<amount>}}]
--        n1: the amount when S = 1
--        if n1 > 0, then amount = 0 when S=0
--        if n1 = 0, then amount is absent when S=0
--    n=7: [<Xn|SP>{, #<simm9>}], no scale
--         Xn in [5:9], simm9 in [12:20], pimm12 in [10:21]
--         Rm at [16:20] extend in [13:15]
--         amount in [12:12]
-- P: prefetch operation
-- Cn<n>: control number  
--    n=1: CRn, in [12:15]
--    n=2: CRm, in [8:11]
--
-- SIMD and floating point instructions
--
-- N<n>.<n1>: non-vector(scalar) SIMD/FP registers. n2 is the possible
--             kinds(B:1, H:2, S:4, D:8, Q:16)
--    n=0: Rd [0:4]
--    n=1: Rn [5:9]
--    n=2: Rm [16:20]
--    n=4: Ra [10:14]
--    n1=1: vector element type is B
--    n1=2: vector element type is H
--    n1=4: vector element type is S
--    n1=8: vector element type is D
--    n1=16:vector element type is Q
--
-- V<n>.<n1>.<n2>: vector registers. n2 is 128 bit flag, n3 is
--                  the possible element kinds(B:1, H:2, S:4, D:8)
--    n=0: Rd
--    n=1: Rn
--    n=2: Rm [16:20]
--    n=3: Rn = Rm
--    n1=0: 64bit
--    n1=1: 128bit
--    n2=1: vector element type is B
--    n2=2: vector element type is H
--    n2=4: vector element type is S
--    n2=8: vector element type is D
-- Ev<n>.<n1>.<n2>: element of vector register
--    n=0: Rd
--    n=1: Rn
--    n=2: Rm
--    n1=1: vector element type is B
--    n1=2: vector element type is H
--    n1=4: vector element type is S
--    n1=8: vector element type is D
--    n2=1: index type 1: imm5[16:20]
--    n2=2: index type 2: immhlm with h[11], l[21], m[20]
--    n2=3: index type 3: imm4[11:14]
--    n2=4: index type 4: V<n1>.D[1]
-- El<n>.<n1>: element of list of vector registers:
--    n=1: list with 1 register
--    n=2: list with 2 registers
--    n=3: list with 3 registers
--    n=4: list with 4 registers
--    n1=1: vector element type is B
--    n1=2: vector element type is H
--    n1=4: vector element type is S
--    n1=8: vector element type is D
--    index is in immqss with q[30], s[12], size[10:11]
-- Lv<n>.<n1>.<n2>.<n3>: list of vector registers
--    n=0: Rd
--    n=1: Rn
--    n=2: Rm [16:20]
--    n1=1: list with 1 register
--    n1=2: list with 2 registers
--    n1=3: list with 3 registers
--    n1=4: list with 4 registers
--    n2=0: 64 bits
--    n2=1: 128 bits
--    n3=1: vector element type is B
--    n3=2: vector element type is H
--    n3=4: vector element type is S
--    n3=8: vector element type is D


local map_op = {
    adc_3 = "1a000000G0.0G1.0G2.0|9a000000G0.1G1.1G2.1",
    adcs_3 = "3a000000G0.0G1.0G2.0|ba000000G0.1G1.1G2.1",
 
    add_3 = "0b000000G0.0G1.0E1.0|8b000000G0.1G1.1E1.1|"..
            "11000000G0.0G1.0I10|91000000G0.1G1.1I10",
    add_4 = "0b000000G0.0G1.0E1.0|8b000000G0.1G1.1E1.1|"..
            "11000000G0.0G1.0I10|91000000G0.1G1.1I10",
    adds_3 = "2b000000G0.0G1.0E1.0|ab000000G0.1G1.1E1.1|"..
             "31000000G0.0G1.0I10|b1000000G0.1G1.1I10",
    adds_4 = "2b000000G0.0G1.0E1.0|ab000000G0.1G1.1E1.1|"..
             "31000000G0.0G1.0I10|b1000000G0.1G1.1I10",
 
    adr_2 = "10000000G0L1",
    adrp_2 = "90000000G0L0",
 
    and_3 = "0a000000G0.0G1.0E2.0|12000000G0.0G1.0I11.0|"..
            "8a000000G0.1G1.1E2.1|92000000G0.1G1.1I11.1",
    and_4 = "0a000000G0.0G1.0E2.0|8a000000G0.1G1.1E2.1",
    ands_3 = "6a000000G0.0G1.0E2.0|72000000G0.0G1.0I11.0|"..
             "ea000000G0.1G1.1E2.1|f2000000G0.1G1.1I11.1",
    ands_4 = "6a000000G0.0G1.0E2.0|ea000000G0.1G1.1E2.1",
 
    asr_3 = "1ac02800G0.0G1.0G2.0|13007c00G0.0G1.0I1|"..
            "9ac02800G0.1G1.1G2.1|9340fc00G0.1G1.1I1",
    asrv_3 = "1ac02800G0.0G1.0G2.0|9ac02800G0.1G1.1G2.1",
 
    at_2 = "d5080000Sy1G0",
 
    ["b.cc_1"] = "54000003L3",
    b_1 = "14000000L4",
 
    bfi_4 = "33000000G0.0G1.0I3.0I4.0|b3400000G0.1G1.1I3.1I4.1",
    bfm_4 = "33000000G0.0G1.0I1I2|b3400000G0.1G1.1I1I2",
    bfxil_4 = "33000000G0.0G1.0I1I5.0|b3400000G0.1G1.1I1I5.1",
 
    bic_3 = "0a200000G0.0G1.0E2.0|8a200000G0.1G1.1E2.1",
    bic_4 = "0a200000G0.0G1.0E2.0|8a200000G0.1G1.1E2.1",
    bics_3 = "6a200000G0.0G1.0E2.0|ea200000G0.1G1.1E2.1",
    bics_4 = "6a200000G0.0G1.0E2.0|ea200000G0.1G1.1E2.1",
 
    bl_1 = "94000000L4",
    blr_1 = "d63f0000G1",
    br_1 = "d61f0000G1",
 
    brk_1 = "d4200000I6",
 
    cbnz_2 = "35000000G0.0L3|b5000000G0.1L3",
    cbz_2 = "34000000G0.0L3|b4000000G0.1L3",
 
    ccmn_4 = "3a400000G1.0G2.0FCd|3a400800G1.0I12FCd|"..
             "ba400000G1.1G2.1FCd|ba400800G1.1I12FCd",
    ccmp_4 = "7a400000G1.0G2.0FCd|7a400800G1.0I12FCd|"..
             "fa400000G1.1G2.1FCd|fa400800G1.1I12FCd",
 
    cinc_3 = "1a800400G0.0G3.0Cd|9a800400G0.1G3.1Cd",
    cinv_3 = "5a800000G0.0G3.0Cd|da800000G0.1G3.1Cd",
 
    clrex_0 = "d5033f5f",
    clrex_1 = "d503305fI8",
 
    cls_2 = "5ac01400G0.0G1.0|dac01400G0.1G1.1",
    clz_2 = "5ac01000G0.0G1.0|dac01000G0.1G1.1",
 
    cmn_2 = "2b00001fG1.0E1.0|3100001fG1.0I10|"..
            "ab00001fG1.1E1.1|b100001fG1.1I10",
    cmn_3 = "2b00001fG1.0E1.0|3100001fG1.0I10|"..
            "ab00001fG1.1E1.1|b100001fG1.1I10",
    cmp_2 = "6b00001fG1.0E1.0|7100001fG1.0I10|"..
            "eb00001fG1.1E1.1|f100001fG1.1I10",
    cmp_3 = "6b00001fG1.0E1.0|7100001fG1.0I10|"..
            "eb00001fG1.1E1.1|f100001fG1.1I10",
    
    cneg_3 = "5a800400G0.0G3.0Cd|da800400G0.1G3.1Cd",
 
    crc32b_3 = "1ac04000G0.0G1.0G2.0",
    crc32h_3 = "1ac04400G0.0G1.0G2.0",
    crc32w_3 = "1ac04800G0.0G1.0G2.0",
    crc32x_3 = "9ac04c00G0.0G1.0G2.1",
    crc32cb_3 = "1ac05000G0.0G1.0G2.0",
    crc32ch_3 = "1ac05400G0.0G1.0G2.0",
    crc32cw_3 = "1ac05800G0.0G1.0G2.0",
    crc32cx_3 = "9ac05c00G0.0G1.0G2.1",
 
    csel_4 = "1a800000G0.0G1.0G2.0Cd|9a800000G0.1G1.1G2.1Cd",
    cset_2 = "1a9f07e0G0.0Cd|9a9f07e0G0.1Cd",
    csetm_2 = "5a800000G0.0Cd|da800000G0.1Cd",
    csinc_4 = "1a800400G0.0G1.0G2.0Cd|9a800400G0.1G1.1G2.1Cd",
    csinv_4 = "5a800000G0.0G1.0G2.0Cd|da800000G0.1G1.1G2.1Cd",
    csneg_4 = "5a800400G0.0G1.0G2.0Cd|da800400G0.1G1.1G2.1Cd",
 
    dc_2 = "d5080000Sy2G0",
 
    dcps1_0 = "d4a00001",
    dcps1_1 = "d4a00001I6",
    dcps2_0 = "d4a00002",
    dcps2_1 = "d4a00002I6",
    dcps3_0 = "d4a00003",
    dcps3_1 = "d4a00003I6",
 
    dmb_1 = "d50330bfE3",
    drps_0 = "d6bf03e0",
    dsb_1 = "d503309fE3",
 
    eon_3 = "4a200000G0.0G1.0E2.0|ca200000G0.1G1.1E2.1",
    eon_4 = "4a200000G0.0G1.0E2.0|ca200000G0.1G1.1E2.1",
 
    eor_3 = "4a000000G0.0G1.0E2.0|52000000G0.0G1.0I11.0|"..
            "ca000000G0.1G1.1E2.1|d2000000G0.1G1.1I11.1",
    eor_4 = "4a000000G0.0G1.0E2.0|ca000000G0.1G1.1E2.1",
 
    eret_0 = "d69f03e0",
 
    extr_4 = "13800000G0.0G1.0G2.0I2|93c00000G0.1G1.1G2.1I2",
 
    hint_1 = "d503201fI7",
    hlt_1 = "d4400000I6",
    hvc_1 = "d4000002I6",
 
    ic_1 = "d508001fSy3",
    ic_2 = "d5080000Sy3G0.1",
 
    isb_0 = "d5033fdf",
    isb_1 = "d50330dfE3",
 
    ldar_2 = "88dffc00G0.0A0|c8dffc00G0.1A0",
    ldarb_2 = "08dffc00G0.0A0",
    ldarh_2 = "48dffc00G0.0A0",
 
    ldaxp_3 = "887f8000G0.0G4.0A0|c87f8000G0.1G4.1A0",
    ldaxr_2 = "885ffc00G0.0A0|c85ffc00G0.1A0",
    ldaxrb_2 = "085ffc00G0A0",
    ldaxrh_2 = "485ffc00G0A0",
 
    ldnp_3 = "28400000G0.0G4.0A1.2|a8400000G0.1G4.1A1.3",
    ldp_3 = "29c00000G0.0G4.0A3.2|29400000G0.0G4.0A1.2|"..
            "a9c00000G0.1G4.1A3.3|a9400000G0.1G4.1A1.3",
    ldp_4 = "28c00000G0.0G4.0A2I15.2|a8c00000G0.1G4.1A2I15.3",
    ldpsw_3 = "69c00000G0.1G4.1A3.2|69400000G0.1G4.1A1.2",
    ldpsw_4 = "68c00000G0.1G4.1A2I15.2",

    ldr_2 = "b8400c00G0.0A4|b9400000G0.0A5.2|b8600800G0.0A6.2|18000000G0.0L3|"..
            "f8400c00G0.1A4|f9400000G0.1A5.3|f8600800G0.1A6.3|58000000G0.1L3",
    ldr_3 = "b8400400G0.0A2I16|f8400400G0.1A2I16",
    ldrb_2 = "38400c00G0.0A4|39400000G0.0A5|38600800G0.0A6.0",
    ldrb_3 = "38400400G0.0A2I16",
    ldrh_2 = "78400c00G0.0A4|39400000G0.0A5.1|38600800G0.0A6.1",
    ldrh_3 = "38400400G0.0A2I16",
    ldrsb_2 = "38c00c00G0.0A4|39c00000G0.0A5|38e00800G0.0A6.0|"..
              "38800c00G0.1A4|39800000G0.1A5|38a00800G0.1A6.0",
    ldrsb_3 = "38c00400G0.0A2I16|38800400G0.1A2I16",   
    ldrsh_2 = "78c00c00G0.0A4|79c00000G0.0A5.1|78e00800G0.0A6.1|"..
              "78800c00G0.1A4|79800000G0.1A5.1|78a00800G0.1A6.1",
    ldrsh_3 = "78c00400G0.0A2I16|78800400G0.1A2I16",
    ldrsw_2 = "b8800c00G0.1A4|b9800000G0.1A5.2|b8a00800G0.1A6.2|98000000G0.1L3",
    ldrsw_3 = "b8800400G0.1A2I16",
    ldtr_2 = "b8400800G0.0A7|f8400800G0.1A7",
    ldtrb_2 = "38400800G0.0A7",
    ldtrh_2 = "78400800G0.0A7",
    ldtrsb_2 = "38c00800G0.0A7|38800800G0.1A7",
    ldtrsh_2 = "78c00800G0.0A7|78800800G0.1A7",
    ldtrsw_2 = "b8800800G0.1A7",
    ldur_2 = "b8400000G0.0A7|f8400000G0.1A7",
    ldurb_2 = "38400000G0.0A7",
    ldurh_2 = "78400000G0.0A7",
    ldursb_2 = "38c00000G0.0A7|38800000G0.1A7",
    ldursh_2 = "78c00000G0.0A7|78800000G0.1A7",
    ldursw_2 = "b8800000G0.1A7",
    ldxp_3 = "887f0000G0.0G4.0A0|c87f0000G0.1G4.1A0",
    ldxr_2 = "885f7c00G0.0A0|c85f7c00G0.1A0",
    ldxrb_2 = "085f7c00G0.0A0",
    ldxrh_2 = "485f7c00G0.0A0",
 
    lsl_3 = "1ac02000G0.0G1.0G2.0|53000000G0.0G1.0I13.0|"..
            "9ac02000G0.1G1.1G2.1|d3400000G0.1G1.1I13.1",
    lslv_3 = "1ac02000G0.0G1.0G2.0|9ac02000G0.1G1.1G2.1",
 
    lsr_3 = "1ac02400G0.0G1.0G2.0|53007c00G0.0G1.0I1|"..
            "9ac02400G0.1G1.1G2.1|d340fc00G0.1G1.1I1",
    lsrv_3 = "1ac02400G0.0G1.0G2.0|9ac02400G0.1G1.1G2.1",
 
    madd_4 = "1b000000G0.0G1.0G2.0G4.0|9b000000G0.1G1.1G2.1G4.1",
    mneg_3 = "1b00fc00G0.0G1.0G2.0|9b00fc00G0.1G1.1G2.1",

    mov_2 = "11000000G0.0G5.0|2a0003e0G0.0G2.0|00000000G0.0I14.0|"..
            "91000000G0.1G5.1|aa0003e0G0.1G2.1|90000000G0.1I14.1",
    movk_2 = "72800000G0.0I6|f2800000G0.1I6",
    movk_3 = "72800000G0.0I6I9.0|f2800000G0.1I6I9.1",
    movn_2 = "12800000G0.0I6|92800000G0.1I6",
    movn_3 = "12800000G0.0I6I9.0|92800000G0.1I6I9.1",
    movz_2 = "52800000G0.0I6|d2800000G0.1I6",
    movz_3 = "52800000G0.0I6I9.0|d2800000G0.1I6I9.1",

    mrs_2 = "d5300000G0Sy5",
    msr_2 = "d500401fSy6I8|d5100000Sy5G0",
    msub_4 = "1b008000G0.0G1.0G2.0G4.0|9b008000G0.1G1.1G2.1G4.1",
    mul_3 = "1b007c00G0.0G1.0G2.0|9b007c00G0.1G1.1G2.1",
    mvn_2 = "2a2003e0G0.0E2.0|aa2003e0G0.1E2.1",
    mvn_3 = "2a2003e0G0.0E2.0|aa2003e0G0.1E2.1",
    neg_2 = "4b0003e0G0.0E2.0|cb0003e0G0.1E2.1", 
    neg_3 = "4b0003e0G0.0E2.0|cb0003e0G0.1E2.1", 
    negs_2= "6b0003e0G0.0E2.0|eb0003e0G0.1E2.1",
    negs_3= "6b0003e0G0.0E2.0|eb0003e0G0.1E2.1",
    ngc_2 = "5a0003e0G0.0G2.0|da0003e0G0.1G2.1",
    ngcs_2= "7a0003e0G0.0G2.0|fa0003e0G0.1G2.1",
    nop_0 = "d503201f",
    orn_3 = "2a200000G0.0G1.0G2.0|aa200000G0.1G1.1G2.1",
    orn_4 = "2a200000G0.0G1.0E2.0|aa200000G0.1G1.1E2.1",
    orr_3 = "2a000000G0.0G1.0E2.0|32000000G0.0G1.0I11.0|"..
            "aa000000G0.1G1.1E2.1|b2000000G0.1G1.1I11.1",
    orr_4 = "2a000000G0.0G1.0E2.0|aa000000G0.1G1.1E2.1",

    prfm_2= "f9800000PA5.3|d8000000PL3|f8a00800PA6.3",
    prfum_2 = "f8800000PA7",
    rbit_2 = "5ac00000G0.0G1.0|dac00000G0.1G1.1",
    ret_0 = "d65f03c0",
    ret_1 = "d65f0000G1.1",
    rev_2 = "5ac00800G0.0G1.0|dac00c00G0.1G1.1",
    rev16_2 = "5ac00400G0.0G1.0|dac00400G0.1G1.1",
    rev32_2 = "dac00800G0.1G1.1",

    ror_3 = "13800000G0.0G3.0I2|1ac02c00G0.0G1.0G2.0|"..
            "93c00000G0.1G3.1I2|9ac02c00G0.1G1.1G2.1",
    rorv_3 = "1ac02c00G0.0G1.0G2.0|9ac02c00G0.1G1.1G2.1",
    sbc_3 = "5a000000G0.0G1.0G2.0|da000000G0.1G1.1G2.1",
    sbcs_3 = "7a000000G0.0G1.0G2.0|fa000000G0.1G1.1G2.1",
    sbfiz_4 = "13000000G0.0G1.0I3.0I4.0|93400000G0.1G1.1I3.1I4.1",
    sbfm_4 = "13000000G0.0G1.0I1I2|93400000G0.1G1.1I1I2",
    sbfx_4 = "13000000G0.0G1.0I1I5.0|93400000G0.1G1.1I1I5.1",
    sdiv_3 = "1ac00c00G0.0G1.0G2.0|9ac00c00G0.1G1.1G2.1",
    sev_0 = "d503209f",
    sevl_0 = "d50320bf",
    smaddl_4 = "9b200000G0.1G1.0G2.0G4.1",
    smc_1 = "d4000003I6",
    smnegl_3 = "9b20fc00G0.1G1.0G2.0",
    smsubl_4 = "9b208000G0.1G1.0G2.0G4.1",
    smulh_3 = "9b407c00G0.1G1.1G2.1",
    smull_3 = "9b207c00G0.1G1.0G2.0",

    stlr_2 = "889ffc00G0.0A0|c89ffc00G0.1A0",
    stlrb_2 = "089ffc00G0.0A0",
    stlrh_2 = "489ffc00G0.0A0",
    stlxp_4 = "88208000G2.0G0.0G4.0A0|c8208000G2.0G0.1G4.1A0",
    stlxr_3 = "8800fc00G2.0G0.0A0|c800fc00G2.0G0.1A0",
    stlxrb_3 = "0800fc00G2.0G0.0A0",
    stlxrh_3 = "4800fc00G2.0G0.0A0",
    stnp_3 = "28000000G0.0G4.0A1.2|a8000000G0.1G4.1A1.3",
    stp_3 = "29800000G0.0G4.0A3.2|29000000G0.0G4.0A1.2|"..
            "a9800000G0.1G4.1A3.3|a9000000G0.1G4.1A1.3",
    stp_4 = "28800000G0.0G4.0A2I15.2|a8800000G0.1G4.1A2I15.3",
    str_2 = "b8000c00G0.0A4|b9000000G0.0A5.2|b8200800G0.0A6.2|"..
            "f8000c00G0.1A4|f9000000G0.1A5.3|f8200800G0.1A6.3",
    str_3 = "b8000400G0.0A2I16|f8000400G0.1A2I16",
    strb_2 = "38000c00G0.0A4|39000000G0.0A5|38200800G0.0A6.0",
    strb_3 = "38000400G0.0A2I16",
    strh_2 = "78000c00G0.0A4|79000000G0.0A5.1|78200800G0.0A6.1",
    strh_3 = "78000400G0.0A2I16",
    sttr_2 = "b8000800G0.0A7|f8000800G0.1A7",
    sttrb_2 = "38000800G0.0A7",
    sttrh_2 = "78000800G0.0A7",
    stur_2 = "b8000000G0.0A7|f8000000G0.1A7",
    sturb_2 = "38000000G0.0A7",
    sturh_2 = "78000000G0.0A7",
    stxp_4 = "88200000G2.0G0.0G4.0A0|c8200000G2.0G0.1G4.1A0",
    stxr_3 = "88007c00G2.0G0.0A0|c8007c00G2.0G0.1A0",
    stxrb_3 = "08007c00G2.0G0.0A0",
    stxrh_3 = "48007c00G2.0G0.0A0",
 
    sub_3 = "4b000000G0.0G1.0E1.0|51000000G0.0G1.0I10|"..
            "cb000000G0.1G1.1E1.1|d1000000G0.1G1.1I10",
    sub_4 = "4b000000G0.0G1.0E1.0|51000000G0.0G1.0I10|"..
            "cb000000G0.1G1.1E1.1|d1000000G0.1G1.1I10",
    subs_3 = "6b000000G0.0G1.0E1.0|71000000G0.0G1.0I10|"..
             "eb000000G0.1G1.1E1.1|f1000000G0.1G1.1I10",
    subs_4 = "6b000000G0.0G1.0E1.0|71000000G0.0G1.0I10|"..
             "eb000000G0.1G1.1E1.1|f1000000G0.1G1.1I10",

    svc_1 = "d4000001I6",
    sxtb_2 = "13001c00G0.0G1.0|93401c00G0.1G1.0",
    sxth_2 = "13003c00G0.0G1.0|93403c00G0.1G1.0",
    sxtw_2 = "93407c00G0.1G1.0",
    sys_4 = "d508001fI17Cn1Cn2I18",
    sys_5 = "d5080000I17Cn1Cn2I18G0.1",
    sysl_5 = "d5280000G0.1I17Cn1Cn2I18",

    tbnz_3 = "37000000G0.0I19.0L2|b7000000G0.1I19.1L2",
    tbz_3 = "36000000G0.0I19.0L2|b6000000G0.1I19.1L2",
    tlbi_1 = "d508001fSy4",
    tlbi_2 = "d5080000Sy4G0.1",

    tst_2 = "6a00001fG1.0E2.0|7200001fG1.0I11.0|"..
            "ea00001fG1.1E2.1|f200001fG1.1I11.1",
    tst_3 = "6a00001fG1.0E2.0|ea00001fG1.1E2.1",

    ubfiz_4 = "53000000G0.0G1.0I3.0I4.0|d3400000G0.1G1.1I3.1I4.1",
    ubfm_4 = "53000000G0.0G1.0I1I2|d3400000G0.1G1.1I1I2",
    ubfx_4 = "53000000G0.0G1.0I1I5.0|d3400000G0.1G1.1I1I5.1",
    udiv_3 = "1ac00800G0.0G1.0G2.0|9ac00800G0.1G1.1G2.1",
    umaddl_4 = "9ba00000G0.1G1.0G2.0G4.1",
    umnegl_3 = "9ba0fc00G0.1G1.0G2.0",
    umsubl_4 = "9ba08000G0.1G1.0G2.0G4.1",
    umulh_3 = "9bc07c00G0.1G1.1G2.1",
    umull_3 = "9ba07c00G0.1G1.0G2.0",
    uxtb_2 = "53001c00G0.0G1.0",
    uxth_2 = "53003c00G0.0G1.0",
    wfe_0 = "d503205f",
    wfi_0 = "d503207f",
    yield_0 = "d503203f"
 
}

local map_vop = {
    abs_2 = "5ee0b800N0.8N1.8|"..
            "0e20b800V0.0.1V1.0.1|"..
            "4e20b800V0.1.1V1.1.1|"..
            "0e60b800V0.0.2V1.0.2|"..
            "4e60b800V0.1.2V1.1.2|"..
            "0ea0b800V0.0.4V1.0.4|"..
            "4ea0b800V0.1.4V1.1.4|"..
            "4ee0b800V0.1.8V1.1.8",

    add_3 = "5ee08400N0.8N1.8N2.8|"..
            "0e208400V0.0.1V1.0.1V2.0.1|"..
            "4e208400V0.1.1V1.1.1V2.1.1|"..
            "0e608400V0.0.2V1.0.2V2.0.2|"..
            "4e608400V0.1.2V1.1.2V2.1.2|"..
            "0ea08400V0.0.4V1.0.4V2.0.4|"..
            "4ea08400V0.1.4V1.1.4V2.1.4|"..
            "4ee08400V0.1.8V1.1.8V2.1.8",

    addhn_3 = "0e204000V0.0.1V1.1.2V2.1.2|"..
              "0e604000V0.0.2V1.1.4V2.1.4|"..
              "0ea04000V0.0.4V1.1.8V2.1.8",

    addhn2_3= "4e204000V0.1.1V1.1.2V2.1.2|"..
              "4e604000V0.1.2V1.1.4V2.1.4|"..
              "4ea04000V0.1.4V1.1.8V2.1.8",

    addp_2 = "5ef1b800N0.8V1.1.8",

    addp_3 = "0e20bc00V0.0.1V1.0.1V2.0.1|"..
             "4e20bc00V0.1.1V1.1.1V2.1.1|"..
             "0e60bc00V0.0.2V1.0.2V2.0.2|"..
             "4e60bc00V0.1.2V1.1.2V2.1.2|"..
             "0ea0bc00V0.0.4V1.0.4V2.0.4|"..
             "4ea0bc00V0.1.4V1.1.4V2.1.4|"..
             "4ee0bc00V0.1.8V1.1.8V2.1.8",

    addv_2 = "0e31b800N0.1V1.0.1|"..
             "4e31b800N0.1V1.1.1|"..
             "0e71b800N0.2V1.0.2|"..
             "4e71b800N0.2V1.1.2|"..
             "4eb1b800N0.4V1.1.4",

    aesd_2 = "4e285800V0.1.1V1.1.1",
    aese_2 = "4e284800V0.1.1V1.1.1",
    aesimc_2 = "4e287800V0.1.1V1.1.1",
    aesmc_2 = "4e286800V0.1.1V1.1.1",
    and_3 = "0e201c00V0.0.1V1.0.1V2.0.1|"..
            "4e201c00V0.1.1V1.1.1V2.1.1",
    bic_2 = "2f009400V0.0.2I20|"..
            "6f009400V0.1.2I20|"..
            "2f001400V0.0.4I20|"..
            "6f001400V0.1.4I20",

    bic_3 = "2f009400V0.0.2I20I21.2|"..
            "6f009400V0.1.2I20I21.2|"..
            "2f001400V0.0.4I20I21.4|"..
            "6f009400V0.1.4I20I21.4|"..
            "0e601c00V0.0.1V1.0.1V2.0.1|"..
            "4e601c00V0.1.1V1.1.1V2.1.1",

    bif_3 = "2ee01c00V0.0.1V1.0.1V2.0.1|"..
            "6ee01c00V0.1.1V1.1.1V2.1.1",

    bit_3 = "2ea01c00V0.0.1V1.0.1V2.0.1|"..
            "6ea01c00V0.1.1V1.1.1V2.1.1",

    bsl_3 = "2e601c00V0.0.1V1.0.1V2.0.1|"..
            "6e601c00V0.1.1V1.1.1V2.1.1",

    cls_2 = "0e204800V0.0.1V1.0.1|"..
            "4e204800V0.1.1V1.1.1|"..
            "0e604800V0.0.2V1.0.2|"..
            "4e604800V0.1.2V1.1.2|"..
            "0ea04800V0.0.4V1.0.4|"..
            "4ea04800V0.1.4V1.1.4",

    clz_2 = "2e204800V0.0.1V1.0.1|"..
            "6e204800V0.1.1V1.1.1|"..
            "2e604800V0.0.2V1.0.2|"..
            "6e604800V0.1.2V1.1.2|"..
            "2ea04800V0.0.4V1.0.4|"..
            "6ea04800V0.1.4V1.1.4",

    cmeq_3 = "7ee08c00N0.8N1.8N2.8|"..
             "2e208c00V0.0.1V1.0.1V2.0.1|"..
             "6e208c00V0.1.1V1.1.1V2.1.1|"..
             "2e608c00V0.0.2V1.0.2V2.0.2|"..
             "6e608c00V0.1.2V1.1.2V2.1.2|"..
             "2ea08c00V0.0.4V1.0.4V2.0.4|"..
             "6ea08c00V0.1.4V1.1.4V2.1.4|"..
             "6ee08c00V0.1.8V1.1.8V2.1.8|"..
             "5ee09800N0.8N1.8I0|"..
             "0e209800V0.0.1V1.0.1I0|"..
             "4e209800V0.1.1V1.1.1I0|"..
             "0e609800V0.0.2V1.0.2I0|"..
             "4e609800V0.1.2V1.1.2I0|"..
             "0ea09800V0.0.4V1.0.4I0|"..
             "4ea09800V0.1.4V1.1.4I0|"..
             "4ee09800V0.1.8V1.1.8I0",

    cmge_3 = "5ee03c00N0.8N1.8N2.8|"..
             "0e203c00V0.0.1V1.0.1V2.0.1|"..
             "4e203c00V0.1.1V1.1.1V2.1.1|"..
             "0e603c00V0.0.2V1.0.2V2.0.2|"..
             "4e603c00V0.1.2V1.1.2V2.1.2|"..
             "0ea03c00V0.0.4V1.0.4V2.0.4|"..
             "4ea03c00V0.1.4V1.1.4V2.1.4|"..
             "4ee03c00V0.1.8V1.1.8V2.1.8|"..
             "7ee08800N0.8N1.8I0|"..
             "2e208800V0.0.1V1.0.1I0|"..
             "6e208800V0.1.1V1.1.1I0|"..
             "2e608800V0.0.2V1.0.2I0|"..
             "6e608800V0.1.2V1.1.2I0|"..
             "2ea08800V0.0.4V1.0.4I0|"..
             "6ea08800V0.1.4V1.1.4I0|"..
             "6ee08800V0.1.8V1.1.8I0",

    cmgt_3 = "5ee03400N0.8N1.8N2.8|"..
             "0e203400V0.0.1V1.0.1V2.0.1|"..
             "4e203400V0.1.1V1.1.1V2.1.1|"..
             "0e603400V0.0.2V1.0.2V2.0.2|"..
             "4e603400V0.1.2V1.1.2V2.1.2|"..
             "0ea03400V0.0.4V1.0.4V2.0.4|"..
             "4ea03400V0.1.4V1.1.4V2.1.4|"..
             "4ee03400V0.1.8V1.1.8V2.1.8|"..
             "5ee08800N0.8N1.8I0|"..
             "0e208800V0.0.1V1.0.1I0|"..
             "4e208800V0.1.1V1.1.1I0|"..
             "0e608800V0.0.2V1.0.2I0|"..
             "4e608800V0.1.2V1.1.2I0|"..
             "0ea08800V0.0.4V1.0.4I0|"..
             "4ea08800V0.1.4V1.1.4I0|"..
             "4ee08800V0.1.8V1.1.8I0",

    cmhi_3 = "7ee03400N0.8N1.8N2.8|"..
             "2e203400V0.0.1V1.0.1V2.0.1|"..
             "6e203400V0.1.1V1.1.1V2.1.1|"..
             "2e603400V0.0.2V1.0.2V2.0.2|"..
             "6e603400V0.1.2V1.1.2V2.1.2|"..
             "2ea03400V0.0.4V1.0.4V2.0.4|"..
             "6ea03400V0.1.4V1.1.4V2.1.4|"..
             "6ee03400V0.1.8V1.1.8V2.1.8",

    cmhs_3 = "7ee03c00N0.8N1.8N2.8|"..
             "2e203c00V0.0.1V1.0.1V2.0.1|"..
             "6e203c00V0.1.1V1.1.1V2.1.1|"..
             "2e603c00V0.0.2V1.0.2V2.0.2|"..
             "6e603c00V0.1.2V1.1.2V2.1.2|"..
             "2ea03c00V0.0.4V1.0.4V2.0.4|"..
             "6ea03c00V0.1.4V1.1.4V2.1.4|"..
             "6ee03c00V0.1.8V1.1.8V2.1.8",

    cmle_3 = "7ee09800N0.8N1.8I0|"..
             "2e209800V0.0.1V1.0.1I0|"..
             "6e209800V0.1.1V1.1.1I0|"..
             "2e609800V0.0.2V1.0.2I0|"..
             "6e609800V0.1.2V1.1.2I0|"..
             "2ea09800V0.0.4V1.0.4I0|"..
             "6ea09800V0.1.4V1.1.4I0|"..
             "6ee09800V0.1.8V1.1.8I0",

    cmlt_3 = "5ee0a800N0.8N1.8I0|"..
             "0e20a800V0.0.1V1.0.1I0|"..
             "4e20a800V0.1.1V1.1.1I0|"..
             "0e60a800V0.0.2V1.0.2I0|"..
             "4e60a800V0.1.2V1.1.2I0|"..
             "0ea0a800V0.0.4V1.0.4I0|"..
             "4ea0a800V0.1.4V1.1.4I0|"..
             "4ee0a800V0.1.8V1.1.8I0",

    cmtst_3 = "5ee08c00N0.8N1.8N2.8|"..
              "0e208c00V0.0.1V1.0.1V2.0.1|"..
              "4e208c00V0.1.1V1.1.1V2.1.1|"..
              "0e608c00V0.0.2V1.0.2V2.0.2|"..
              "4e608c00V0.1.2V1.1.2V2.1.2|"..
              "0ea08c00V0.0.4V1.0.4V2.0.4|"..
              "4ea08c00V0.1.4V1.1.4V2.1.4|"..
              "4ee08c00V0.1.8V1.1.8V2.1.8",

    cnt_2 = "0e205800V0.0.1V1.0.1|"..
            "4e205800V0.1.1V1.1.1",

    dup_2 = "5e010400N0.1Ev1.1.1|"..
            "5e020400N0.2Ev1.2.1|"..
            "5e040400N0.4Ev1.4.1|"..
            "5e080400N0.8Ev1.8.1|"..
            "0e010400V0.0.1Ev1.1.1|"..
            "4e010400V0.1.1Ev1.1.1|"..
            "0e020400V0.0.2Ev1.2.1|"..
            "4e020400V0.1.2Ev1.2.1|"..
            "0e040400V0.0.4Ev1.4.1|"..
            "4e040400V0.1.4Ev1.4.1|"..
            "4e080400V0.1.8Ev1.8.1|"..
            "0e010c00V0.0.1G1.0|"..
            "4e010c00V0.1.1G1.0|"..
            "0e020c00V0.0.2G1.0|"..
            "4e020c00V0.1.2G1.0|"..
            "0e040c00V0.0.4G1.0|"..
            "4e040c00V0.1.4G1.0|"..
            "4e080c00V0.1.8G1.1",

    eor_3 = "2e201c00V0.0.1V1.0.1V2.0.1|"..
            "6e201c00V0.1.1V1.1.1V2.1.1",

    ext_4 = "2e000000V0.0.1V1.0.1V2.0.1I24|"..
            "6e000000V0.1.1V1.1.1V2.1.1I24",

    fabd_3 = "7ea0d400N0.4N1.4N2.4|7ee0d400N0.8N1.8N2.8|"..
             "2ea0d400V0.0.4V1.0.4V2.0.4|"..
             "6ea0d400V0.1.4V1.1.4V2.1.4|"..
             "6ee0d400V0.1.8V1.1.8V2.1.8",

    fabs_2 = "0ea0f800V0.0.4V1.0.4|"..
             "4ea0f800V0.1.4V1.1.4|"..
             "4ee0f800V0.1.8V1.1.4|"..
             "1e20c000N0.4N1.4|"..
             "1e60c000N0.8N1.8",

    facge_3 = "7e20ec00N0.4N1.4N2.4|"..
              "7e60ec00N0.8N1.8N2.8|"..
              "2e20ec00V0.0.4V1.0.4V2.0.4|"..
              "6e20ec00V0.1.4V1.1.4V2.1.4|"..
              "6e60ec00V0.1.8V1.1.8V2.1.8",

    facgt_3 = "7ea0ec00N0.4N1.4N2.4|"..
              "7ee0ec00N0.8N1.8N2.8|"..
              "2ea0ec00V0.0.4V1.0.4V2.0.4|"..
              "6ea0ec00V0.1.4V1.1.4V2.1.4|"..
              "6ee0ec00V0.1.8V1.1.8V2.1.8",

    fadd_3 = "0e20d400V0.0.4V1.0.4V2.0.4|"..
             "4e20d400V0.1.4V1.1.4V2.1.4|"..
             "4e60d400V0.1.8V1.1.8V2.1.8|"..
             "1e202800N0.4N1.4N2.4|"..
             "1e602800N0.8N1.8N2.4",

    faddp_2 = "7e30d800N0.4V1.0.4|"..
              "7e70d800N0.8V1.1.8|"..
              "2e20d400V0.0.4V1.0.4V2.0.4|"..
              "6e20d400V0.1.4V1.1.4V2.1.4|"..
              "6e60d400V0.1.8V1.1.8V2.1.8",

    fccmp_4 = "1e200400N1.4N2.4FCd|1e600400N1.8N2.8FCd",

    fccmpe_4 = "1e200410N1.4N2.4FCd|1e600410N1.8N2.8FCd",

    fcmeq_3 = "5e20e400N0.4N1.4N2.4|5e60e400N0.8N1.8N2.8|"..
              "0e20e400V0.0.4V1.0.4V2.0.4|"..
              "4e20e400V0.1.4V1.1.4V2.1.4|"..
              "4e60e400V0.1.8V1.1.8V2.1.8|"..
              "5ea0d800N0.4N1.4I0|5ee0d800N0.8N1.8I0|"..
              "0ea0d800V0.0.4V1.0.4I0|"..
              "4ea0d800V0.1.4V1.1.4I0|"..
              "4ee0d800V0.1.8V1.1.8I0",

    fcmge_3 = "7e20e400N0.4N1.4N2.4|7e60e400N0.8N1.8N2.8|"..
              "2e20e400V0.0.4V1.0.4V2.0.4|"..
              "6e20e400V0.1.4V1.1.4V2.1.4|"..
              "6e60e400V0.1.8V1.1.8V2.1.8|"..
              "7ea0c800N0.4N1.4I0|"..
              "7ee0c800N0.8N1.8I0|"..
              "2ea0c800V0.0.4V1.0.4I0|"..
              "6ea0c800V0.1.4V1.1.4I0|"..
              "6ee0c800V0.1.8V1.1.8I0",

    fcmgt_3 = "7ea0e400N0.4N1.4N2.4|7ee0e400N0.8N1.8N2.8|"..
              "2ea0e400V0.0.4V1.0.4V2.0.4|"..
              "6ea0e400V0.1.4V1.1.4V2.1.4|"..
              "6ee0e400V0.1.8V1.1.8V2.1.8|"..
              "5ea0c800N0.4N1.4I0|5ee0c800N0.8N1.8I0|"..
              "0ea0c800V0.0.4V1.0.4I0|"..
              "4ea0c800V0.1.4V1.1.4I0|"..
              "4ee0c800V0.1.8V1.1.8I0",

    fcmle_3 = "7ea0d800N0.4N1.4I0|7ee0d800N0.8N1.8I0|"..
              "2ea0d800V0.0.4V1.0.4I0|"..
              "6ea0d800V0.1.4V1.1.4I0|"..
              "6ee0d800V0.1.8V1.1.8I0",

    fcmlt_3 = "5ea0e800N0.4N1.4I0|5ee0e800N0.8N1.8I0|"..
              "0ea0e800V0.0.4V1.0.4I0|"..
              "4ea0e800V0.1.4V1.1.4I0|"..
              "4ee0e800V0.1.8V1.1.8I0",

    fcmp_2 = "1e202000N1.4N2.4|1e202008N1.4I0|"..
             "1e602000N1.8N2.8|1e602008N1.8I0",

    fcmpe_2 = "1e202010N1.4N2.4|1e202018N1.4I0|"..
              "1e602010N1.8N2.8|1e602018N1.8I0",

    fcsel_4 = "1e200c00N0.4N1.4N2.4Cd|"..
              "1e600c00N0.8N1.8N2.8Cd",

    fcvt_2 = "1ee24000N0.4N1.2|1ee0c000N0.8N1.2|"..
             "1e23c000N0.2N1.4|1e22c000N0.8N1.4|"..
             "1e63c000N0.2N1.8|1e624000N0.4N1.8",

    fcvtas_2 = "5e21c800N0.4N1.4|5e61c800N0.8N1.8|"..
               "0e21c800V0.0.4V1.0.4|"..
               "4e21c800V0.1.4V1.1.4|"..
               "4e61c800V0.1.8V1.1.8|"..
               "1e240000G0.0N1.4|"..
               "9e240000G0.1N1.4|"..
               "1e640000G0.0N1.8|"..
               "9e640000G0.1N1.8",

    fcvtau_2 = "7e21c800N0.4N1.4|7e61c800N0.8N1.8|"..
               "2e21c800V0.0.4V1.0.4|"..
               "6e21c800V0.1.4V1.1.4|"..
               "6e61c800V0.1.8V1.1.8|"..
               "1e250000G0.0N1.4|"..
               "9e250000G0.1N1.4|"..
               "1e650000G0.0N1.8|"..
               "9e650000G0.1N1.8",

    fcvtl_2 = "0e217800V0.1.4V1.0.2|"..
              "0e617800V0.1.8V1.0.4",

    fcvtl2_2 = "4e217800V0.1.4V1.1.2|"..
               "4e617800V0.1.8V1.1.4",

    fcvtms_2 = "5e21b800N0.4N1.4|5e61b800N0.8N1.8|"..
               "0e21b800V0.0.4V1.0.4|"..
               "4e21b800V0.1.4V1.1.4|"..
               "4e61b800V0.1.8V1.1.8|"..
               "1e300000G0.0N1.4|"..
               "9e300000G0.1N1.4|"..
               "1e700000G0.0N1.8|"..
               "9e700000G0.1N1.8",

    fcvtmu_2 = "7e21b800N0.4N1.4|7e61b800N0.8N1.8|"..
               "2e21b800V0.0.4V1.0.4|"..
               "6e21b800V0.1.4V1.1.4|"..
               "6e61b800V0.1.8V1.1.8|"..
               "1e310000G0.0N1.4|"..
               "9e310000G0.1N1.4|"..
               "1e710000G0.0N1.8|"..
               "9e710000G0.1N1.8",

    fcvtn_2 = "0e216800V0.0.2V1.1.4|"..
              "0e616800V0.0.4V1.1.8",

    fcvtn2_2 = "4e216800V0.1.2V1.1.4|"..
               "4e616800V0.1.4V1.1.8",

    fcvtns_2 = "5e21a800N0.4N1.4|5e61a800N0.8N1.8|"..
               "0e21a800V0.0.4V1.0.4|"..
               "4e21a800V0.1.4V1.1.4|"..
               "4e61a800V0.1.8V1.1.8|"..
               "1e200000G0.0N1.4|"..
               "9e200000G0.1N1.4|"..
               "1e600000G0.0N1.8|"..
               "9e600000G0.1N1.8",

    fcvtnu_2 = "7e21a800N0.4N1.4|7e61a800N0.8N1.8|"..
               "2e21a800V0.0.4V1.0.4|"..
               "6e21a800V0.1.4V1.1.4|"..
               "6e61a800V0.1.8V1.1.8|"..
               "1e210000G0.0N1.4|"..
               "9e210000G0.1N1.4|"..
               "1e610000G0.0N1.8|"..
               "9e610000G0.1N1.8",

    fcvtps_2 = "5ea1a800N0.4N1.4|5ee1a800N0.8N1.8|"..
               "0ea1a800V0.0.4V1.0.4|"..
               "4ea1a800V0.1.4V1.1.4|"..
               "4ee1a800V0.1.8V1.1.8|"..
               "1e280000G0.0N1.4|"..
               "9e280000G0.1N1.4|"..
               "1e680000G0.0N1.8|"..
               "9e680000G0.1N1.8",

    fcvtpu_2 = "7ea1a800N0.4N1.4|7ee1a800N0.8N1.8|"..
               "2ea1a800V0.0.4V1.0.4|"..
               "6ea1a800V0.1.4V1.1.4|"..
               "6ee1a800V0.1.8V1.1.8|"..
               "1e290000G0.0N1.4|"..
               "9e290000G0.1N1.4|"..
               "1e690000G0.0N1.8|"..
               "9e690000G0.1N1.8",

    fcvtxn_2 = "7e616800N0.4N1.8|2e616800V0.0.4V1.1.8",

    fcvtxn2_2 = "6e616800V0.1.4V1.1.8",

    fcvtzs_2 = "5ea1b800N0.4N1.4|5ee1b800N0.8N1.8|"..
               "0ea1b800V0.0.4V1.0.4|"..
               "4ea1b800V0.1.4V1.1.4|"..
               "4ee1b800V0.1.8V1.1.8|"..
               "1e380000G0.0N1.4|"..
               "9e380000G0.1N1.4|"..
               "1e780000G0.0N1.8|"..
               "9e780000G0.1N1.8",

    fcvtzs_3 = "5f20fc00N0.4N1.4I25.5|"..
               "5f40fc00N0.8N1.8I25.6|"..
               "0f20fc00V0.0.4V1.0.4I25.5|"..
               "4f20fc00V0.1.4V1.1.4I25.5|"..
               "4f40fc00V0.1.8V1.1.8I25.6|"..
               "1e188000G0.0N1.4I26.0|"..
               "9e180000G0.1N1.4I26.1|"..
               "1e588000G0.0N1.8I26.0|"..
               "9e580000G0.1N1.8I26.1",

    fcvtzu_2 = "7ea1b800N0.4N1.4|"..
               "7ee1b800N0.8N1.8|"..
               "2ea1b800V0.0.4V1.0.4|"..
               "6ea1b800V0.1.4V1.1.4|"..
               "6ee1b800V0.1.8V1.1.8|"..
               "1e390000G0.0N1.4|"..
               "9e390000G0.1N1.4|"..
               "1e790000G0.0N1.8|"..
               "9e790000G0.1N1.8",

    fcvtzu_3 = "7f20fc00N0.4N1.4I25.5|"..
               "7f40fc00N0.8N1.8I25.6|"..
               "2f20fc00V0.0.4V1.0.4I25.5|"..
               "6f20fc00V0.1.4V1.1.4I25.5|"..
               "6f40fc00V0.1.8V1.1.8I25.6|"..
               "1e198000G0.0N1.4I26.0|"..
               "9e190000G0.1N1.4I26.1|"..
               "1e598000G0.0N1.8I26.0|"..
               "9e590000G0.1N1.8I26.1",

    fdiv_3 = "2e20fc00V0.0.4V1.0.4V2.0.4|"..
             "6e20fc00V0.1.4V1.1.4V2.1.4|"..
             "6e60fc00V0.1.8V1.1.8V2.1.8|"..
             "1e201800N0.4N1.4N2.4|"..
             "1e601800N0.8N1.8N2.8",

    fmadd_4 = "1f000000N0.4N1.4N2.4N4.4|"..
              "1f400000N0.8N1.8N2.8N4.8",

    fmax_3 = "0e20f400V0.0.4V1.0.4V2.0.4|"..
             "4e20f400V0.1.4V1.1.4V2.1.4|"..
             "4e60f400V0.1.8V1.1.8V2.1.8|"..
             "1e204800N0.4N1.4N2.4|"..
             "1e604800N0.8N1.8N2.8",

    fmaxnm_3 = "0e20c400V0.0.4V1.0.4V2.0.4|"..
               "4e20c400V0.1.4V1.1.4V2.1.4|"..
               "4e60c400V0.1.8V1.1.8V2.1.8|"..
               "1e206800N0.4N1.4N2.4|"..
               "1e606800N0.8N1.8N2.8",

    fmaxnmp_2 = "7e30c800N0.4V1.0.4|"..
                "7e70c800N0.8V1.1.8",

    fmaxnmp_3 = "2e20c400V0.0.4V1.0.4V2.0.4|"..
                "6e20c400V0.1.4V1.1.4V2.1.4|"..
                "6e60c400V0.1.8V1.1.8V2.1.8",

    fmaxnmv_2 = "6e30c800N0.4V1.1.4",

    fmaxp_2 = "7e30f800N0.4V1.0.4|"..
              "7e70f800N0.8V1.1.8",

    fmaxp_3 = "2e20f400V0.0.4V1.0.4V2.0.4|"..
              "6e20f400V0.1.4V1.1.4V2.1.4|"..
              "6e60f400V0.1.8V1.1.8V2.1.8",

    fmaxv_2 = "6e30f800N0.4V1.1.4",

    fmin_3 = "0ea0f400V0.0.4V1.0.4V2.0.4|"..
             "4ea0f400V0.1.4V1.1.4V2.1.4|"..
             "4ee0f400V0.1.8V1.1.8V2.1.8|"..
             "1e205800N0.4N1.4N2.4|"..
             "1e605800N0.8N1.8N2.8",

    fminnm_3 = "0ea0c400V0.0.4V1.0.4V2.0.4|"..
               "4ea0c400V0.1.4V1.1.4V2.1.4|"..
               "4ee0c400V0.1.8V1.1.8V2.1.8|"..
               "1e207800N0.4N1.4N2.4|"..
               "1e607800N0.8N1.8N2.8",

    fminnmp_2 = "7eb0c800N0.4V1.0.4|7ef0c800N0.8V1.1.8",

    fminnmp_3 = "2ea0c400V0.0.4V1.0.4V2.0.4|"..
                "6ea0c400V0.1.4V1.1.4V2.1.4|"..
                "6ee0c400V0.1.8V1.1.8V2.1.8", 

    fminnmv_2 = "6eb0c800N0.4V1.1.4",

    fminp_2 = "7eb0f800N0.4V1.0.4|7ef0f800N0.8V1.1.8",

    fminp_3 = "2ea0f400V0.0.4V1.0.4V2.0.4|"..
              "6ea0f400V0.1.4V1.1.4V2.1.4|"..
              "6ee0f400V0.1.8V1.1.8V2.1.8",

    fminv_2 = "6eb0f800N0.4V1.1.4",

    fmla_3 = "5f801000N0.4N1.4Ev2.4.2|"..
             "5fc01000N0.8N1.8Ev2.8.2|"..
             "0f801000V0.0.4V1.0.4Ev2.4.2|"..
             "4f801000V0.1.4V1.1.4Ev2.4.2|"..
             "4fc01000V0.1.8V2.1.8Ev2.8.2|"..
             "0e20cc00V0.0.4V1.0.4V2.0.4|"..
             "4e20cc00V0.1.4V1.1.4V2.1.4|"..
             "4e60cc00V0.1.8V1.1.8V2.1.8",

    fmls_3 = "5f805000N0.4N1.4Ev2.4.2|"..
             "5fc05000N0.8N1.8Ev2.8.2|"..
             "0f805000V0.0.4V1.0.4Ev2.4.2|"..
             "4f805000V0.1.4V1.1.4Ev2.4.2|"..
             "4fc05000V0.1.8V1.1.8Ev2.8.2|"..
             "0ea0cc00V0.0.4V1.0.4V2.0.4|"..
             "4ea0cc00V0.1.4V1.1.4V2.1.4|"..
             "4ee0cc00V0.1.8V1.1.8V2.1.8",

    fmov_2 = "0f00f400V0.0.4I27|4f00f400V0.1.4I27|"..
             "6f00f400V0.1.8I27|1e204000N0.4N1.4|"..
             "1e604000N0.8N1.8|1e270000N0.4G1.0|"..
             "1e260000G0.0N1.4|9e670000N0.8G1.1|"..
             "9eaf0000Ev0.8.4G1.1|9e660000G0.1N1.8|"..
             "9eae0000G0.1Ev1.8.4|1e201000N0.4I28|"..
             "1e601000N0.8I28",

    fmsub_4 = "1f008000N0.4N1.4N2.4N4.4|1f408000N0.8N1.8N2.8N4.8",

    fmul_3 = "5f809000N0.4N1.4Ev2.4.2|"..
             "5fc09000N0.8N1.8Ev2.8.2|"..
             "0f809000V0.0.4V1.0.4Ev2.4.2|"..
             "4f809000V0.1.4V1.1.4Ev2.4.2|"..
             "4fc09000V0.1.8V1.1.8Ev2.8.2|"..
             "2e20dc00V0.0.4V1.0.4V2.0.4|"..
             "6e20dc00V0.1.4V1.1.4V2.1.4|"..
             "6e60dc00V0.1.8V1.1.8V2.1.8|"..
             "1e200800N0.4N1.4N2.4|"..
             "1e600800N0.8N1.8N2.8",

    fmulx_3 = "7f809000N0.4N1.4Ev2.4.2|"..
              "7fc09000N0.8N1.8Ev2.8.2|"..
              "2f809000V0.0.4V1.0.4Ev2.4.2|"..
              "6f809000V0.1.4V1.1.4Ev2.4.2|"..
              "6fc09000V0.1.8V1.1.8Ev2.8.2|"..
              "5e20dc00N0.4N1.4N2.4|"..
              "5e60dc00N0.8N1.8N2.8|"..
              "0e20dc00V0.0.4V1.0.4V2.0.4|"..
              "4e20dc00V0.1.4V1.1.4V2.1.4|"..
              "4e60dc00V0.1.8V1.1.8V2.1.8",

    fneg_2 = "2ea0f800V0.0.4V1.0.4|"..
             "6ea0f800V0.1.4V1.1.4|"..
             "6ee0f800V0.1.8V1.1.8|"..
             "1e214000N0.4N1.4|1e614000N0.8N1.8",

    fnmadd_4 = "1f200000N0.4N1.4N2.4N4.4|1f600000N0.8N1.8N2.8N4.8",

    fnmsub_4 = "1f208000N0.4N1.4N2.4N4.4|1f608000N0.8N1.8N2.8N4.8",

    fnmul_3 = "1e208800N0.4N1.4N2.4|1e608800N0.N1.8N2.8",

    frecpe_2 = "5ea1d800N0.4N1.4|5ee1d800N0.8N1.8|"..
               "0ea1d800V0.0.4V1.0.4|"..
               "4ea1d800V0.1.4V1.1.4|"..
               "4ee1d800V0.1.8V1.1.8",

    frecps_3 = "5e20fc00N0.4N1.4N2.4|5e60fc00N0.8N1.8N2.8|"..
               "0e20fc00V0.0.4V1.0.4V2.0.4|"..
               "4e20fc00V0.1.4V1.1.4V2.1.4|"..
               "4e60fc00V0.1.8V1.1.8V2.1.8",

    frecpx_2 = "5ea1f800N0.4N1.4|5ee1f800N0.8N1.8",

    frinta_2 = "2e218800V0.0.4V1.0.4|"..
               "6e218800V0.1.4V1.1.4|"..
               "6e618800V0.1.8V1.1.8|"..
               "1e264000N0.4N1.4|1e664000N0.8N1.8",

    frinti_2 = "2ea19800V0.0.4V1.0.4|"..
               "6ea19800V0.1.4V1.1.4|"..
               "6ee19800V0.1.8V1.1.8|"..
               "1e27c000N0.4N1.4|1e67c000N0.8N1.8",

    frintm_2 = "0e219800V0.0.4V1.0.4|"..
               "4e219800V0.1.4V1.1.4|"..
               "4e619800V0.1.8V1.1.8|"..
               "1e254000N0.4N1.4|1e654000N0.8N1.8",

    frintn_2 = "0e218800V0.0.4V1.0.4|"..
               "4e218800V0.1.4V1.1.4|"..
               "4e618800V0.1.8V1.1.8|"..
               "1e244000N0.4N1.4|1e644000N0.8N1.8",

    frintp_2 = "0ea18800V0.0.4V1.0.4|"..
               "4ea18800V0.1.4V1.1.4|"..
               "4ee18800V0.1.8V1.1.8|"..
               "1e24c000N0.4N1.4|1e64c000N0.8N1.8",

    frintx_2 = "2e219800V0.0.4V1.0.4|"..
               "6e219800V0.1.4V1.1.4|"..
               "6e619800V0.1.8V1.1.8|"..
               "1e274000N0.4N1.4|1e674000N0.8N1.8",

    frintz_2 = "0ea19800V0.0.4V1.0.4|"..
               "4ea19800V0.1.4V1.1.4|"..
               "4ee19800V0.1.8V1.1.8|"..
               "1e25c000N0.4N1.4|1e65c000N0.8N1.8",

    frsqrte_2 = "7ea1d800N0.4N1.4|7ee1d800N0.8N1.8|"..
                "2ea1d800V0.0.4V1.0.4|"..
                "6ea1d800V0.1.4V1.1.4|"..
                "6ee1d800V0.1.8V1.1.8",

    frsqrts_3 = "5ea0fc00N0.4N1.4N2.4|"..
                "5ee0fc00N0.8N1.8N2.8|"..
                "0ea0fc00V0.0.4V1.0.4V2.0.4|"..
                "4ea0fc00V0.1.4V1.1.4V2.1.4|"..
                "4ee0fc00V0.1.8V1.1.8V2.1.8",

    fsqrt_2 =   "2ea1f800V0.0.4V1.0.4|"..
                "6ea1f800V0.1.4V1.1.4|"..
                "6ee1f800V0.1.8V1.1.8|"..
                "1e21c000N0.4N1.4|1e61c000N0.8N1.8",

    fsub_3 =    "0ea0d400V0.0.4V1.0.4V2.0.4|"..
                "4ea0d400V0.1.4V1.1.4V2.1.4|"..
                "4ee0d400V0.1.8V1.1.8V2.1.8|"..
                "1e203800N0.4N1.4N2.4|1e603800N0.8N1.8N2.8",

    ins_2 = "6e010400Ev0.1.1Ev1.1.3|"..
            "6e020400Ev0.2.1Ev1.2.3|"..
            "6e040400Ev0.4.1Ev1.4.3|"..
            "6e080400Ev0.8.1Ev1.8.3|"..
            "4e011c00Ev0.1.1G1.0|"..
            "4e021c00Ev0.2.1G1.0|"..
            "4e041c00Ev0.4.1G1.0|"..
            "4e081c00Ev0.8.1G1.1",

    ld1_2 = "0c407000Lv0.1.0.1A2|"..
            "4c407000Lv0.1.1.1A2|"..
            "0c407400Lv0.1.0.2A2|"..
            "4c407400Lv0.1.1.2A2|"..
            "0c407800Lv0.1.0.4A2|"..
            "4c407800Lv0.1.1.4A2|"..
            "0c407c00Lv0.1.0.8A2|"..
            "4c407c00Lv0.1.1.8A2|"..
            "0c40a000Lv0.2.0.1A2|"..
            "4c40a000Lv0.2.1.1A2|"..
            "0c40a400Lv0.2.0.2A2|"..
            "4c40a400Lv0.2.1.2A2|"..
            "0c40a800Lv0.2.0.4A2|"..
            "4c40a800Lv0.2.1.4A2|"..
            "0c40ac00Lv0.2.0.8A2|"..
            "4c40ac00Lv0.2.1.8A2|"..
            "0c406000Lv0.3.0.1A2|"..
            "4c406000Lv0.3.1.1A2|"..
            "0c406400Lv0.3.0.2A2|"..
            "4c406400Lv0.3.1.2A2|"..
            "0c406800Lv0.3.0.4A2|"..
            "4c406800Lv0.3.1.4A2|"..
            "0c406c00Lv0.3.0.8A2|"..
            "4c406c00Lv0.3.1.8A2|"..
            "0c402000Lv0.4.0.1A2|"..
            "4c402000Lv0.4.1.1A2|"..
            "0c402400Lv0.4.0.2A2|"..
            "4c402400Lv0.4.1.2A2|"..
            "0c402800Lv0.4.0.4A2|"..
            "4c402800Lv0.4.1.4A2|"..
            "0c402c00Lv0.4.0.8A2|"..
            "4c402c00Lv0.4.1.8A2|"..
            "0d400000El1.1A2|"..
            "0d404000El1.2A2|"..
            "0d408000El1.4A2|"..
            "0d408400El1.8A2",

    ld1_3 = "0cdf7000Lv0.1.0.1A2I0.8|"..
            "4cdf7000Lv0.1.1.1A2I0.16|"..
            "0cdf7400Lv0.1.0.2A2I0.8|"..
            "4cdf7400Lv0.1.1.2A2I0.16|"..
            "0cdf7800Lv0.1.0.4A2I0.8|"..
            "4cdf7800Lv0.1.1.4A2I0.16|"..
            "0cdf7c00Lv0.1.0.8A2I0.8|"..
            "4cdf7c00Lv0.1.1.8A2I0.16|"..
            "0cc07000Lv0.1.0.1A2G2.1|"..
            "4cc07000Lv0.1.1.1A2G2.1|"..
            "0cc07400Lv0.1.0.2A2G2.1|"..
            "4cc07400Lv0.1.1.2A2G2.1|"..
            "0cc07800Lv0.1.0.4A2G2.1|"..
            "4cc07800Lv0.1.1.4A2G2.1|"..
            "0cc07c00Lv0.1.0.8A2G2.1|"..
            "4cc07c00Lv0.1.1.8A2G2.1|"..
            "0cdfa000Lv0.2.0.1A2I0.16|"..
            "4cdfa000Lv0.2.1.1A2I0.32|"..
            "0cdfa400Lv0.2.0.2A2I0.16|"..
            "4cdfa400Lv0.2.1.2A2I0.32|"..
            "0cdfa800Lv0.2.0.4A2I0.16|"..
            "4cdfa800Lv0.2.1.4A2I0.32|"..
            "0cdfac00Lv0.2.0.8A2I0.16|"..
            "4cdfac00Lv0.2.1.8A2I0.32|"..
            "0cc0a000Lv0.2.0.1A2G2.1|"..
            "4cc0a000Lv0.2.1.1A2G2.1|"..
            "0cc0a400Lv0.2.0.2A2G2.1|"..
            "4cc0a400Lv0.2.1.2A2G2.1|"..
            "0cc0a800Lv0.2.0.4A2G2.1|"..
            "4cc0a800Lv0.2.1.4A2G2.1|"..
            "0cc0ac00Lv0.2.0.8A2G2.1|"..
            "4cc0ac00Lv0.2.1.8A2G2.1|"..
            "0cdf6000Lv0.3.0.1A2I0.24|"..
            "4cdf6000Lv0.3.1.1A2I0.48|"..
            "0cdf6400Lv0.3.0.2A2I0.24|"..
            "4cdf6400Lv0.3.1.2A2I0.48|"..
            "0cdf6800Lv0.3.0.4A2I0.24|"..
            "4cdf6800Lv0.3.1.4A2I0.48|"..
            "0cdf6c00Lv0.3.0.8A2I0.24|"..
            "4cdf6c00Lv0.3.1.8A2I0.48|"..
            "0cc06000Lv0.3.0.1A2G2.1|"..
            "4cc06000Lv0.3.1.1A2G2.1|"..
            "0cc06400Lv0.3.0.2A2G2.1|"..
            "4cc06400Lv0.3.1.2A2G2.1|"..
            "0cc06800Lv0.3.0.4A2G2.1|"..
            "4cc06800Lv0.3.1.4A2G2.1|"..
            "0cc06c00Lv0.3.0.8A2G2.1|"..
            "4cc06c00Lv0.3.1.8A2G2.1|"..
            "0cdf2000Lv0.4.0.1A2I0.32|"..
            "4cdf2000Lv0.4.1.1A2I0.64|"..
            "0cdf2400Lv0.4.0.2A2I0.32|"..
            "4cdf2400Lv0.4.1.2A2I0.64|"..
            "0cdf2800Lv0.4.0.4A2I0.32|"..
            "4cdf2800Lv0.4.1.4A2I0.64|"..
            "0cdf2c00Lv0.4.0.8A2I0.32|"..
            "4cdf2c00Lv0.4.1.8A2I0.64|"..
            "0cc02000Lv0.4.0.1A2G2.1|"..
            "4cc02000Lv0.4.1.1A2G2.1|"..
            "0cc02400Lv0.4.0.2A2G2.1|"..
            "4cc02400Lv0.4.1.2A2G2.1|"..
            "0cc02800Lv0.4.0.4A2G2.1|"..
            "4cc02800Lv0.4.1.4A2G2.1|"..
            "0cc02c00Lv0.4.0.8A2G2.1|"..
            "4cc02c00Lv0.4.1.8A2G2.1|"..
            "0ddf0000El1.1A2I0.1|"..
            "0dc00000El1.1A2G2.1|"..
            "0ddf4000El1.2A2I0.2|"..
            "0dc04000El1.2A2G2.1|"..
            "0ddf8000El1.4A2I0.4|"..
            "0dc08000El1.4A2G2.1|"..
            "0ddf8400El1.8A2I0.8|"..
            "0dc08400El1.8A2G2.1",
    
    ld1r_2 = "0d40c000Lv0.1.0.1A2|"..
             "4d40c000Lv0.1.1.1A2|"..
             "0d40c400Lv0.1.0.2A2|"..
             "4d40c400Lv0.1.1.2A2|"..
             "0d40c800Lv0.1.0.4A2|"..
             "4d40c800Lv0.1.1.4A2|"..
             "0d40cc00Lv0.1.0.8A2|"..
             "4d40cc00Lv0.1.1.8A2",

    ld1r_3 = "0ddfc000Lv0.1.0.1A2I0.1|"..
             "0dc0c000Lv0.1.0.1A2G2.1|"..
             "4ddfc000Lv0.1.1.1A2I0.1|"..
             "4dc0c000Lv0.1.1.1A2G2.1|"..
             "0ddfc400Lv0.1.0.2A2I0.2|"..
             "0dc0c400Lv0.1.0.2A2G2.1|"..
             "4ddfc400Lv0.1.1.2A2I0.2|"..
             "4dc0c400Lv0.1.1.2A2G2.1|"..
             "0ddfc800Lv0.1.0.4A2I0.4|"..
             "0dc0c800Lv0.1.0.4A2G2.1|"..
             "4ddfc800Lv0.1.1.4A2I0.4|"..
             "4dc0c800Lv0.1.1.4A2G2.1|"..
             "0ddfcc00Lv0.1.0.8A2I0.8|"..
             "0dc0cc00Lv0.1.0.8A2G2.1|"..
             "4ddfcc00Lv0.1.1.8A2I0.8|"..
             "4dc0cc00Lv0.1.1.8A2G2.1",
    
    ld2_2 = "0c408000Lv0.2.0.1A2|"..
            "4c408000Lv0.2.1.1A2|"..
            "0c408400Lv0.2.0.2A2|"..
            "4c408400Lv0.2.1.2A2|"..
            "0c408800Lv0.2.0.4A2|"..
            "4c408800Lv0.2.1.4A2|"..
            "4c408c00Lv0.2.1.8A2|"..
            "0d600000El2.1A2|"..
            "0d604000El2.2A2|"..
            "0d608000El2.4A2|"..
            "0d608400El2.8A2",

    ld2_3 = "0cdf8000Lv0.2.0.1A2I0.16|"..
            "4cdf8000Lv0.2.1.1A2I0.32|"..
            "0cdf8400Lv0.2.0.2A2I0.16|"..
            "4cdf8400Lv0.2.1.2A2I0.32|"..
            "0cdf8800Lv0.2.0.4A2I0.16|"..
            "4cdf8800Lv0.2.1.4A2I0.32|"..
            "4cdf8c00Lv0.2.1.8A2I0.32|"..
            "0cc08000Lv0.2.0.1A2G2.1|"..
            "4cc08000Lv0.2.1.1A2G2.1|"..
            "0cc08400Lv0.2.0.2A2G2.1|"..
            "4cc08400Lv0.2.1.2A2G2.1|"..
            "0cc08800Lv0.2.0.4A2G2.1|"..
            "4cc08800Lv0.2.1.4A2G2.1|"..
            "4cc08c00Lv0.2.1.8A2G2.1|"..
            "0dff0000El2.1A2I0.2|"..
            "0de00000El2.1A2G2.1|"..
            "0dff4000El2.2A2I0.4|"..
            "0de04000El2.2A2G2.1|"..
            "0dff8000El2.4A2I0.8|"..
            "0de08000El2.4A2G2.1|"..
            "0dff8400El2.8A2I0.16|"..
            "0de08400El2.8A2G2.1",

    ld2r_2 ="0d60c000Lv0.2.0.1A2|"..
            "4d60c000Lv0.2.1.1A2|"..
            "0d60c400Lv0.2.0.2A2|"..
            "4d60c400Lv0.2.1.2A2|"..
            "0d60c800Lv0.2.0.4A2|"..
            "4d60c800Lv0.2.1.4A2|"..
            "0d60cc00Lv0.2.0.8A2|"..
            "4d60cc00Lv0.2.1.8A2",

    ld2r_3 ="0dffc000Lv0.2.0.1A2I0.2|"..
            "4dffc000Lv0.2.1.1A2I0.2|"..
            "0dffc400Lv0.2.0.2A2I0.4|"..
            "4dffc400Lv0.2.1.2A2I0.4|"..
            "0dffc800Lv0.2.0.4A2I0.8|"..
            "4dffc800Lv0.2.1.4A2I0.8|"..
            "0dffcc00Lv0.2.0.8A2I0.16|"..
            "4dffcc00Lv0.2.1.8A2I0.16|"..
            "0de0c000Lv0.2.0.1A2G2.1|"..
            "4de0c000Lv0.2.1.1A2G2.1|"..
            "0de0c400Lv0.2.0.2A2G2.1|"..
            "4de0c400Lv0.2.1.2A2G2.1|"..
            "0de0c800Lv0.2.0.4A2G2.1|"..
            "4de0c800Lv0.2.1.4A2G2.1|"..
            "0de0cc00Lv0.2.0.8A2G2.1|"..
            "4de0cc00Lv0.2.1.8A2G2.1",

    ld3_2 = "0c404000Lv0.3.0.1A2|"..
            "4c404000Lv0.3.1.1A2|"..
            "0c404400Lv0.3.0.2A2|"..
            "4c404400Lv0.3.1.2A2|"..
            "0c404800Lv0.3.0.4A2|"..
            "4c404800Lv0.3.1.4A2|"..
            "4c404c00Lv0.3.1.8A2|"..
            "0d402000El3.1A2|"..
            "0d406000El3.2A2|"..
            "0d40a000El3.4A2|"..
            "0d40a400El3.8A2",

    ld3_3 = "0cdf4000Lv0.3.0.1A2I0.24|"..
            "4cdf4000Lv0.3.1.1A2I0.48|"..
            "0cdf4400Lv0.3.0.2A2I0.24|"..
            "4cdf4400Lv0.3.1.2A2I0.48|"..
            "0cdf4800Lv0.3.0.4A2I0.24|"..
            "4cdf4800Lv0.3.1.4A2I0.48|"..
            "4cdf4c00Lv0.3.1.8A2I0.48|"..
            "0cc04000Lv0.3.0.1A2G2.1|"..
            "4cc04000Lv0.3.1.1A2G2.1|"..         
            "0cc04400Lv0.3.0.2A2G2.1|"..
            "4cc04400Lv0.3.1.2A2G2.1|"..         
            "0cc04800Lv0.3.0.4A2G2.1|"..
            "4cc04800Lv0.3.1.4A2G2.1|"..         
            "4cc04c00Lv0.3.1.8A2G2.1|"..         
            "0ddf2000El3.1A2I0.3|"..
            "0dc02000El3.1A2G2.1|"..
            "0ddf6000El3.2A2I0.6|"..
            "0dc06000El3.2A2G2.1|"..
            "0ddfa000El3.4A2I0.12|"..
            "0dc0a000El3.4A2G2.1|"..
            "0ddfa400El3.8A2I0.24|"..
            "0dc0a400El3.8A2G2.1",

    ld3r_2 ="0d40e000Lv0.3.0.1A2|"..
            "4d40e000Lv0.3.1.1A2|"..
            "0d40e400Lv0.3.0.2A2|"..
            "4d40e400Lv0.3.1.2A2|"..
            "0d40e800Lv0.3.0.4A2|"..
            "4d40e800Lv0.3.1.4A2|"..
            "0d40ec00Lv0.3.0.8A2|"..
            "4d40ec00Lv0.3.1.8A2",

    ld3r_3 ="0ddfe000Lv0.3.0.1A2I0.3|"..
            "4ddfe000Lv0.3.1.1A2I0.3|"..
            "0ddfe400Lv0.3.0.2A2I0.6|"..
            "4ddfe400Lv0.3.1.2A2I0.6|"..
            "0ddfe800Lv0.3.0.4A2I0.12|"..
            "4ddfe800Lv0.3.1.4A2I0.12|"..
            "0ddfec00Lv0.3.0.8A2I0.24|"..
            "4ddfec00Lv0.3.1.8A2I0.24|"..
            "0dc0e000Lv0.3.0.1A2G2.1|"..
            "4dc0e000Lv0.3.1.1A2G2.1|"..
            "0dc0e400Lv0.3.0.2A2G2.1|"..
            "4dc0e400Lv0.3.1.2A2G2.1|"..
            "0dc0e800Lv0.3.0.4A2G2.1|"..
            "4dc0e800Lv0.3.1.4A2G2.1|"..
            "0dc0ec00Lv0.3.0.8A2G2.1|"..
            "4dc0ec00Lv0.3.1.8A2G2.1",

    ld4_2 = "0c400000Lv0.4.0.1A2|"..
            "4c400000Lv0.4.1.1A2|"..
            "0c400400Lv0.4.0.2A2|"..
            "4c400400Lv0.4.1.2A2|"..
            "0c400800Lv0.4.0.4A2|"..
            "4c400800Lv0.4.1.4A2|"..
            "0c400c00Lv0.4.0.8A2|"..
            "4c400c00Lv0.4.1.8A2|"..
            "0d602000El4.1A2|"..
            "0d606000El4.2A2|"..
            "0d60a000El4.4A2|"..
            "0d60a400El4.8A2",

    ld4_3 = "0cdf0000Lv0.4.0.1A2I0.32|"..
            "4cdf0000Lv0.4.1.1A2I0.64|"..
            "0cdf0400Lv0.4.0.2A2I0.32|"..
            "4cdf0400Lv0.4.1.2A2I0.64|"..
            "0cdf0800Lv0.4.0.4A2I0.32|"..
            "4cdf0800Lv0.4.1.4A2I0.64|"..
            "4cdf0c00Lv0.4.1.8A2I0.64|"..
            "0cc00000Lv0.4.0.1A2G2.1|"..
            "4cc00000Lv0.4.1.1A2G2.1|"..
            "0cc00400Lv0.4.0.2A2G2.1|"..
            "4cc00400Lv0.4.1.2A2G2.1|"..
            "0cc00800Lv0.4.0.4A2G2.1|"..
            "4cc00800Lv0.4.1.4A2G2.1|"..
            "0cc00c00Lv0.4.0.8A2G2.1|"..
            "4cc00c00Lv0.4.1.8A2G2.1|"..
            "0dff2000El4.1A2I0.4|"..
            "0de02000El4.1A2G2.1|"..
            "0dff6000El4.2A2I0.8|"..
            "0de06000El4.2A2G2.1|"..
            "0dffa000El4.4A2I0.16|"..
            "0de0a000El4.4A2G2.1|"..
            "0dffa400El4.8A2I0.32|"..
            "0de0a400El4.8A2G2.1",

    ld4r_2 ="0d60e000Lv0.4.0.1A2|"..
            "4d60e000Lv0.4.1.1A2|"..
            "0d60e400Lv0.4.0.2A2|"..
            "4d60e400Lv0.4.1.2A2|"..
            "0d60e800Lv0.4.0.4A2|"..
            "4d60e800Lv0.4.1.4A2|"..
            "0d60ec00Lv0.4.0.8A2|"..
            "4d60ec00Lv0.4.1.8A2",

    ld4r_3 ="0dffe000Lv0.4.0.1A2I0.4|"..
            "4dffe000Lv0.4.1.1A2I0.4|"..
            "0dffe400Lv0.4.0.2A2I0.8|"..
            "4dffe400Lv0.4.1.2A2I0.8|"..
            "0dffe800Lv0.4.0.4A2I0.16|"..
            "4dffe800Lv0.4.1.4A2I0.16|"..
            "0dffec00Lv0.4.0.8A2I0.32|"..
            "4dffec00Lv0.4.1.8A2I0.32|"..
            "0de0e000Lv0.4.0.1A2G2.1|"..
            "4de0e000Lv0.4.1.1A2G2.1|"..
            "0de0e400Lv0.4.0.2A2G2.1|"..
            "4de0e400Lv0.4.1.2A2G2.1|"..
            "0de0e800Lv0.4.0.4A2G2.1|"..
            "4de0e800Lv0.4.1.4A2G2.1|"..
            "0de0ec00Lv0.4.0.8A2G2.1|"..
            "4de0ec00Lv0.4.1.8A2G2.1",

    ldnp_3 ="2c400000N0.4N4.4A1.2|"..
            "6c400000N0.8N4.8A1.3|"..
            "ac400000N0.16N4.16A1.4",

    ldp_4 = "2cc00000N0.4N4.4A2I15.2|"..
            "6cc00000N0.8N4.8A2I15.3|"..
            "acc00000N0.16N4.16A2I15.4",

    ldp_3 = "2dc00000N0.4N4.4A3.2|"..
            "6dc00000N0.8N4.8A3.3|"..
            "adc00000N0.16N4.16A3.4|"..
            "2d400000N0.4N4.4A1.2|"..
            "6d400000N0.8N4.8A1.3|"..
            "ad400000N0.16N4.16A1.4",

    ldr_3 = "3c400400N0.1A2I16|"..
            "7c400400N0.2A2I16|"..
            "bc400400N0.4A2I16|"..
            "fc400400N0.8A2I16|"..
            "3cc00400N0.16A2I16",

    ldr_2 = "3c400c00N0.1A4|"..
            "7c400c00N0.2A4|"..
            "bc400c00N0.4A4|"..
            "fc400c00N0.8A4|"..
            "3cc00c00N0.16A4|"..
            "3d400000N0.1A5|"..
            "7d400000N0.2A5.1|"..
            "bd400000N0.4A5.2|"..
            "fd400000N0.8A5.3|"..
            "3dc00000N0.16A5.4|"..
            "1c000000N0.4L3|"..
            "5c000000N0.8L3|"..
            "9c000000N0.16L3|"..
            "3c600800N0.1A6.0|"..
            "7c600800N0.2A6.1|"..
            "bc600800N0.4A6.2|"..
            "fc600800N0.8A6.3|"..
            "3ce00800N0.16A6.4",

    ldur_2 ="3c400000N0.1A7|"..
            "7c400000N0.2A7|"..
            "bc400000N0.4A7|"..
            "fc400000N0.8A7|"..
            "3cc00000N0.16A7",

    mla_3 = "2f400000V0.0.2V1.0.2Ev2.2.2|"..
            "6f400000V0.1.2V1.1.2Ev2.2.2|"..
            "2f800000V0.0.4V1.0.4Ev2.4.2|"..
            "6f800000V0.1.4V1.1.4Ev2.4.2|"..
            "0e209400V0.0.1V1.0.1V2.0.1|"..
            "4e209400V0.1.1V1.1.1V2.1.1|"..
            "0e609400V0.0.2V1.0.2V2.0.2|"..
            "4e609400V0.1.2V1.1.2V2.1.2|"..
            "0ea09400V0.0.4V1.0.4V2.0.4|"..
            "4ea09400V0.1.4V1.1.4V2.1.4",

    mls_3 = "2f404000V0.0.2V1.0.2Ev2.2.2|"..
            "6f404000V0.1.2V1.1.2Ev2.2.2|"..
            "2f804000V0.0.4V1.0.4Ev2.4.2|"..
            "6f804000V0.1.4V1.1.4Ev2.4.2|"..
            "2e209400V0.0.1V1.0.1V2.0.1|"..
            "6e209400V0.1.1V1.1.1V2.1.1|"..
            "2e609400V0.0.2V1.0.2V2.0.2|"..
            "6e609400V0.1.2V1.1.2V2.1.2|"..
            "2ea09400V0.0.4V1.0.4V2.0.4|"..
            "6ea09400V0.1.4V1.1.4V2.1.4",
    
    mov_2 = "5e010400N0.1Ev1.1.1|"..
            "5e020400N0.2Ev1.2.1|"..
            "5e040400N0.4Ev1.4.1|"..
            "5e080400N0.8Ev1.8.1|"..
            "6e010400Ev0.1.1Ev1.1.3|"..
            "6e020400Ev0.2.1Ev1.2.3|"..
            "6e040400Ev0.4.1Ev1.4.3|"..
            "6e080400Ev0.8.1Ev1.8.3|"..
            "4e011c00Ev0.1.1G1.0|"..
            "4e021c00Ev0.2.1G1.0|"..
            "4e041c00Ev0.4.1G1.0|"..
            "4e081c00Ev0.8.1G1.1|"..
            "0ea01c00V0.0.1V3.0.1|"..
            "4ea01c00V0.1.1V3.1.1|"..
            "0e043c00G0.0Ev1.4.1|"..
            "4e083c00G0.1Ev1.8.1",

    movi_2 ="0f00e400V0.0.1I20|"..
            "4f00e400V0.1.1I20|"..
            "0f008400V0.0.2I20|"..
            "4f008400V0.1.2I20|"..
            "0f000400V0.0.4I20|"..
            "4f000400V0.1.4I20|"..
            "2f00e400N0.8I23|"..
            "6f00e400V0.1.8I23",

    movi_3 ="0f00e400V0.0.1I20I21.0|"..
            "4f00e400V0.1.1I20I21.0|"..
            "0f008400V0.0.2I20I21.2|"..
            "4f008400V0.1.2I20I21.2|"..
            "0f000400V0.0.4I20I21.4|"..
            "4f000400V0.1.4I20I21.4|"..
            "0f00c400V0.0.4I20I22|"..
            "4f00c400V0.1.4I20I22",

    mul_3 = "0f408000V0.0.2V1.0.2Ev2.2.2|"..
            "4f408000V0.1.2V1.1.2Ev2.2.2|"..
            "0f808000V0.0.4V1.0.4Ev2.4.2|"..
            "4f808000V0.1.4V1.1.4Ev2.4.2|"..
            "0e209c00V0.0.1V1.0.1V2.0.1|"..
            "4e209c00V0.1.1V1.1.1V2.1.1|"..
            "0e609c00V0.0.2V1.0.2V2.0.2|"..
            "4e609c00V0.1.2V1.1.2V2.1.2|"..
            "0ea09c00V0.0.4V1.0.4V2.0.4|"..
            "4ea09c00V0.1.4V1.1.4V2.1.4",

    mvn_2 = "2e205800V0.0.1V1.0.1|"..
            "6e205800V0.1.1V1.1.1",

    mvni_2 ="2f008400V0.0.2I20|"..
            "6f008400V0.1.2I20|"..
            "2f000400V0.0.4I20|"..
            "6f000400V0.1.4I20",

    mvni_3 ="2f008400V0.0.2I20I21.2|"..
            "6f008400V0.1.2I20I21.2|"..
            "2f000400V0.0.4I20I21.4|"..
            "6f000400V0.1.4I20I21.4|"..
            "2f00c400V0.0.4I20I22|"..
            "6f00c400V0.1.4I20I22",
   
    neg_2 = "7ee0b800N0.8N1.8|"..
            "2e20b800V0.0.1V1.0.1|"..
            "6e20b800V0.1.1V1.1.1|"..
            "2e60b800V0.0.2V1.0.2|"..
            "6e60b800V0.1.2V1.1.2|"..
            "2ea0b800V0.0.4V1.0.4|"..
            "6ea0b800V0.1.4V1.1.4|"..
            "6ee0b800V0.1.8V1.1.8",

    not_2 = "2e205800V0.0.1V1.0.1|"..
            "6e205800V0.1.1V1.1.1",

    orn_3 = "0ee01c00V0.0.1V1.0.1V2.0.1|"..
            "4ee01c00V0.1.1V1.1.1V2.1.1",

    orr_2 = "0f009400V0.0.2I20|"..
            "4f009400V0.1.2I20|"..
            "0f001400V0.0.4I20|"..
            "4f001400V0.1.4I20",
    
    orr_3 = "0f009400V0.0.2I20I21.2|"..
            "4f009400V0.1.2I20I21.2|"..
            "0f001400V0.0.4I20I21.4|"..
            "4f001400V0.1.4I20I21.4|"..
            "0ea01c00V0.0.1V1.0.1V2.0.1|"..
            "4ea01c00V0.1.1V1.1.1V2.1.1",

    pmul_3 ="2e209c00V0.0.1V1.0.1V2.0.1|"..
            "6e209c00V0.1.1V1.1.1V2.1.1",

    pmull_3 = "0e20e000V0.1.2V1.0.1V2.0.1|"..
              "0ee0e000V0.1.16V1.0.8V2.0.8",

    pmull2_3 = "4e20e000V0.1.2V1.1.1V2.1.1|"..
               "4ee0e000V0.1.16V1.1.8V2.1.8",

    raddhn_3 = "2e204000V0.0.1V1.1.2V2.1.2|"..
               "2e604000V0.0.2V1.1.4V2.1.4|"..
               "2ea04000V0.0.4V1.1.8V2.1.8",

    raddhn2_3 = "6e204000V0.1.1V1.1.2V2.1.2|"..
                "6e604000V0.1.2V1.1.4V2.1.4|"..
                "6ea04000V0.1.4V1.1.8V2.1.8",

    rbit_2 ="2e605800V0.0.1V1.0.1|6e605800V0.1.1V1.1.1",

    rev16_2 = "0e201800V0.0.1V1.0.1|4e201800V0.1.1V1.1.1",

    rev32_2 =   "2e200800V0.0.1V1.0.1|"..
                "6e200800V0.1.1V1.1.1|"..
                "2e600800V0.0.2V1.0.2|"..
                "6e600800V0.1.2V1.1.2",

    rev64_2 =   "0e200800V0.0.1V1.0.1|"..
                "4e200800V0.1.1V1.1.1|"..
                "0e600800V0.0.2V1.0.2|"..
                "4e600800V0.1.2V1.1.2|"..
                "0ea00800V0.0.4V1.0.4|"..
                "4ea00800V0.1.4V1.1.4",

    rshrn_3 =   "0f088c00V0.0.1V1.1.2I25.3|"..
                "0f108c00V0.0.2V1.1.4I25.4|"..
                "0f208c00V0.0.4V1.1.8I25.5",

    rshrn2_3 =  "4f088c00V0.1.1V1.1.2I25.3|"..
                "4f108c00V0.1.2V1.1.4I25.4|"..
                "4f288c00V0.1.4V1.1.8I25.5",

    rsubhn_3 =  "2e206000V0.0.1V1.1.2V2.1.2|"..
                "2e606000V0.0.2V1.1.4V2.1.4|"..
                "2ea06000V0.0.4V1.1.8V2.1.8",

    rsubhn2_3 = "6e206000V0.1.1V1.1.2V2.1.2|"..
                "6e606000V0.1.2V1.1.4V2.1.4|"..
                "6ea06000V0.1.4V1.1.8V2.1.8",

    saba_3 ="0e207c00V0.0.1V1.0.1V2.0.1|"..
            "4e207c00V0.1.1V1.1.1V2.1.1|"..
            "0e607c00V0.0.2V1.0.2V2.0.2|"..
            "4e607c00V0.1.2V1.1.2V2.1.2|"..
            "0ea07c00V0.0.4V1.0.4V2.0.4|"..
            "4ea07c00V0.1.4V1.1.4V2.1.4",

    sabal_3 =   "0e205000V0.1.2V1.0.1V2.0.1|"..
                "0e605000V0.1.4V1.0.2V2.0.2|"..
                "0ea05000V0.1.8V1.0.4V2.0.4",

    sabal2_3 =  "4e205000V0.1.2V1.1.1V2.1.1|"..
                "4e605000V0.1.4V1.1.2V2.1.2|"..
                "4ea05000V0.1.8V1.1.4V2.1.4",

    sabd_3 ="0e207400V0.0.1V1.0.1V2.0.1|"..
            "4e207400V0.1.1V1.1.1V2.1.1|"..
            "0e607400V0.0.2V1.0.2V2.0.2|"..
            "4e607400V0.1.2V1.1.2V2.1.2|"..
            "0ea07400V0.0.4V1.0.4V2.0.4|"..
            "4ea07400V0.1.4V1.1.4V2.1.4",

    sabdl_3 =   "0e207000V0.1.2V1.0.1V2.0.1|"..
                "0e607000V0.1.4V1.0.2V2.0.2|"..
                "0ea07000V0.1.8V1.0.4V2.0.4",

    sabdl2_3 =  "4e207000V0.1.2V1.1.1V2.1.1|"..
                "4e607000V0.1.4V1.1.2V2.1.2|"..
                "4ea07000V0.1.8V1.1.4V2.1.4",

    sadalp_2 =  "0e206800V0.0.2V1.0.1|"..
                "4e206800V0.1.2V1.1.1|"..
                "0e606800V0.0.4V1.0.2|"..
                "4e606800V0.1.4V1.1.2|"..
                "0ea06800V0.0.8V1.0.4|"..
                "4ea06800V0.1.8V1.1.4",

    saddl_3 =   "0e200000V0.1.2V1.0.1V2.0.1|"..
                "0e600000V0.1.4V1.0.2V2.0.2|"..
                "0ea00000V0.1.8V1.0.4V2.0.4",

    saddl2_3 =  "4e200000V0.1.2V1.1.1V2.1.1|"..
                "4e600000V0.1.4V1.1.2V2.1.2|"..
                "4ea00000V0.1.8V1.1.4V2.1.4",

    saddlp_2 =  "0e202800V0.0.2V1.0.1|"..
                "4e202800V0.1.2V1.1.1|"..
                "0e602800V0.0.4V1.0.2|"..
                "4e602800V0.1.4V1.1.2|"..
                "0ea02800V0.0.8V1.0.4|"..
                "4ea02800V0.1.8V1.1.4",

    saddlv_2 =  "0e303800N0.2V1.0.1|"..
                "4e303800N0.2V1.1.1|"..
                "0e703800N0.4V1.0.2|"..
                "4e703800N0.4V1.1.2|"..
                "4eb03800N0.8V1.1.4",

    saddw_3 =   "0e201000V0.1.2V1.1.2V2.0.1|"..
                "0e601000V0.1.4V1.1.4V2.0.2|"..
                "0ea01000V0.1.8V1.1.8V2.0.4",

    saddw2_3 =  "4e201000V0.1.2V1.1.2V2.1.1|"..
                "4e601000V0.1.4V1.1.4V2.1.2|"..
                "4ea01000V0.1.8V1.1.8V2.1.4",

    scvtf_3 =   "5f20e400N0.4N1.4I25.5|"..
                "5f40e400N0.8N1.8I25.6|"..
                "0f20e400V0.0.4V1.0.4I25.5|"..
                "4f20e400V0.1.4V1.1.4I25.5|"..
                "4f40e400V0.1.8V1.1.8I25.6|"..
                "1e028000N0.4G1.0I26.0|"..
                "1e428000N0.8G1.0I26.0|"..
                "9e020000N0.4G1.1I26.1|"..
                "9e420000N0.8G1.1I26.1",

    scvtf_2 =   "5e21d800N0.4N1.4|"..
                "5e61d800N0.8N1.8|"..
                "0e21d800V0.0.4V1.0.4|"..
                "4e21d800V0.1.4V1.1.4|"..
                "4e61d800V0.1.8V1.1.8|"..
                "1e220000N0.4G1.0|"..
                "1e620000N0.8G1.0|"..
                "9e220000N0.4G1.1|"..
                "9e620000N0.8G1.1",

    sha1c_3 =   "5e000000N0.16N1.4V2.1.4",

    sha1h_2 =   "5e280800N0.4N1.4",

    sha1m_3 =   "5e002000N0.16N1.4V2.1.4",

    sha1p_3 =   "5e001000N0.16N1.4V2.1.4",

    sha1su0_3 = "5e003000V0.1.4V1.1.4V2.1.4",

    sha1su1_2 = "5e281800V0.1.4V1.1.4",

    sha256h2_3 = "5e005000N0.16N1.16V2.1.4",

    sha256h_3 = "5e004000N0.16N1.16V2.1.4",

    sha256su0_2 = "5e282800V0.1.4V1.1.4",
    
    sha256su1_3 = "5e006000V0.1.4V1.1.4V2.1.4",

    shadd_3 =   "0e200400V0.0.1V1.0.1V2.0.1|"..
                "4e200400V0.1.1V1.1.1V2.1.1|"..
                "0e600400V0.0.2V1.0.2V2.0.2|"..
                "4e600400V0.1.2V1.1.2V2.1.2|"..
                "0ea00400V0.0.4V1.0.4V2.0.4|"..
                "4ea00400V0.1.4V1.1.4V2.1.4",
    shl_3 = "5f405400N0.8N1.8I29.6|"..
            "0f085400V0.0.1V1.0.1I29.3|"..
            "4f085400V0.1.1V1.1.1I29.3|"..
            "0f105400V0.0.2V1.0.2I29.4|"..
            "4f105400V0.1.2V1.1.2I29.4|"..
            "0f205400V0.0.4V1.0.4I29.5|"..
            "4f205400V0.1.4V1.1.4I29.5|"..
            "4f405400V0.1.8V1.1.8I29.6",

    shll_3 ="2e213800V0.1.2V1.0.1I0.8|"..
            "2e613800V0.1.4V1.0.2I0.16|"..
            "2ea13800V0.1.8V1.0.4I0.32",

    shll2_3="6e213800V0.1.2V1.1.1I0.8|"..
            "6e613800V0.1.4V1.1.2I0.16|"..
            "6ea13800V0.1.8V1.1.4I0.32",

    shrn_3 ="0f088400V0.0.1V1.1.2I25.3|"..
            "0f108400V0.0.2V1.1.4I25.4|"..
            "0f208400V0.0.4V1.1.8I25.5",
    
    shrn2_3="4f088400V0.1.1V1.1.2I25.3|"..
            "4f108400V0.1.2V1.1.4I25.4|"..
            "4f208400V0.1.4V1.1.8I25.5",

    shsub_3="0e202400V0.0.1V1.0.1V2.0.1|"..
            "4e202400V0.1.1V1.1.1V2.1.1|"..
            "0e602400V0.0.2V1.0.2V2.0.2|"..
            "4e602400V0.1.2V1.1.2V2.1.2|"..
            "0ea02400V0.0.4V1.0.4V2.0.4|"..
            "4ea02400V0.1.4V1.1.4V2.1.4",


    sli_3 = "7f405400N0.8N1.8I29.6|"..
            "2f085400V0.0.1V1.0.1I29.3|"..
            "6f085400V0.1.1V1.1.1I29.3|"..
            "2f105400V0.0.2V1.0.2I29.4|"..
            "6f105400V0.1.2V1.1.2I29.4|"..
            "2f205400V0.0.4V1.0.4I29.5|"..
            "6f205400V0.1.4V1.1.4I29.5|"..
            "6f405400V0.1.8V1.1.8I29.6",

    smax_3 ="0e206400V0.0.1V1.0.1V2.0.1|"..
            "4e206400V0.1.1V1.1.1V2.1.1|"..
            "0e606400V0.0.2V1.0.2V2.0.2|"..
            "4e606400V0.1.2V1.1.2V2.1.2|"..
            "0ea06400V0.0.4V1.0.4V2.0.4|"..
            "4ea06400V0.1.4V1.1.4V2.1.4",

    smaxp_3="0e20a400V0.0.1V1.0.1V2.0.1|"..
            "4e20a400V0.1.1V1.1.1V2.1.1|"..
            "0e60a400V0.0.2V1.0.2V2.0.2|"..
            "4e60a400V0.1.2V1.1.2V2.1.2|"..
            "0ea0a400V0.0.4V1.0.4V2.0.4|"..
            "4ea0a400V0.1.4V1.1.4V2.1.4",

    smaxv_2="0e30a800N0.1V1.0.1|"..
            "4e30a800N0.1V1.1.1|"..
            "0e70a800N0.2V1.0.2|"..
            "4e70a800N0.2V1.1.2|"..
            "4eb0a800N0.4V1.1.4",
    
    smin_3 ="0e206c00V0.0.1V1.0.1V2.0.1|"..
            "4e206c00V0.1.1V1.1.1V2.1.1|"..
            "0e606c00V0.0.2V1.0.2V2.0.2|"..
            "4e606c00V0.1.2V1.1.2V2.1.2|"..
            "0ea06c00V0.0.4V1.0.4V2.0.4|"..
            "4ea06c00V0.1.4V1.1.4V2.1.4",

    sminp_3="0e20ac00V0.0.1V1.0.1V2.0.1|"..
            "4e20ac00V0.1.1V1.1.1V2.1.1|"..
            "0e60ac00V0.0.2V1.0.2V2.0.2|"..
            "4e60ac00V0.1.2V1.1.2V2.1.2|"..
            "0ea0ac00V0.0.4V1.0.4V2.0.4|"..
            "4ea0ac00V0.1.4V1.1.4V2.1.4",

    sminv_2="0e31a800N0.1V1.0.1|"..
            "4e31a800N0.1V1.1.1|"..
            "0e71a800N0.2V1.0.2|"..
            "4e71a800N0.2V1.1.2|"..
            "4eb1a800N0.4V1.1.4",

    smlal_3="0f402000V0.1.4V1.0.2Ev2.2.2|"..
            "0f802000V0.1.8V1.0.4Ev2.4.2|"..
            "0e208000V0.1.2V1.0.1V2.0.1|"..
            "0e608000V0.1.4V1.0.2V2.0.2|"..
            "0ea08000V0.1.8V1.0.4V2.0.4",

    smlal2_3="4f402000V0.1.4V1.1.2Ev2.2.2|"..
             "4f802000V0.1.8V1.1.4Ev2.4.2|"..
             "4e208000V0.1.2V1.1.1V2.1.1|"..
             "4e608000V0.1.4V1.1.2V2.1.2|"..
             "4ea08000V0.1.8V1.1.4V2.1.4",

    smlsl_3="0f406000V0.1.4V1.0.2Ev2.2.2|"..
            "0f806000V0.1.8V1.0.4Ev2.4.2|"..
            "0e20a000V0.1.2V1.0.1V2.0.1|"..
            "0e60a000V0.1.4V1.0.2V2.0.2|"..
            "0ea0a000V0.1.8V1.0.4V2.0.4",

    smlsl2_3="4f406000V0.1.4V1.1.2Ev2.2.2|"..
             "4f806000V0.1.8V1.1.4Ev2.4.2|"..
             "4e20a000V0.1.2V1.1.1V2.1.1|"..
             "4e60a000V0.1.4V1.1.2V2.1.2|"..
             "4ea0a000V0.1.8V1.1.4V2.1.4",

    smov_2 ="0e012c00G0.0Ev1.1.1|"..
            "0e022c00G0.0Ev1.2.1|"..
            "4e012c00G0.1Ev1.1.1|"..
            "4e022c00G0.1Ev1.2.1|"..
            "4e042c00G0.1Ev1.4.1",

    smull_3="0f40a000V0.1.4V1.0.2Ev2.2.2|"..
            "0f80a000V0.1.8V1.0.4Ev2.4.2|"..
            "0e20c000V0.1.2V1.0.1V2.0.1|"..
            "0e60c000V0.1.4V1.0.2V2.0.2|"..
            "0ea0c000V0.1.8V1.0.4V2.0.4",

    smull2_3="4f40a000V0.1.4V1.1.2Ev2.2.2|"..
             "4f80a000V0.1.8V1.1.4Ev2.4.2|"..
             "4e20c000V0.1.2V1.1.1V2.1.1|"..
             "4e60c000V0.1.4V1.1.2V2.1.2|"..
             "4ea0c000V0.1.8V1.1.4V2.1.4",

    sqabs_2 ="5e207800N0.1N1.1|"..
             "5e607800N0.2N1.2|"..
             "5ea07800N0.4N1.4|"..
             "5ee07800N0.8N1.8|"..
             "0e207800V0.0.1V1.0.1|"..
             "4e207800V0.1.1V1.1.1|"..
             "0e607800V0.0.2V1.0.2|"..
             "4e607800V0.1.2V1.1.2|"..
             "0ea07800V0.0.4V1.0.4|"..
             "4ea07800V0.1.4V1.1.4|"..
             "4ee07800V0.1.8V1.1.8",

    sqadd_3 ="5e200c00N0.1N1.1N2.1|"..
             "5e600c00N0.2N1.2N2.2|"..
             "5ea00c00N0.4N1.4N2.4|"..
             "5ee00c00N0.8N1.8N2.8|"..
             "0e200c00V0.0.1V1.0.1V2.0.1|"..
             "4e200c00V0.1.1V1.1.1V2.1.1|"..
             "0e600c00V0.0.2V1.0.2V2.0.2|"..
             "4e600c00V0.1.2V1.1.2V2.1.2|"..
             "0ea00c00V0.0.4V1.0.4V2.0.4|"..
             "4ea00c00V0.1.4V1.1.4V2.1.4|"..
             "4ee00c00V0.1.8V1.1.8V2.1.8",

    sqdmlal_3 = "5f403000N0.4N1.2Ev2.2.2|"..
                "5f803000N0.8N1.4Ev2.4.2|"..
                "0f403000V0.1.4V1.0.2Ev2.2.2|"..
                "0f803000V0.1.8V1.0.4Ev2.4.2|"..
                "5e609000N0.4N1.2N2.2|"..
                "5ea09000N0.8N1.4N2.4|"..
                "0e609000V0.1.4V1.0.2V2.0.2|"..
                "0ea09000V0.1.8V1.0.4V2.0.4",

    sqdmlal2_3 ="4f403000V0.1.4V1.1.2Ev2.2.2|"..
                "4f803000V0.1.8V1.1.4Ev2.4.2|"..
                "4e609000V0.1.4V1.1.2V2.1.2|"..
                "4ea09000V0.1.8V1.1.4V2.1.4",

    sqdmlsl_3 = "5f407000N0.4N1.2Ev2.2.2|"..
                "5f807000N0.8N1.4Ev2.4.2|"..
                "0f407000V0.1.4V1.0.2Ev2.2.2|"..
                "0f807000V0.1.8V1.0.4Ev2.4.2|"..
                "5e60b000N0.4N1.2N2.2|"..
                "5ea0b000N0.8N1.4N2.4|"..
                "0e60b000V0.1.4V1.0.2V2.0.2|"..
                "0ea0b000V0.1.8V1.0.4V2.0.4",

    sqdmlsl2_3 ="4f407000V0.1.4V1.1.2Ev2.2.2|"..
                "4f807000V0.1.8V1.1.4Ev2.4.2|"..
                "4e60b000V0.1.4V1.1.2V2.1.2|"..
                "4ea0b000V0.1.8V1.1.4V2.1.4",

    sqdmulh_3 = "5f40c000N0.2N1.2Ev2.2.2|"..
                "5f80c000N0.4N1.4Ev2.4.2|"..
                "0f40c000V0.1.2V1.0.2Ev2.2.2|"..
                "4f40c000V0.1.2V1.1.2Ev2.2.2|"..
                "0f80c000V0.1.4V1.0.4Ev2.4.2|"..
                "4f807000V0.1.4V1.1.4Ev2.4.2|"..
                "5e60b400N0.2N1.2N2.2|"..
                "5ea0b400N0.4N1.4N2.4|"..
                "0e60b400V0.1.2V1.0.2V2.0.2|"..
                "4e60b400V0.1.2V1.1.2V2.1.2|"..
                "0ea0b400V0.1.4V1.0.4V2.0.4|"..
                "4ea0b400V0.1.4V1.1.4V2.1.4",

    sqdmull_3 = "5f40b000N0.4N1.2Ev2.2.2|"..
                "5f80b000N0.8N1.4Ev2.4.2|"..
                "0f40b000V0.1.4V1.0.2Ev2.2.2|"..
                "0f80b000V0.1.8V1.0.4Ev2.4.2|"..
                "5e60d000N0.4N1.2N2.2|"..
                "5ea0d000N0.8N1.4N2.4|"..
                "0e60d000V0.1.4V1.0.2V2.0.2|"..
                "0ea0d000V0.1.8V1.0.4V2.0.4",

    sqdmull2_3 ="4f40b000V0.1.4V1.1.2Ev2.2.2|"..
                "4f80b000V0.1.8V1.1.4Ev2.4.2|"..
                "4e60d000V0.1.4V1.1.2V2.1.2|"..
                "4ea0d000V0.1.8V1.1.4V2.1.4",

    sqneg_2 ="7e207800N0.1N1.1|"..
             "7e607800N0.2N1.2|"..
             "7ea07800N0.4N1.4|"..
             "7ee07800N0.8N1.8|"..
             "2e207800V0.0.1V1.0.1|"..
             "6e207800V0.1.1V1.1.1|"..
             "2e607800V0.0.2V1.0.2|"..
             "6e607800V0.1.2V1.1.2|"..
             "2ea07800V0.0.4V1.0.4|"..
             "6ea07800V0.1.4V1.1.4|"..
             "6ee07800V0.1.8V1.1.8",


    sqrdmulh_3 ="5f40d000N0.2N1.2Ev2.2.2|"..
                "5f80d000N0.4N1.4Ev2.4.2|"..
                "0f40d000V0.1.2V1.0.2Ev2.2.2|"..
                "4f40d000V0.1.2V1.1.2Ev2.2.2|"..
                "0f80d000V0.1.4V1.0.4Ev2.4.2|"..
                "4f80d000V0.1.4V1.1.4Ev2.4.2|"..
                "7e60b400N0.2N1.2N2.2|"..
                "7ea0b400N0.4N1.4N2.4|"..
                "2e60b400V0.1.2V1.0.2V2.0.2|"..
                "6e60b400V0.1.2V1.1.2V2.1.2|"..
                "2ea0b400V0.1.4V1.0.4V2.0.4|"..
                "6ea0b400V0.1.4V1.1.4V2.1.4",

    sqrshl_3="5e205c00N0.1N1.1N2.1|"..
             "5e605c00N0.2N1.2N2.2|"..
             "5ea05c00N0.4N1.4N2.4|"..
             "5ee05c00N0.8N1.8N2.8|"..
             "0e205c00V0.0.1V1.0.1V2.0.1|"..
             "4e205c00V0.1.1V1.1.1V2.1.1|"..
             "0e605c00V0.0.2V1.0.2V2.0.2|"..
             "4e605c00V0.1.2V1.1.2V2.1.2|"..
             "0ea05c00V0.0.4V1.0.4V2.0.4|"..
             "4ea05c00V0.1.4V1.1.4V2.1.4|"..
             "4ee05c00V0.1.8V1.1.8V2.1.8",

    sqrshrn_3 = "5f089c00N0.1N1.2I25.3|"..
                "5f109c00N0.2N1.4I25.4|"..
                "5f209c00N0.4N1.8I25.5|"..
                "0f089c00V0.0.1V1.1.2I25.3|"..
                "0f109c00V0.0.2V1.1.4I25.4|"..
                "0f209c00V0.0.4V1.1.8I25.5",
    
    sqrshrn2_3= "4f089c00V0.1.1V1.1.2I25.3|"..
                "4f109c00V0.1.2V1.1.4I25.4|"..
                "4f209c00V0.1.4V1.1.8I25.5",

    sqrshrun_3 ="7f088c00N0.1N1.2I25.3|"..
                "7f108c00N0.2N1.4I25.4|"..
                "7f208c00N0.4N1.8I25.5|"..
                "2f088c00V0.0.1V1.1.2I25.3|"..
                "2f108c00V0.0.2V1.1.4I25.4|"..
                "2f208c00V0.0.4V1.1.8I25.5",
    
    sqrshrun2_3="6f088c00V0.1.1V1.1.2I25.3|"..
                "6f108c00V0.1.2V1.1.4I25.4|"..
                "6f208c00V0.1.4V1.1.8I25.5",

    sqshl_3 =   "5f087400N0.1N1.1I29.3|"..
                "5f107400N0.2N1.2I29.4|"..
                "5f207400N0.4N1.4I29.5|"..
                "5f407400N0.8N1.8I29.6|"..
                "0f087400V0.0.1V1.0.1I29.3|"..
                "4f087400V0.1.1V1.1.1I29.3|"..
                "0f107400V0.0.2V1.0.2I29.4|"..
                "4f107400V0.1.2V1.1.2I29.4|"..
                "0f207400V0.0.4V1.0.4I29.5|"..
                "4f207400V0.1.4V1.1.4I29.5|"..
                "4f407400V0.1.8V1.1.8I29.6|"..
                "5e204c00N0.1N1.1N2.1|"..
                "5e604c00N0.2N1.2N2.2|"..
                "5ea04c00N0.4N1.4N2.4|"..
                "5ee04c00N0.8N1.8N2.8|"..
                "0e204c00V0.0.1V1.0.1V2.0.1|"..
                "4e204c00V0.1.1V1.1.1V2.1.1|"..
                "0e604c00V0.0.2V1.0.2V2.0.2|"..
                "4e604c00V0.1.2V1.1.2V2.1.2|"..
                "0ea04c00V0.0.4V1.0.4V2.0.4|"..
                "4ea04c00V0.1.4V1.1.4V2.1.4|"..
                "4ee04c00V0.1.8V1.1.8V2.1.8",

    
    sqshlu_3 =  "7f086400N0.1N1.1I29.3|"..
                "7f106400N0.2N1.2I29.4|"..
                "7f206400N0.4N1.4I29.5|"..
                "7f406400N0.8N1.8I29.6|"..
                "2f086400V0.0.1V1.0.1I29.3|"..
                "6f086400V0.1.1V1.1.1I29.3|"..
                "2f106400V0.0.2V1.0.2I29.4|"..
                "6f106400V0.1.2V1.1.2I29.4|"..
                "2f206400V0.0.4V1.0.4I29.5|"..
                "6f206400V0.1.4V1.1.4I29.5|"..
                "6f406400V0.1.8V1.1.8I29.6|",

    sqshrn_3 =  "5f089400N0.1N1.2I25.3|"..
                "5f109400N0.2N1.4I25.4|"..
                "5f209400N0.4N1.8I25.5|"..
                "0f089400V0.0.1V1.1.2I25.3|"..
                "0f109400V0.0.2V1.1.4I25.4|"..
                "0f209400V0.0.4V1.1.8I25.5",
    
    sqshrn2_3=  "4f089400V0.1.1V1.1.2I25.3|"..
                "4f109400V0.1.2V1.1.4I25.4|"..
                "4f209400V0.1.4V1.1.8I25.5",

    sqrshrun_3 ="7f088400N0.1N1.2I25.3|"..
                "7f108400N0.2N1.4I25.4|"..
                "7f208400N0.4N1.8I25.5|"..
                "2f088400V0.0.1V1.1.2I25.3|"..
                "2f108400V0.0.2V1.1.4I25.4|"..
                "2f208400V0.0.4V1.1.8I25.5",
    
    sqrshrun2_3="6f088400V0.1.1V1.1.2I25.3|"..
                "6f108400V0.1.2V1.1.4I25.4|"..
                "6f208400V0.1.4V1.1.8I25.5",

    sqsub_3= "5e202c00N0.1N1.1N2.1|"..
             "5e602c00N0.2N1.2N2.2|"..
             "5ea02c00N0.4N1.4N2.4|"..
             "5ee02c00N0.8N1.8N2.8|"..
             "0e202c00V0.0.1V1.0.1V2.0.1|"..
             "4e202c00V0.1.1V1.1.1V2.1.1|"..
             "0e602c00V0.0.2V1.0.2V2.0.2|"..
             "4e602c00V0.1.2V1.1.2V2.1.2|"..
             "0ea02c00V0.0.4V1.0.4V2.0.4|"..
             "4ea02c00V0.1.4V1.1.4V2.1.4|"..
             "4ee02c00V0.1.8V1.1.8V2.1.8",

    sqxtn_2 =   "5e214800N0.1N1.2|"..
                "5e614800N0.2N1.4|"..
                "5ea14800N0.4N1.8|"..
                "0e214800V0.0.1V1.1.2|"..
                "0e614800V0.0.2V1.1.4|"..
                "0ea14800V0.0.4V1.1.8",

    sqxtn2_2 =  "4e214800V0.1.1V1.1.2|"..
                "4e614800V0.1.2V1.1.4|"..
                "4ea14800V0.1.4V1.1.8",

    sqxtun_2 =  "7e212800N0.1N1.2|"..
                "7e612800N0.2N1.4|"..
                "7ea12800N0.4N1.8|"..
                "2e212800V0.0.1V1.1.2|"..
                "2e612800V0.0.2V1.1.4|"..
                "2ea12800V0.0.4V1.1.8",

    sqxtun2_2 = "6e212800V0.1.1V1.1.2|"..
                "6e612800V0.1.2V1.1.4|"..
                "6ea12800V0.1.4V1.1.8",

    srhadd_3 =  "0e201400V0.0.1V1.0.1V2.0.1|"..
                "4e201400V0.1.1V1.1.1V2.1.1|"..
                "0e601400V0.0.2V1.0.2V2.0.2|"..
                "4e601400V0.1.2V1.1.2V2.1.2|"..
                "0ea01400V0.0.4V1.0.4V2.0.4|"..
                "4ea01400V0.1.4V1.1.4V2.1.4",

    sri_3 = "7f404400N0.8N1.8I25.6|"..
            "2f084400V0.0.1V1.0.1I25.3|"..
            "6f084400V0.1.1V1.1.1I25.3|"..
            "2f104400V0.0.2V1.0.2I25.4|"..
            "6f104400V0.1.2V1.1.2I25.4|"..
            "2f204400V0.0.4V1.0.4I25.5|"..
            "6f204400V0.1.4V1.1.4I25.5|"..
            "6f404400V0.1.8V1.1.8I25.6",

    srshl_3 ="5ee05400N0.8N1.8N2.8|"..
             "0e205400V0.0.1V1.0.1V2.0.1|"..
             "4e205400V0.1.1V1.1.1V2.1.1|"..
             "0e605400V0.0.2V1.0.2V2.0.2|"..
             "4e605400V0.1.2V1.1.2V2.1.2|"..
             "0ea05400V0.0.4V1.0.4V2.0.4|"..
             "4ea05400V0.1.4V1.1.4V2.1.4|"..
             "4ee05400V0.1.8V1.1.8V2.1.8",

    srshr_3 ="5f402400N0.8N1.8I25.6|"..
             "0f082400V0.0.1V1.0.1I25.3|"..
             "4f082400V0.1.1V1.1.1I25.3|"..
             "0f102400V0.0.2V1.0.2I25.4|"..
             "4f102400V0.1.2V1.1.2I25.4|"..
             "0f202400V0.0.4V1.0.4I25.5|"..
             "4f202400V0.1.4V1.1.4I25.5|"..
             "4f402400V0.1.8V1.1.8I25.6",

    srsra_3 ="5f403400N0.8N1.8I25.6|"..
             "0f083400V0.0.1V1.0.1I25.3|"..
             "4f083400V0.1.1V1.1.1I25.3|"..
             "0f103400V0.0.2V1.0.2I25.4|"..
             "4f103400V0.1.2V1.1.2I25.4|"..
             "0f203400V0.0.4V1.0.4I25.5|"..
             "4f203400V0.1.4V1.1.4I25.5|"..
             "4f403400V0.1.8V1.1.8I25.6",

    sshl_3 = "5ee04400N0.8N1.8N2.8|"..
             "0e204400V0.0.1V1.0.1V2.0.1|"..
             "4e204400V0.1.1V1.1.1V2.1.1|"..
             "0e604400V0.0.2V1.0.2V2.0.2|"..
             "4e604400V0.1.2V1.1.2V2.1.2|"..
             "0ea04400V0.0.4V1.0.4V2.0.4|"..
             "4ea04400V0.1.4V1.1.4V2.1.4|"..
             "4ee04400V0.1.8V1.1.8V2.1.8",

    sshll_3 ="0f08a400V0.1.2V1.0.1I29.3|"..
             "0f10a400V0.1.4V1.0.2I29.4|"..
             "0f20a400V0.1.8V1.0.4I29.5",

    sshll2_3 ="4f08a400V0.1.2V1.2.1I29.3|"..
              "4f10a400V0.1.4V1.2.2I29.4|"..
              "4f20a400V0.1.8V1.2.4I29.5",

    sshr_3 = "5f400400N0.8N1.8I25.6|"..
             "0f080400V0.0.1V1.0.1I25.3|"..
             "4f080400V0.1.1V1.1.1I25.3|"..
             "0f100400V0.0.2V1.0.2I25.4|"..
             "4f100400V0.1.2V1.1.2I25.4|"..
             "0f200400V0.0.4V1.0.4I25.5|"..
             "4f200400V0.1.4V1.1.4I25.5|"..
             "4f400400V0.1.8V1.1.8I25.6",

    ssra_3 = "5f401400N0.8N1.8I25.6|"..
             "0f081400V0.0.1V1.0.1I25.3|"..
             "4f081400V0.1.1V1.1.1I25.3|"..
             "0f101400V0.0.2V1.0.2I25.4|"..
             "4f101400V0.1.2V1.1.2I25.4|"..
             "0f201400V0.0.4V1.0.4I25.5|"..
             "4f201400V0.1.4V1.1.4I25.5|"..
             "4f401400V0.1.8V1.1.8I25.6",

    ssubl_3 =   "0e202000V0.1.2V1.0.1V2.0.1|"..
                "0e602000V0.1.4V1.0.2V2.0.2|"..
                "0ea02000V0.1.8V1.0.4V2.0.4",

    ssubl2_3 =  "4e202000V0.1.2V1.1.1V2.1.1|"..
                "4e602000V0.1.4V1.1.2V2.1.2|"..
                "4ea02000V0.1.8V1.1.4V2.1.4",

    ssubw_3 =   "0e203000V0.1.2V1.1.2V2.0.1|"..
                "0e603000V0.1.4V1.1.4V2.0.2|"..
                "0ea03000V0.1.8V1.1.8V2.0.4",

    ssubw2_3 =  "4e203000V0.1.2V1.1.2V2.1.1|"..
                "4e603000V0.1.4V1.1.4V2.1.2|"..
                "4ea03000V0.1.8V1.1.8V2.1.4",

    st1_2 = "0c007000Lv0.1.0.1A2|"..
            "4c007000Lv0.1.1.1A2|"..
            "0c007400Lv0.1.0.2A2|"..
            "4c007400Lv0.1.1.2A2|"..
            "0c007800Lv0.1.0.4A2|"..
            "4c007800Lv0.1.1.4A2|"..
            "0c007c00Lv0.1.0.8A2|"..
            "4c007c00Lv0.1.1.8A2|"..
            "0c00a000Lv0.2.0.1A2|"..
            "4c00a000Lv0.2.1.1A2|"..
            "0c00a400Lv0.2.0.2A2|"..
            "4c00a400Lv0.2.1.2A2|"..
            "0c00a800Lv0.2.0.4A2|"..
            "4c00a800Lv0.2.1.4A2|"..
            "0c00ac00Lv0.2.0.8A2|"..
            "4c00ac00Lv0.2.1.8A2|"..
            "0c006000Lv0.3.0.1A2|"..
            "4c006000Lv0.3.1.1A2|"..
            "0c006400Lv0.3.0.2A2|"..
            "4c006400Lv0.3.1.2A2|"..
            "0c006800Lv0.3.0.4A2|"..
            "4c006800Lv0.3.1.4A2|"..
            "0c006c00Lv0.3.0.8A2|"..
            "4c006c00Lv0.3.1.8A2|"..
            "0c002000Lv0.4.0.1A2|"..
            "4c002000Lv0.4.1.1A2|"..
            "0c002400Lv0.4.0.2A2|"..
            "4c002400Lv0.4.1.2A2|"..
            "0c002800Lv0.4.0.4A2|"..
            "4c002800Lv0.4.1.4A2|"..
            "0c002c00Lv0.4.0.8A2|"..
            "4c002c00Lv0.4.1.8A2|"..
            "0d000000El1.1A2|"..
            "0d004000El1.2A2|"..
            "0d008000El1.4A2|"..
            "0d008400El1.8A2",

    st1_3 = "0c9f7000Lv0.1.0.1A2I0.8|"..
            "4c9f7000Lv0.1.1.1A2I0.16|"..
            "0c9f7400Lv0.1.0.2A2I0.8|"..
            "4c9f7400Lv0.1.1.2A2I0.16|"..
            "0c9f7800Lv0.1.0.4A2I0.8|"..
            "4c9f7800Lv0.1.1.4A2I0.16|"..
            "0c9f7c00Lv0.1.0.8A2I0.8|"..
            "4c9f7c00Lv0.1.1.8A2I0.16|"..
            "0c807000Lv0.1.0.1A2G2.1|"..
            "4c807000Lv0.1.1.1A2G2.1|"..
            "0c807400Lv0.1.0.2A2G2.1|"..
            "4c807400Lv0.1.1.2A2G2.1|"..
            "0c807800Lv0.1.0.4A2G2.1|"..
            "4c807800Lv0.1.1.4A2G2.1|"..
            "0c807c00Lv0.1.0.8A2G2.1|"..
            "4c807c00Lv0.1.1.8A2G2.1|"..
            "0c9fa000Lv0.2.0.1A2I0.16|"..
            "4c9fa000Lv0.2.1.1A2I0.32|"..
            "0c9fa400Lv0.2.0.2A2I0.16|"..
            "4c9fa400Lv0.2.1.2A2I0.32|"..
            "0c9fa800Lv0.2.0.4A2I0.16|"..
            "4c9fa800Lv0.2.1.4A2I0.32|"..
            "0c9fac00Lv0.2.0.8A2I0.16|"..
            "4c9fac00Lv0.2.1.8A2I0.32|"..
            "0c80a000Lv0.2.0.1A2G2.1|"..
            "4c80a000Lv0.2.1.1A2G2.1|"..
            "0c80a400Lv0.2.0.2A2G2.1|"..
            "4c80a400Lv0.2.1.2A2G2.1|"..
            "0c80a800Lv0.2.0.4A2G2.1|"..
            "4c80a800Lv0.2.1.4A2G2.1|"..
            "0c80ac00Lv0.2.0.8A2G2.1|"..
            "4c80ac00Lv0.2.1.8A2G2.1|"..
            "0c9f6000Lv0.3.0.1A2I0.24|"..
            "4c9f6000Lv0.3.1.1A2I0.48|"..
            "0c9f6400Lv0.3.0.2A2I0.24|"..
            "4c9f6400Lv0.3.1.2A2I0.48|"..
            "0c9f6800Lv0.3.0.4A2I0.24|"..
            "4c9f6800Lv0.3.1.4A2I0.48|"..
            "0c9f6c00Lv0.3.0.8A2I0.24|"..
            "4c9f6c00Lv0.3.1.8A2I0.48|"..
            "0c806000Lv0.3.0.1A2G2.1|"..
            "4c806000Lv0.3.1.1A2G2.1|"..
            "0c806400Lv0.3.0.2A2G2.1|"..
            "4c806400Lv0.3.1.2A2G2.1|"..
            "0c806800Lv0.3.0.4A2G2.1|"..
            "4c806800Lv0.3.1.4A2G2.1|"..
            "0c806c00Lv0.3.0.8A2G2.1|"..
            "4c806c00Lv0.3.1.8A2G2.1|"..
            "0c9f2000Lv0.4.0.1A2I0.32|"..
            "4c9f2000Lv0.4.1.1A2I0.64|"..
            "0c9f2400Lv0.4.0.2A2I0.32|"..
            "4c9f2400Lv0.4.1.2A2I0.64|"..
            "0c9f2800Lv0.4.0.4A2I0.32|"..
            "4c9f2800Lv0.4.1.4A2I0.64|"..
            "0c9f2c00Lv0.4.0.8A2I0.32|"..
            "4c9f2c00Lv0.4.1.8A2I0.64|"..
            "0c802000Lv0.4.0.1A2G2.1|"..
            "4c802000Lv0.4.1.1A2G2.1|"..
            "0c802400Lv0.4.0.2A2G2.1|"..
            "4c802400Lv0.4.1.2A2G2.1|"..
            "0c802800Lv0.4.0.4A2G2.1|"..
            "4c802800Lv0.4.1.4A2G2.1|"..
            "0c802c00Lv0.4.0.8A2G2.1|"..
            "4c802c00Lv0.4.1.8A2G2.1|"..
            "0d9f0000El1.1A2I0.1|"..
            "0d800000El1.1A2G2.1|"..
            "0d9f4000El1.2A2I0.2|"..
            "0d804000El1.2A2G2.1|"..
            "0d9f8000El1.4A2I0.4|"..
            "0d808000El1.4A2G2.1|"..
            "0d9f8400El1.8A2I0.8|"..
            "0d808400El1.8A2G2.1",
    
    st2_2 = "0c008000Lv0.2.0.1A2|"..
            "4c008000Lv0.2.1.1A2|"..
            "0c008400Lv0.2.0.2A2|"..
            "4c008400Lv0.2.1.2A2|"..
            "0c008800Lv0.2.0.4A2|"..
            "4c008800Lv0.2.1.4A2|"..
            "4c008c00Lv0.2.1.8A2|"..
            "0d200000El2.1A2|"..
            "0d204000El2.2A2|"..
            "0d208000El2.4A2|"..
            "0d208400El2.8A2",

    st2_3 = "0c9f8000Lv0.2.0.1A2I0.16|"..
            "4c9f8000Lv0.2.1.1A2I0.32|"..
            "0c9f8400Lv0.2.0.2A2I0.16|"..
            "4c9f8400Lv0.2.1.2A2I0.32|"..
            "0c9f8800Lv0.2.0.4A2I0.16|"..
            "4c9f8800Lv0.2.1.4A2I0.32|"..
            "4c9f8c00Lv0.2.1.8A2I0.32|"..
            "0c808000Lv0.2.0.1A2G2.1|"..
            "4c808000Lv0.2.1.1A2G2.1|"..
            "0c808400Lv0.2.0.2A2G2.1|"..
            "4c808400Lv0.2.1.2A2G2.1|"..
            "0c808800Lv0.2.0.4A2G2.1|"..
            "4c808800Lv0.2.1.4A2G2.1|"..
            "4c808c00Lv0.2.1.8A2G2.1|"..
            "0dbf0000El2.1A2I0.2|"..
            "0da00000El2.1A2G2.1|"..
            "0dbf4000El2.2A2I0.4|"..
            "0da04000El2.2A2G2.1|"..
            "0dbf8000El2.4A2I0.8|"..
            "0da08000El2.4A2G2.1|"..
            "0dbf8400El2.8A2I0.16|"..
            "0da08400El2.8A2G2.1",

    st3_2 = "0c004000Lv0.3.0.1A2|"..
            "4c004000Lv0.3.1.1A2|"..
            "0c004400Lv0.3.0.2A2|"..
            "4c004400Lv0.3.1.2A2|"..
            "0c004800Lv0.3.0.4A2|"..
            "4c004800Lv0.3.1.4A2|"..
            "4c004c00Lv0.3.1.8A2|"..
            "0d002000El3.1A2|"..
            "0d006000El3.2A2|"..
            "0d00a000El3.4A2|"..
            "0d00a400El3.8A2",

    st3_3 = "0c9f4000Lv0.3.0.1A2I0.24|"..
            "4c9f4000Lv0.3.1.1A2I0.48|"..
            "0c9f4400Lv0.3.0.2A2I0.24|"..
            "4c9f4400Lv0.3.1.2A2I0.48|"..
            "0c9f4800Lv0.3.0.4A2I0.24|"..
            "4c9f4800Lv0.3.1.4A2I0.48|"..
            "4c9f4c00Lv0.3.1.8A2I0.48|"..
            "0c804000Lv0.3.0.1A2G2.1|"..
            "4c804000Lv0.3.1.1A2G2.1|"..         
            "0c804400Lv0.3.0.2A2G2.1|"..
            "4c804400Lv0.3.1.2A2G2.1|"..         
            "0c804800Lv0.3.0.4A2G2.1|"..
            "4c804800Lv0.3.1.4A2G2.1|"..         
            "4c804c00Lv0.3.1.8A2G2.1|"..         
            "0d9f2000El3.1A2I0.3|"..
            "0d802000El3.1A2G2.1|"..
            "0d9f6000El3.2A2I0.6|"..
            "0d806000El3.2A2G2.1|"..
            "0d9fa000El3.4A2I0.12|"..
            "0d80a000El3.4A2G2.1|"..
            "0d9fa400El3.8A2I0.24|"..
            "0d80a400El3.8A2G2.1",

    st4_2 = "0c000000Lv0.4.0.1A2|"..
            "4c000000Lv0.4.1.1A2|"..
            "0c000400Lv0.4.0.2A2|"..
            "4c000400Lv0.4.1.2A2|"..
            "0c000800Lv0.4.0.4A2|"..
            "4c000800Lv0.4.1.4A2|"..
            "0c000c00Lv0.4.0.8A2|"..
            "4c000c00Lv0.4.1.8A2|"..
            "0d202000El4.1A2|"..
            "0d206000El4.2A2|"..
            "0d20a000El4.4A2|"..
            "0d20a400El4.8A2",

    st4_3 = "0c9f0000Lv0.4.0.1A2I0.32|"..
            "4c9f0000Lv0.4.1.1A2I0.64|"..
            "0c9f0400Lv0.4.0.2A2I0.32|"..
            "4c9f0400Lv0.4.1.2A2I0.64|"..
            "0c9f0800Lv0.4.0.4A2I0.32|"..
            "4c9f0800Lv0.4.1.4A2I0.64|"..
            "4c9f0c00Lv0.4.1.8A2I0.64|"..
            "0c800000Lv0.4.0.1A2G2.1|"..
            "4c800000Lv0.4.1.1A2G2.1|"..
            "0c800400Lv0.4.0.2A2G2.1|"..
            "4c800400Lv0.4.1.2A2G2.1|"..
            "0c800800Lv0.4.0.4A2G2.1|"..
            "4c800800Lv0.4.1.4A2G2.1|"..
            "0c800c00Lv0.4.0.8A2G2.1|"..
            "4c800c00Lv0.4.1.8A2G2.1|"..
            "0dbf2000El4.1A2I0.4|"..
            "0da02000El4.1A2G2.1|"..
            "0dbf6000El4.2A2I0.8|"..
            "0da06000El4.2A2G2.1|"..
            "0dbfa000El4.4A2I0.16|"..
            "0da0a000El4.4A2G2.1|"..
            "0dbfa400El4.8A2I0.32|"..
            "0da0a400El4.8A2G2.1",

    stnp_3 ="2c000000N0.4N4.4A1.2|"..
            "6c000000N0.8N4.8A1.3|"..
            "ac000000N0.16N4.16A1.4",

    stp_4 = "2c800000N0.4N4.4A2I15.2|"..
            "6c800000N0.8N4.8A2I15.3|"..
            "ac800000N0.16N4.16A2I15.4",

    stp_3 = "2d800000N0.4N4.4A3.2|"..
            "6d800000N0.8N4.8A3.3|"..
            "ad800000N0.16N4.16A3.4|"..
            "2d000000N0.4N4.4A1.2|"..
            "6d000000N0.8N4.8A1.3|"..
            "ad000000N0.16N4.16A1.4",

    str_3 = "3c000400N0.1A2I16|"..
            "7c000400N0.2A2I16|"..
            "bc000400N0.4A2I16|"..
            "fc000400N0.8A2I16|"..
            "3c800400N0.16A2I16",

    str_2 = "3c000c00N0.1A4|"..
            "7c000c00N0.2A4|"..
            "bc000c00N0.4A4|"..
            "fc000c00N0.8A4|"..
            "3c800c00N0.16A4|"..
            "3d000000N0.1A5|"..
            "7d000000N0.2A5.1|"..
            "bd000000N0.4A5.2|"..
            "fd000000N0.8A5.3|"..
            "3d800000N0.16A5.4|"..
            "3c200800N0.1A6.0|"..
            "7c200800N0.2A6.1|"..
            "bc200800N0.4A6.2|"..
            "fc200800N0.8A6.3|"..
            "3ca00800N0.16A6.4",

    stur_2 ="3c000000N0.1A7|"..
            "7c000000N0.2A7|"..
            "bc000000N0.4A7|"..
            "fc000000N0.8A7|"..
            "3c800000N0.16A7",

    sub_3 = "7ee08400N0.8N1.8N2.8|"..
            "2e208400V0.0.1V1.0.1V2.0.1|"..
            "6e208400V0.1.1V1.1.1V2.1.1|"..
            "2e608400V0.0.2V1.0.2V2.0.2|"..
            "6e608400V0.1.2V1.1.2V2.1.2|"..
            "2ea08400V0.0.4V1.0.4V2.0.4|"..
            "6ea08400V0.1.4V1.1.4V2.1.4|"..
            "6ee08400V0.1.8V1.1.8V2.1.8",

    subhn_3 =   "0e206000V0.0.1V1.1.2V2.1.2|"..
                "0e606000V0.0.2V1.1.4V2.1.4|"..
                "0ea06000V0.0.4V1.1.8V2.1.8",

    subhn2_3 =  "4e206000V0.1.1V1.1.2V2.1.2|"..
                "4e606000V0.1.2V1.1.4V2.1.4|"..
                "4ea06000V0.1.4V1.1.8V2.1.8",

    suqadd_2 =  "5e203800N0.1N1.1|"..
                "5e603800N0.2N1.2|"..
                "5ea03800N0.4N1.4|"..
                "5ee03800N0.8N1.8|"..
                "0e203800V0.0.1V1.0.1|"..
                "4e203800V0.1.1V1.1.1|"..
                "0e603800V0.0.2V1.0.2|"..
                "4e603800V0.1.2V1.1.2|"..
                "0ea03800V0.0.4V1.0.4|"..
                "4ea03800V0.1.4V1.1.4|"..
                "4ee03800V0.1.8V1.1.8",

    sxtl_2 =    "0f08a400V0.1.2V1.0.1|"..
                "0f10a400V0.1.4V1.0.2|"..
                "0f20a400V0.1.8V1.0.4",
    
    sxtl2_2 =   "4f08a400V0.1.2V1.1.1|"..
                "4f10a400V0.1.4V1.1.2|"..
                "4f20a400V0.1.8V1.1.4",

    tbl_3 = "0e000000V0.0.1Lv1.1.1.1V2.0.1|"..
            "4e000000V0.1.1Lv1.1.1.1V2.1.1|"..
            "0e002000V0.0.1Lv1.2.1.1V2.0.1|"..
            "4e002000V0.1.1Lv1.2.1.1V2.1.1|"..
            "0e004000V0.0.1Lv1.3.1.1V2.0.1|"..
            "4e004000V0.1.1Lv1.3.1.1V2.1.1|"..
            "0e006000V0.0.1Lv1.4.1.1V2.0.1|"..
            "4e006000V0.1.1Lv1.4.1.1V2.1.1",

    tbx_3 = "0e001000V0.0.1Lv1.1.1.1V2.0.1|"..
            "4e001000V0.1.1Lv1.1.1.1V2.1.1|"..
            "0e003000V0.0.1Lv1.2.1.1V2.0.1|"..
            "4e003000V0.1.1Lv1.2.1.1V2.1.1|"..
            "0e005000V0.0.1Lv1.3.1.1V2.0.1|"..
            "4e005000V0.1.1Lv1.3.1.1V2.1.1|"..
            "0e007000V0.0.1Lv1.4.1.1V2.0.1|"..
            "4e007000V0.1.1Lv1.4.1.1V2.1.1",

    trn1_3 ="0e002800V0.0.1V1.0.1V2.0.1|"..
            "4e002800V0.1.1V1.1.1V2.1.1|"..
            "0e402800V0.0.2V1.0.2V2.0.2|"..
            "4e402800V0.1.2V1.1.2V2.1.2|"..
            "0e802800V0.0.4V1.0.4V2.0.4|"..
            "4e802800V0.1.4V1.1.4V2.1.4|"..
            "4ec02800V0.1.8V1.1.8V2.1.8",

    trn2_3 ="0e006800V0.0.1V1.0.1V2.0.1|"..
            "4e006800V0.1.1V1.1.1V2.1.1|"..
            "0e406800V0.0.2V1.0.2V2.0.2|"..
            "4e406800V0.1.2V1.1.2V2.1.2|"..
            "0e806800V0.0.4V1.0.4V2.0.4|"..
            "4e806800V0.1.4V1.1.4V2.1.4|"..
            "4ec06800V0.1.8V1.1.8V2.1.8",

    uaba_3 ="2e207c00V0.0.1V1.0.1V2.0.1|"..
            "6e207c00V0.1.1V1.1.1V2.1.1|"..
            "2e607c00V0.0.2V1.0.2V2.0.2|"..
            "6e607c00V0.1.2V1.1.2V2.1.2|"..
            "2ea07c00V0.0.4V1.0.4V2.0.4|"..
            "6ea07c00V0.1.4V1.1.4V2.1.4",

    uabal_3 =   "2e205000V0.1.2V1.0.1V2.0.1|"..
                "2e605000V0.1.4V1.0.2V2.0.2|"..
                "2ea05000V0.1.8V1.0.4V2.0.4",
    
    uabal2_3 =  "6e205000V0.1.2V1.1.1V2.1.1|"..
                "6e605000V0.1.4V1.1.2V2.1.2|"..
                "6ea05000V0.1.8V1.1.4V2.1.4",

    uabd_3 ="2e207400V0.0.1V1.0.1V2.0.1|"..
            "6e207400V0.1.1V1.1.1V2.1.1|"..
            "2e607400V0.0.2V1.0.2V2.0.2|"..
            "6e607400V0.1.2V1.1.2V2.1.2|"..
            "2ea07400V0.0.4V1.0.4V2.0.4|"..
            "6ea07400V0.1.4V1.1.4V2.1.4",

    uabdl_3 =   "2e207000V0.1.2V1.0.1V2.0.1|"..
                "2e607000V0.1.4V1.0.2V2.0.2|"..
                "2ea07000V0.1.8V1.0.4V2.0.4",
    
    uabdl2_3 =  "6e207000V0.1.2V1.1.1V2.1.1|"..
                "6e607000V0.1.4V1.1.2V2.1.2|"..
                "6ea07000V0.1.8V1.1.4V2.1.4",

    uadalp_2 =  "2e206800V0.0.2V1.0.1|"..
                "6e206800V0.1.2V1.1.1|"..
                "2e606800V0.0.4V1.0.2|"..
                "6e606800V0.1.4V1.1.2|"..
                "2ea06800V0.0.8V1.0.4|"..
                "6ea06800V0.1.8V1.1.4",
    
    uaddl_2 =   "2e200000V0.1.2V1.0.1V2.0.1|"..
                "2e600000V0.1.4V1.0.2V2.0.2|"..
                "2ea00000V0.1.8V1.0.4V2.0.4",
    
    uaddl2_2 =  "6e200000V0.1.2V1.1.1V2.1.1|"..
                "6e600000V0.1.4V1.1.2V2.1.2|"..
                "6ea00000V0.1.8V1.1.4V2.1.4",

    uaddlp_2 =  "2e202800V0.0.2V1.0.1|"..
                "6e202800V0.1.2V1.1.1|"..
                "2e602800V0.0.4V1.0.2|"..
                "6e602800V0.1.4V1.1.2|"..
                "2ea02800V0.0.8V1.0.4|"..
                "6ea02800V0.1.8V1.1.4",
    
    uaddlv_2 =  "2e303800N0.2V1.0.1|"..
                "6e303800N0.2V1.1.1|"..
                "2e703800N0.4V1.0.2|"..
                "6e703800N0.4V1.1.2|"..
                "6eb03800N0.8V1.1.4",

    uaddw_2 =   "2e201000V0.1.2V1.0.1V2.0.1|"..
                "2e601000V0.1.4V1.0.2V2.0.2|"..
                "2ea01000V0.1.8V1.0.4V2.0.4",
    
    uaddw2_2 =  "6e201000V0.1.2V1.1.1V2.1.1|"..
                "6e601000V0.1.4V1.1.2V2.1.2|"..
                "6ea01000V0.1.8V1.1.4V2.1.4",

    ucvtf_3 =   "7f20e400N0.4N1.4I25.5|"..
                "7f40e400N0.8N1.8I25.6|"..
                "2f20e400V0.0.4V1.0.4I25.5|"..
                "6f20e400V0.1.4V1.1.4I25.5|"..
                "6f40e400V0.1.8V1.1.8I25.6|"..
                "1e038000N0.4G1.0I26.0|"..
                "1e438000N0.8G1.0I26.0|"..
                "9e030000N0.4G1.1I26.1|"..
                "9e430000N0.8G1.1I26.1",

    ucvtf_2 =   "7e21d800N0.4N1.4|"..
                "7e61d800N0.8N1.8|"..
                "2e21d800V0.0.4V1.0.4|"..
                "6e21d800V0.1.4V1.1.4|"..
                "6e61d800V0.1.8V1.1.8|"..
                "1e230000N0.4G1.0|"..
                "1e630000N0.8G1.0|"..
                "9e230000N0.4G1.1|"..
                "9e630000N0.8G1.1",

    uhadd_3 =   "2e200400V0.0.1V1.0.1V2.0.1|"..
                "6e200400V0.1.1V1.1.1V2.1.1|"..
                "2e600400V0.0.2V1.0.2V2.0.2|"..
                "6e600400V0.1.2V1.1.2V2.1.2|"..
                "2ea00400V0.0.4V1.0.4V2.0.4|"..
                "6ea00400V0.1.4V1.1.4V2.1.4",

    uhsub_3 =   "2e202400V0.0.1V1.0.1V2.0.1|"..
                "6e202400V0.1.1V1.1.1V2.1.1|"..
                "2e602400V0.0.2V1.0.2V2.0.2|"..
                "6e602400V0.1.2V1.1.2V2.1.2|"..
                "2ea02400V0.0.4V1.0.4V2.0.4|"..
                "6ea02400V0.1.4V1.1.4V2.1.4",

    umax_3 =    "2e206400V0.0.1V1.0.1V2.0.1|"..
                "6e206400V0.1.1V1.1.1V2.1.1|"..
                "2e606400V0.0.2V1.0.2V2.0.2|"..
                "6e606400V0.1.2V1.1.2V2.1.2|"..
                "2ea06400V0.0.4V1.0.4V2.0.4|"..
                "6ea06400V0.1.4V1.1.4V2.1.4",

    umaxp_3 =   "2e20a400V0.0.1V1.0.1V2.0.1|"..
                "6e20a400V0.1.1V1.1.1V2.1.1|"..
                "2e60a400V0.0.2V1.0.2V2.0.2|"..
                "6e60a400V0.1.2V1.1.2V2.1.2|"..
                "2ea0a400V0.0.4V1.0.4V2.0.4|"..
                "6ea0a400V0.1.4V1.1.4V2.1.4",

    umaxv_2 =   "2e30a800N0.1V1.0.1|"..
                "6e30a800N0.1V1.1.1|"..
                "2e70a800N0.2V1.0.2|"..
                "6e70a800N0.2V1.1.2|"..
                "6eb0a800N0.4V1.1.4",

    umin_3 =    "2e206c00V0.0.1V1.0.1V2.0.1|"..
                "6e206c00V0.1.1V1.1.1V2.1.1|"..
                "2e606c00V0.0.2V1.0.2V2.0.2|"..
                "6e606c00V0.1.2V1.1.2V2.1.2|"..
                "2ea06c00V0.0.4V1.0.4V2.0.4|"..
                "6ea06c00V0.1.4V1.1.4V2.1.4",

    uminp_3 =   "2e20ac00V0.0.1V1.0.1V2.0.1|"..
                "6e20ac00V0.1.1V1.1.1V2.1.1|"..
                "2e60ac00V0.0.2V1.0.2V2.0.2|"..
                "6e60ac00V0.1.2V1.1.2V2.1.2|"..
                "2ea0ac00V0.0.4V1.0.4V2.0.4|"..
                "6ea0ac00V0.1.4V1.1.4V2.1.4",

    uminv_2 =   "2e31a800N0.1V1.0.1|"..
                "6e31a800N0.1V1.1.1|"..
                "2e71a800N0.2V1.0.2|"..
                "6e71a800N0.2V1.1.2|"..
                "6eb1a800N0.4V1.1.4",

    umlal_3 =   "2f402000V0.1.4V1.0.2Ev2.2.2|"..
                "2f802000V0.1.8V1.0.4Ev2.4.2|"..
                "2e208000V0.1.2V1.0.1V2.0.1|"..
                "2e608000V0.1.4V1.0.2V2.0.2|"..
                "2ea08000V0.1.8V1.0.4V2.0.4",

    umlal2_3 =  "6f402000V0.1.4V1.1.2Ev2.2.2|"..
                "6f802000V0.1.8V1.1.4Ev2.4.2|"..
                "6e208000V0.1.2V1.1.1V2.1.1|"..
                "6e608000V0.1.4V1.1.2V2.1.2|"..
                "6ea08000V0.1.8V1.1.4V2.1.4",

    umlsl_3 =   "2f406000V0.1.4V1.0.2Ev2.2.2|"..
                "2f806000V0.1.8V1.0.4Ev2.4.2|"..
                "2e20a000V0.1.2V1.0.1V2.0.1|"..
                "2e60a000V0.1.4V1.0.2V2.0.2|"..
                "2ea0a000V0.1.8V1.0.4V2.0.4",

    umlsl2_3 =  "6f406000V0.1.4V1.1.2Ev2.2.2|"..
                "6f806000V0.1.8V1.1.4Ev2.4.2|"..
                "6e20a000V0.1.2V1.1.1V2.1.1|"..
                "6e60a000V0.1.4V1.1.2V2.1.2|"..
                "6ea0a000V0.1.8V1.1.4V2.1.4",

    umov_2 =    "0e013c00G0.0Ev1.1.1|"..
                "0e023c00G0.0Ev1.2.1|"..
                "0e043c00G0.0Ev1.4.1|"..
                "4e083c00G0.1Ev1.8.1",

    umull_3 =   "2f40a000V0.1.4V1.0.2Ev2.2.2|"..
                "2f80a000V0.1.8V1.0.4Ev2.4.2|"..
                "2e20c000V0.1.2V1.0.1V2.0.1|"..
                "2e60c000V0.1.4V1.0.2V2.0.2|"..
                "2ea0c000V0.1.8V1.0.4V2.0.4",

    umull2_3 =  "6f40a000V0.1.4V1.1.2Ev2.2.2|"..
                "6f80a000V0.1.8V1.1.4Ev2.4.2|"..
                "6e20c000V0.1.2V1.1.1V2.1.1|"..
                "6e60c000V0.1.4V1.1.2V2.1.2|"..
                "6ea0c000V0.1.8V1.1.4V2.1.4",

    uqadd_3= "7e200c00N0.1N1.1N2.1|"..
             "7e600c00N0.2N1.2N2.2|"..
             "7ea00c00N0.4N1.4N2.4|"..
             "7ee00c00N0.8N1.8N2.8|"..
             "2e200c00V0.0.1V1.0.1V2.0.1|"..
             "6e200c00V0.1.1V1.1.1V2.1.1|"..
             "2e600c00V0.0.2V1.0.2V2.0.2|"..
             "6e600c00V0.1.2V1.1.2V2.1.2|"..
             "2ea00c00V0.0.4V1.0.4V2.0.4|"..
             "6ea00c00V0.1.4V1.1.4V2.1.4|"..
             "6ee00c00V0.1.8V1.1.8V2.1.8",

    uqrshl_3="7e205c00N0.1N1.1N2.1|"..
             "7e605c00N0.2N1.2N2.2|"..
             "7ea05c00N0.4N1.4N2.4|"..
             "7ee05c00N0.8N1.8N2.8|"..
             "2e205c00V0.0.1V1.0.1V2.0.1|"..
             "6e205c00V0.1.1V1.1.1V2.1.1|"..
             "2e605c00V0.0.2V1.0.2V2.0.2|"..
             "6e605c00V0.1.2V1.1.2V2.1.2|"..
             "2ea05c00V0.0.4V1.0.4V2.0.4|"..
             "6ea05c00V0.1.4V1.1.4V2.1.4|"..
             "6ee05c00V0.1.8V1.1.8V2.1.8",

    uqrshrn_3 = "7f089c00N0.1N1.2I25.3|"..
                "7f109c00N0.2N1.4I25.4|"..
                "7f209c00N0.4N1.8I25.5|"..
                "2f089c00V0.0.1V1.1.2I25.3|"..
                "2f109c00V0.0.2V1.1.4I25.4|"..
                "2f209c00V0.0.4V1.1.8I25.5",
    
    uqrshrn2_3= "6f089c00V0.1.1V1.1.2I25.3|"..
                "6f109c00V0.1.2V1.1.4I25.4|"..
                "6f209c00V0.1.4V1.1.8I25.5",

    uqshl_3 =   "7f087400N0.1N1.1I29.3|"..
                "7f107400N0.2N1.2I29.4|"..
                "7f207400N0.4N1.4I29.5|"..
                "7f407400N0.8N1.8I29.6|"..
                "2f087400V0.0.1V1.0.1I29.3|"..
                "6f087400V0.1.1V1.1.1I29.3|"..
                "2f107400V0.0.2V1.0.2I29.4|"..
                "6f107400V0.1.2V1.1.2I29.4|"..
                "2f207400V0.0.4V1.0.4I29.5|"..
                "6f207400V0.1.4V1.1.4I29.5|"..
                "6f407400V0.1.8V1.1.8I29.6|"..
                "7e204c00N0.1N1.1N2.1|"..
                "7e604c00N0.2N1.2N2.2|"..
                "7ea04c00N0.4N1.4N2.4|"..
                "7ee04c00N0.8N1.8N2.8|"..
                "2e204c00V0.0.1V1.0.1V2.0.1|"..
                "6e204c00V0.1.1V1.1.1V2.1.1|"..
                "2e604c00V0.0.2V1.0.2V2.0.2|"..
                "6e604c00V0.1.2V1.1.2V2.1.2|"..
                "2ea04c00V0.0.4V1.0.4V2.0.4|"..
                "6ea04c00V0.1.4V1.1.4V2.1.4|"..
                "6ee04c00V0.1.8V1.1.8V2.1.8",

    uqshrn_3 =  "7f089400N0.1N1.2I25.3|"..
                "7f109400N0.2N1.4I25.4|"..
                "7f209400N0.4N1.8I25.5|"..
                "2f089400V0.0.1V1.1.2I25.3|"..
                "2f109400V0.0.2V1.1.4I25.4|"..
                "2f209400V0.0.4V1.1.8I25.5",
    
    uqshrn2_3=  "6f089400V0.1.1V1.1.2I25.3|"..
                "6f109400V0.1.2V1.1.4I25.4|"..
                "6f209400V0.1.4V1.1.8I25.5",

    uqsub_3= "7e202c00N0.1N1.1N2.1|"..
             "7e602c00N0.2N1.2N2.2|"..
             "7ea02c00N0.4N1.4N2.4|"..
             "7ee02c00N0.8N1.8N2.8|"..
             "2e202c00V0.0.1V1.0.1V2.0.1|"..
             "6e202c00V0.1.1V1.1.1V2.1.1|"..
             "2e602c00V0.0.2V1.0.2V2.0.2|"..
             "6e602c00V0.1.2V1.1.2V2.1.2|"..
             "2ea02c00V0.0.4V1.0.4V2.0.4|"..
             "6ea02c00V0.1.4V1.1.4V2.1.4|"..
             "6ee02c00V0.1.8V1.1.8V2.1.8",

    uqxtn_2 =   "7e214800N0.1N1.2|"..
                "7e614800N0.2N1.4|"..
                "7ea14800N0.4N1.8|"..
                "2e214800V0.0.1V1.1.2|"..
                "2e614800V0.0.2V1.1.4|"..
                "2ea14800V0.0.4V1.1.8",

    uqxtn2_2 =  "6e214800V0.1.1V1.1.2|"..
                "6e614800V0.1.2V1.1.4|"..
                "6ea14800V0.1.4V1.1.8",

    urecpe_2 =  "0ea1c800V0.0.4V1.0.4|4ea1c800V0.1.4V1.1.4",

    urhadd_3 =  "2e201400V0.0.1V1.0.1V2.0.1|"..
                "6e201400V0.1.1V1.1.1V2.1.1|"..
                "2e601400V0.0.2V1.0.2V2.0.2|"..
                "6e601400V0.1.2V1.1.2V2.1.2|"..
                "2ea01400V0.0.4V1.0.4V2.0.4|"..
                "6ea01400V0.1.4V1.1.4V2.1.4",

    urshl_3 ="7ee05400N0.8N1.8N2.8|"..
             "2e205400V0.0.1V1.0.1V2.0.1|"..
             "6e205400V0.1.1V1.1.1V2.1.1|"..
             "2e605400V0.0.2V1.0.2V2.0.2|"..
             "6e605400V0.1.2V1.1.2V2.1.2|"..
             "2ea05400V0.0.4V1.0.4V2.0.4|"..
             "6ea05400V0.1.4V1.1.4V2.1.4|"..
             "6ee05400V0.1.8V1.1.8V2.1.8",

    urshr_3 ="7f402400N0.8N1.8I25.6|"..
             "2f082400V0.0.1V1.0.1I25.3|"..
             "6f082400V0.1.1V1.1.1I25.3|"..
             "2f102400V0.0.2V1.0.2I25.4|"..
             "6f102400V0.1.2V1.1.2I25.4|"..
             "2f202400V0.0.4V1.0.4I25.5|"..
             "6f202400V0.1.4V1.1.4I25.5|"..
             "6f402400V0.1.8V1.1.8I25.6",

    ursqrte_2 = "2ea1c800V0.0.4V1.0.4|6ea1c800V0.1.4V1.1.4",

    ursra_3 ="7f403400N0.8N1.8I25.6|"..
             "2f083400V0.0.1V1.0.1I25.3|"..
             "6f083400V0.1.1V1.1.1I25.3|"..
             "2f103400V0.0.2V1.0.2I25.4|"..
             "6f103400V0.1.2V1.1.2I25.4|"..
             "2f203400V0.0.4V1.0.4I25.5|"..
             "6f203400V0.1.4V1.1.4I25.5|"..
             "6f403400V0.1.8V1.1.8I25.6",

    ushl_3 = "7ee04400N0.8N1.8N2.8|"..
             "2e204400V0.0.1V1.0.1V2.0.1|"..
             "6e204400V0.1.1V1.1.1V2.1.1|"..
             "2e604400V0.0.2V1.0.2V2.0.2|"..
             "6e604400V0.1.2V1.1.2V2.1.2|"..
             "2ea04400V0.0.4V1.0.4V2.0.4|"..
             "6ea04400V0.1.4V1.1.4V2.1.4|"..
             "6ee04400V0.1.8V1.1.8V2.1.8",

    ushll_3 ="2f08a400V0.1.2V1.0.1I29.3|"..
             "2f10a400V0.1.4V1.0.2I29.4|"..
             "2f20a400V0.1.8V1.0.4I29.5",

    ushll2_3 ="6f08a400V0.1.2V1.1.1I29.3|"..
              "6f10a400V0.1.4V1.1.2I29.4|"..
              "6f20a400V0.1.8V1.1.4I29.5",

    ushr_3 = "7f400400N0.8N1.8I25.6|"..
             "2f080400V0.0.1V1.0.1I25.3|"..
             "6f080400V0.1.1V1.1.1I25.3|"..
             "2f100400V0.0.2V1.0.2I25.4|"..
             "6f100400V0.1.2V1.1.2I25.4|"..
             "2f200400V0.0.4V1.0.4I25.5|"..
             "6f200400V0.1.4V1.1.4I25.5|"..
             "6f400400V0.1.8V1.1.8I25.6",

    usqadd_3="7e203800N0.1N1.1|"..
             "7e603800N0.2N1.2|"..
             "7ea03800N0.4N1.4|"..
             "7ee03800N0.8N1.8|"..
             "2e203800V0.0.1V1.0.1|"..
             "6e203800V0.1.1V1.1.1|"..
             "2e603800V0.0.2V1.0.2|"..
             "6e603800V0.1.2V1.1.2|"..
             "2ea03800V0.0.4V1.0.4|"..
             "6ea03800V0.1.4V1.1.4|"..
             "6ee03800V0.1.8V1.1.8",

    usra_3 = "7f401400N0.8N1.8I25.6|"..
             "2f081400V0.0.1V1.0.1I25.3|"..
             "6f081400V0.1.1V1.1.1I25.3|"..
             "2f101400V0.0.2V1.0.2I25.4|"..
             "6f101400V0.1.2V1.1.2I25.4|"..
             "2f201400V0.0.4V1.0.4I25.5|"..
             "6f201400V0.1.4V1.1.4I25.5|"..
             "6f401400V0.1.8V1.1.8I25.6",

    usubl_3 =   "2e202000V0.1.2V1.0.1V2.0.1|"..
                "2e602000V0.1.4V1.0.2V2.0.2|"..
                "2ea02000V0.1.8V1.0.4V2.0.4",

    usubl2_3 =  "6e202000V0.1.2V1.1.1V2.1.1|"..
                "6e602000V0.1.4V1.1.2V2.1.2|"..
                "6ea02000V0.1.8V1.1.4V2.1.4",

    usubw_3 =   "2e203000V0.1.2V1.1.2V2.0.1|"..
                "2e603000V0.1.4V1.1.4V2.0.2|"..
                "2ea03000V0.1.8V1.1.8V2.0.4",

    usubw2_3 =  "6e203000V0.1.2V1.1.2V2.1.1|"..
                "6e603000V0.1.4V1.1.4V2.1.2|"..
                "6ea03000V0.1.8V1.1.8V2.1.4",

    uxtl_2 =    "2f08a400V0.1.2V1.0.1|"..
                "2f10a400V0.1.4V1.0.2|"..
                "2f20a400V0.1.8V1.0.4",
    
    uxtl2_2 =   "6f08a400V0.1.2V1.1.1|"..
                "6f10a400V0.1.4V1.1.2|"..
                "6f20a400V0.1.8V1.1.4",

    uzp1_3 =    "0e001800V0.0.1V1.0.1V2.0.1|"..
                "4e001800V0.1.1V1.1.1V2.1.1|"..
                "0e401800V0.0.2V1.0.2V2.0.2|"..
                "4e401800V0.1.2V1.1.2V2.1.2|"..
                "0e801800V0.0.4V1.0.4V2.0.4|"..
                "4e801800V0.1.4V1.1.4V2.1.4|"..
                "4ec01800V0.1.8V1.1.8V2.1.8",

    uzp2_3 =    "0e005800V0.0.1V1.0.1V2.0.1|"..
                "4e005800V0.1.1V1.1.1V2.1.1|"..
                "0e405800V0.0.2V1.0.2V2.0.2|"..
                "4e405800V0.1.2V1.1.2V2.1.2|"..
                "0e805800V0.0.4V1.0.4V2.0.4|"..
                "4e805800V0.1.4V1.1.4V2.1.4|"..
                "4ec05800V0.1.8V1.1.8V2.1.8",

    xtn_2 = "0e212800V0.0.1V1.1.2|"..
            "0e612800V0.0.2V1.1.4|"..
            "0ea12800V0.0.4V1.1.8",

    xtn2_2 ="4e212800V0.1.1V1.1.2|"..
            "4e612800V0.1.2V1.1.4|"..
            "4ea12800V0.1.4V1.1.8",

    zip1_3 =    "0e003800V0.0.1V1.0.1V2.0.1|"..
                "4e003800V0.1.1V1.1.1V2.1.1|"..
                "0e403800V0.0.2V1.0.2V2.0.2|"..
                "4e403800V0.1.2V1.1.2V2.1.2|"..
                "0e803800V0.0.4V1.0.4V2.0.4|"..
                "4e803800V0.1.4V1.1.4V2.1.4|"..
                "4ec03800V0.1.8V1.1.8V2.1.8",

    zip2_3 =    "0e007800V0.0.1V1.0.1V2.0.1|"..
                "4e007800V0.1.1V1.1.1V2.1.1|"..
                "0e407800V0.0.2V1.0.2V2.0.2|"..
                "4e407800V0.1.2V1.1.2V2.1.2|"..
                "0e807800V0.0.4V1.0.4V2.0.4|"..
                "4e807800V0.1.4V1.1.4V2.1.4|"..
                "4ec07800V0.1.8V1.1.8V2.1.8"

}

-- Merge map_vop into map_op
do
    for k,v in pairs(map_vop) do
        local v1 = map_op[k]
        if v1 then
            map_op[k] = v1 .. "|" .. v
        else
            map_op[k] = v
        end
    end
end

------------------------------------------------------------------------------


local function parse_gpr(expr, bit64)
    local alias, explicitreg = match(expr, "^([%w_]+)%s*:%s*(.*)$")
    local tp = map_type[alias or expr]
    local reg = expr

    if tp then
        reg = explicitreg or tp.reg
        if not reg then
            werror("type `"..(alias or expr).."' needs a register override")
        end
    end

    local regex = bit64 and (bit64 == 0 and "^(wsp)$" or "^(sp)$") or "^(w?sp)$"

    local sf = match(reg, regex)
    if sf then return sf == "sp" and 1 or 0, 31, tp end

    regex = bit64 and (bit64 == 0 and "^(w)zr$" or "^(x)zr$") or "^([wx])zr$"
    local sf = match(reg, regex)
    if sf then return sf=="x" and 1 or 0, 31, tp end

    regex = bit64 and (bit64 == 0 and "w" or "x") or "[wx]"
    local sf, r = match(reg, "^("..regex..")([123]?[0-9])$")
    if sf and r then
        sf = sf == "x" and 1 or 0
        r = tonumber(r)
        if r <= 30 then
            return sf, r, tp
        end
    end
    werror("invalid register name `"..expr.."'")
end

local vector_register_kind_map = {
    [1] = "b",
    [2] = "h",
    [4] = "s",
    [8] = "d",
    [16]= "q"
}

local vector_register_index_bits_map = {
    [1] = 4,
    [2] = 3,
    [4] = 2,
    [8] = 1
}

local function parse_scr(param, kind)
    local k = vector_register_kind_map[kind]
    if not k then werror("invalid scalar SIMD&FP register in template") end
    local alias, explicitreg = match(kind, "^([%w_]+)%s*:%s*("..k.."%d+)$")
    local tp = map_type[alias or expr]
    local vr = param

    if tp then vr = explicitreg or tp.reg end
    if vr then
        local n = match(vr, "^"..k.."(%d+)$")
        n = tonumber(n)
        if n and n < 32 then return n end
    end

    werror("invalid scalar register `"..param.."'")
end

-- parse vector register element
local function parse_ve(param, ekind, indextype)
    local k = vector_register_kind_map[ekind]
    local bits = vector_register_index_bits_map[ekind]
    if not k or not bits then werror("invalid vector register in template") end
    local vr, index = match(param, "^v(%d+)%."..k.."%s*%[%s*(%S+)%s*%]$")
    local nvr, nindex = tonumber(vr), tonumber(index)

    if vr and index and nvr and nvr < 32 then
        if not nindex then
            if indextype == 1 then -- imm5[16:20]
                wactionl("IMM", bits*32+(21-bits), index)
            elseif indextype == 2 and bits <= 3 then --immhlm
                wactionl("IMMHLM", bits, index)
            elseif indextype == 3 then -- imm4[11:14]
                wactionl("IMM", bits*32+(15-bits), index)
            else
                werror("invalid index type in template")
            end
            return nvr, 0
        elseif nindex >= 0 and nindex < shl(1, bits) then
            local imm
            if indextype == 1 then -- imm5[16:20]
                if shr(nindex, bits) == 0 then
                    imm = shl(nindex, 21-bits)
                end
            elseif indextype == 2 then --h,l,m at [11],[21],[20]
                if bits == 1 then
                    imm = shl(nindex, 11)
                elseif bits == 2 then
                    imm = shl(shr(nindex,1), 11) + shl(band(nindex,1),21)
                elseif bits == 3 then
                    imm = shl(shr(nindex,2), 11)
                    imm = shl(shr(nindex,1), 21) + imm
                    imm = shl(band(nindex,1),20) + imm
                else
                    werror("invalid element type in template")
                end
            elseif indextype == 3 then --imm4[11:14]
                if shr(nindex, bits) == 0 then
                    imm = shl(nindex, 15-bits)
                end
            elseif indextype == 4 then --vx.d[1]
                if nindex == 1 and k == "d" then
                    imm = 0
                end
            end
            if imm then return nvr, imm end
        end
    end

    werror("invalid vector register element `"..param.."'")
end

local function rounddiff(n2,n1) 
    if n2<n1 then return n2+32-n1
    else return n2-n1
    end
end

-- parse vector register list element
local function parse_vle(param, llen, ekind)
    local k = vector_register_kind_map[ekind]
    local bits = vector_register_index_bits_map[ekind]
    if not k or not bits then werror("invalid vector register in template") end

    local rb, re, i1 = match(param, "^{%s*v(%d+)%."..k.."%-v(%d+)%."..k.."%s*}%s*%[%s*(%S+)%s*%]$")
    local nrb, nre, ni1 = tonumber(rb), tonumber(re), tonumber(i1)
    local regex = "^{%s*"
    for i=1,llen-1 do
        regex = regex .. "v(%d+)%."..k.."%s*,%s*"
    end
    regex = regex .. "v(%d+)%."..k.."%s*}%s*%[%s*(%S+)%s*%]$"
    local r1,r2,r3,r4,i2 = match(param, regex)
    local nr1,nr2,nr3,nr4,ni2=tonumber(r1),tonumber(r2),tonumber(r3),tonumber(r4),tonumber(i2)
    
    local vr, index, nindex
    if llen == 1 then
        if r1 and r2 ~= "" and nr1 then
            vr, index, nindex = nr1, r2, nr2
        end
    elseif llen == 2 then
        if nrb and nre and rounddiff(nre,nrb)==1 and i1 ~= "" then
            vr, index, nindex = nrb, i1, ni1
        elseif nr1 and nr2 and rounddiff(nr2,nr1)==1 and r3 ~= "" then
            vr, index, nindex = nr1, r3, nr3
        end
    elseif llen == 3 then
        if nrb and nre and rounddiff(nre,nrb)==2 and i1 ~= "" then
            vr, index, nindex = nrb, i1, ni1
        elseif nr1 and nr2 and nr3 and
               rounddiff(nr2,nr1)==1 and rounddiff(nr3,nr2)==1 and r4 ~= "" then
            vr, index, nindex = nr1, r4, nr4
        end
    elseif llen == 4 then
        if nrb and nre and rounddiff(nre,nrb)==3 and i1 ~= "" then
            vr, index, nindex = nrb, i1, ni1
        elseif nr1 and nr2 and nr3 and nr4 and
               rounddiff(nr2,nr1)==1 and rounddiff(nr3,nr2)==1 and
               rounddiff(nr4,nr3)==1 and i2 ~= "" then
            vr, index, nindex = nr1, i2, ni2
        end
    end

    if vr and index and vr < 32 then
        if not nindex then
            wactionl("IMMQSS", bits, index)
            return vr, 0
        elseif nindex >= 0 and shr(nindex, bits) == 0 then
            local imm = 0
            if bits == 1 then
                imm = shl(nindex, 30)
            elseif bits == 2 then
                imm = shl(shr(nindex, 1), 30) + shl(band(nindex,1), 12)
            elseif bits == 3 then
                imm = shl(shr(nindex, 2), 30) + shl(band(nindex,3), 11)
            elseif bits == 4 then
                imm = shl(shr(nindex,3),  30) + shl(band(nindex,7), 10)
            end
            return vr, imm
        end
    end
    
    werror("invalid vector register list element `"..param.."'")
end

-- parse vector register list
local function parse_vl(param, llen, ekind, q)
    local k = vector_register_kind_map[ekind]
    if not k then werror("invalid vector register in template") end
    local count = (q==1 and 16 or 8)/ekind
    local ck = "" .. count .. k

    local rb, re = match(param, "^{%s*v(%d+)%."..ck.."%-v(%d+)%."..ck.."%s*}$")
    local nrb, nre = tonumber(rb), tonumber(re)
    local regex = "^{%s*"
    for i=1,llen-1 do
        regex = regex .. "v(%d+)%."..ck.."%s*,%s*"
    end
    regex = regex .. "v(%d+)%."..ck.."%s*}$"
    local r1,r2,r3,r4 = match(param, regex)
    local nr1,nr2,nr3,nr4 = tonumber(r1),tonumber(r2),tonumber(r3),tonumber(r4)
    local vr
    if llen == 1 then
        if nr1 and nr1 < 32 then vr = nr1 end
    elseif llen == 2 then
        if nrb and nre and rounddiff(nre,nrb)==1 then
            vr = nrb
        elseif nr1 and nr2 and rounddiff(nr2,nr1)==1 then
            vr = nr1
        end
    elseif llen == 3 then
        if nrb and nre and rounddiff(nre,nrb)==2 then
            vr = nrb
        elseif nr1 and nr2 and nr3 and
               rounddiff(nr2,nr1)==1 and
               rounddiff(nr3,nr2)==1 then
            vr = nr1
        end
    elseif llen == 4 then
        if nrb and nre and rounddiff(nre,nrb)==3 then
            vr = nrb
        elseif nr1 and nr2 and nr3 and nr4 and
               rounddiff(nr2,nr1)==1 and
               rounddiff(nr3,nr2)==1 and
               rounddiff(nr4,nr3)==1 then
            vr = nr1
        end
    end
    if vr and vr<32 then return vr end
    werror("invalid vector register `"..param.."'")
end

-- parse vector register
local function parse_vr(param, ekind, q)
    local k = vector_register_kind_map[ekind]
    if not k then werror("invalid vector register in template") end
    local alias, explicitreg = match(param, "^([%w_]+)%s*:%s*(v%d+%.%d+"..k..")$")
    local tp = map_type[alias or expr]
    local vr = param

    if tp then vr = explicitreg or tp.reg end
    if vr then
        local n, n1 = match(vr, "^v(%d+)%.(%d+)"..k.."$")
        n = tonumber(n)
        n1 = tonumber(n1)
        if n and n1 and n < 32 and
           ekind*n1 == shl(8, q) then return n end
    end

    werror("invalid vector register `"..param.."'")
end

local function parse_control(param)
    local control = match(param, "^[cC](1?[0-9])$")
    control = tonumber(control)
    if not control or control < 0 or control > 15 then
        werror("invalid control value `"..param.."'")
    end
    return control
end

local extension_map = {
    uxtb = 0,
    uxth = 1,
    uxtw = 2,
    uxtx = 3,
    sxtb = 4,
    sxth = 5,
    sxtw = 6,
    sxtx = 7
}

local shift_map = {
    lsl = 0,
    lsr = 1,
    asr = 2,
    ror = 3
}

-- parse extension or shifted register
local function parse_ext_or_sr(op, params, n, nparams)
    local expr = params[n]
    local sf, rm = parse_gpr(expr)
    op = op + shl(rm, 16)
    if n == nparams then return op end
    expr = parmas[n+1]
    local bit64 = shr(band(op, 0x80000000), 31) == 1
    local hassp = band(op, 0x1f) == 0x1f or band(op, 0x1f0000) == 0x1f0000
    local extend, amount = match(expr, "^(%a*)%s*(.*)$")
    local nextend = extension_map[extend]
    if not nextend then
        if hassp and extend == 'lsl' then
            nextend = bit64 and 3 or 2
        end
    end
    local shift
    if not nextend then
        shift = shift_map[extend]
    end
    if not nextend and not shift then werror("invalid extension/shift `"..extend.."'") end
    if shift and hassp then
        werror("shifted register instruction can't work with sp")
    end

    if shift == 3 then
        werror("ror shift is reserved for this instruction")
    end

    local namount = 0
    local amountnum
    if amount and amount ~= "" then
        amountnum = match(amount, "^#(.*)$")
        if amountnum then
            namount = tonumber(amountnum)
        else
            namount = -1
        end
    end
    if nextend then
        if not namount then
            namount = 0
            wactionl("IMM", 3*32 + 10, amountnum)
        end
        if namount >= 0 and namount <= 4 then
            op = op + 0x200000 + shl(nextend, 13) + shl(namount, 10)
            return op
        end
    end
    if shift then
        if not namount then
            namount = 0
            wactionl("IMM", 6*32+10, amountnum)
        end
        local max = bit64 and 63 or 31
        if namount >= 0 and namount <= max then
            op = op + shl(shift, 22) + shl(namount, 10)
            return op
        end
    end
    werror("invalid shift amount `"..amount.."'")
end

local function parse_shifted_imm12(params, n, nparams)
    local nshift = 0
    if n < nparams then
        local shift = match(params[n+1], "lsl%s+#([012]+)$")
        if shift == "12" then
            nshift = 1
        elseif shift ~= "0" then
            werror("invalid shift `"..params[n+1].."'")
        end
    end

    local result = shl(nshift, 22)

    local param = params[n]
    local imm = match(param, "^#%s*(.*)$")
    if not imm then werror("expect immediate operand started with #") end
    local nimm = tonumber(imm)
    if nimm then
        if nimm >=0 and nimm <= 4095 then
            return result + shl(nimm, 10)
        end
        werror("immediate out of range: `"..param.."'")
    else
        wactionl("IMM", 12*32 + 10, imm)
        return result
    end
end

local function parse_sr(op, params, n, nparams)
    local expr = params[n]
    local is64 = shr(op, 31) == 1
    local sf, rm = parse_gpr(expr)

    if is64 and sf == 0 then
        werror("64 bit register should be used")
    end

    local delta = shl(rm, 16)
    if n == nparams then return delta end
    expr = parmas[n+1]

    local shift, amount = match(expr, "^(%a*)%s+#(.*)$")
    if shift and amount then
        local nshift = shift_map[shift]
        if not shift then werror("invalid shift `"..shift.."'") end
        delta = delta + shl(nshift, 22)
        local namount = tonumber(amount)

        if not namount then
            wactionl("IMM", 6*32+10, amount)
            return delta
        else 
            local max = is64 and 63 or 31
            if namount >= 0 and namount <= max then
                delta = delta + shl(namount, 10)
                return delta
            end
        end
    end
    werror("invalid shift/amount `"..expr.."'")
end

local function parse_imm(imm, bits, shift, scale, signed)
    imm = match(imm, "^#(.*)$")
    if not imm then werror("expected immediate operand") end
    local n = tonumber(imm)
    if n then
        local m = sar(n, scale)
        if shl(m, scale) == n then
            if signed then
                local s = sar(m, bits-1)
                if s == 0 then return shl(m, shift)
                elseif s == -1 then return shl(m + shl(1, bits), shift) end
            else
                if sar(m, bits) == 0 then return shl(m, shift) end
            end
        end
        werror("out of range immediate `"..imm.."'")
    else
        wactionl("IMM", (signed and 32768 or 0)+scale*1024+bits*32+shift, imm)
        return 0
    end
end

local function parse_immnsr(param, is64)
    local expr = match(param, "^#(.*)$")
    if not expr then werror("invalid number `"..param.."'") end
    -- all immediate, including the real immediate,
    -- should be handled by C code, because the 
    -- immediate may be 64-bit integer, which can
    -- not be stored in double without lost of accuracy.
    wactionl("IMMNSR", is64 and 1 or 0, expr)
    return 0
end

local function parse_immmov(param, is64)
    local expr = match(param, "^#(.*)$")
    if not expr then werror("invalid number `"..param.."'") end
    -- all immediate, including the real immediate,
    -- should be handled by C code, because the 
    -- immediate may be 64-bit integer, which can
    -- not be stored in double without lost of accuracy.
    wactionl("IMMMOV", is64 and 1 or 0, expr)
    return 0
end

local function parse_immtbn(param, bit64)
    imm = match(imm, "^#(.*)$")
    if not imm then werror("expected immediate operand") end
    local n = tonumber(imm)
    if n then
        if (bit64 and n >= 32 and n <= 63) or
           (not bit64 and n>=0 and n<=31)  then
            return shl(band(n,31), 19)
        end
        werror("out of range immediate `"..imm.."'")
    else
        wactionl("IMMTBN", bit64 and 1 or 0, imm)
        return 0
    end
end

local function parse_imma2h(param)
    local imm = match(param, "^#(.*)$")
    if imm then
        local nimm = tonumber(imm)
        if not nimm then
            wactionl("IMMA2H", 0, imm)
            return 0
        elseif nimm >= 0 and nimm <= 255 then
            return shl(shr(nimm, 5),16) + shl(band(nimm, 0x1f), 5)
        end
    end
    werror("invalid number `".. param .. "'")
end

local function parse_imma2h64(param)
    local imm = match(param, "^#(.*)$")
    if imm then
        wactionl("IMMA2H64", 0, imm)
        return 0
    end
    werror("invalid number `".. param .. "'")
end

local function parse_imma2hfp(param)
    local imm = match(param, "^#(.*)$")
    if imm then
        wactiond("IMMA2HFP", 0, imm)
        return 0
    end
    werror("invalid number `".. param .. "'")
end

local function parse_imm8fp(param)
    local imm = match(param, "^#(.*)$")
    if imm then
        wactiond("IMM8FP", 0, imm)
        return 0
    end
    werror("invalid number `".. param .. "'")
end

local function parse_immhb(param, bits)
    if bits >= 3 and bits <= 6 then
        local max = shl(1, bits)
        local imm = match(param, "^#(.*)$")
        if imm then
            local n = tonumber(imm)
            if not n then
                wactionl("IMMHB", bits, imm)
                return 0
            elseif n>=1 and n<=max then
                return shl(max-n, 16)
            end
        end
    end
    werror("invalid number `".. param .. "'")
end

local function parse_immhb1(param, bits)
    if bits >= 3 and bits <= 6 then
        local max = shl(1, bits) - 1
        local imm = match(param, "^#(.*)$")
        if imm then
            local n = tonumber(imm)
            if not n then
                wactionl("IMM", bits*32+16, imm)
                return 0
            elseif n>=0 and n<=max then
                return shl(n, 16)
            end
        end
    end
    werror("invalid number `".. param .. "'")
end

local function parse_immscale(param, q)
    local max = q == 1 and 64 or 32
    local imm = match(param, "^#(.*)$")
    if imm then
        local n = tonumber(imm)
        if not n then
            wactionl("IMMSCALE", q, imm)
            return 0
        elseif n>=1 and n<=max then
            return shl(max-n, 10)
        end
    end
    werror("invalid number `".. param .. "'")
end

local function parse_immlsl(param, size)
    if size == 2 then
        if param == "#0" then return 0
        elseif param == "#8" then return 0x2000
        end
    elseif size == 4 then
        if param == "#0" then return 0
        elseif param == "#8" then return 0x2000
        elseif param == "#16" then return 0x4000
        elseif param == "#24" then return 0x6000
        end
    elseif size == 0 then
        if param == "#0" then return 0 end
    else
        werror("invalid template")
    end
    werror("invalid lsl amount `"..param.."'")
end

local function parse_immmsl(param)
    if param == "#8" then return 0
    elseif param == "#16" then return 0x1000
    end
    werror("invalid msl amount `"..param.."'")    
end

local function parse_immlsb(imm, is64)
    imm = match(imm, "^#(.*)$")
    if not imm then werror("expected immediate operand") end
    local n = tonumber(imm)
    if n then
        local max = is64 and 63 or 31
        if n >= 0 and n <= max then
            local m = band(-n, max)
            return shl(m, 16)
        end
        werror("out of range immediate `"..imm.."'")
    else
        wactionl("IMMLSB", is64 and 1 or 0, imm)
        return 0
    end
end

local function parse_immwidth1(op, imm, bit64)
    imm = match(imm, "^#(.*)$")
    if not imm then werror("expected immediate operand") end
    local immr = band(shr(op, 16), 0x3f)
    local n = tonumber(imm)
    if n then
        local max = bit64 and 64 or 32
        local m = n - 1 
        if m >= 0 and m < immr then return shl(m, 10) end
        werror("out of range immediate `"..imm.."'")
    else
        wactionl("IMMWIDTH1", bit64 and 1 or 0, imm)
        return 0
    end
end

local function parse_immwidth2(op, param, bit64)
    imm = match(imm, "^#(.*)$")
    if not imm then werror("expected immediate operand") end
    local immr = band(shr(op, 16), 0x3f)
    local n = tonumber(imm)
    if n and immr > 0 then
        local max = bit64 and 64 or 32
        local m = immr + n - 1 
        if m>=immr and m<max then return shl(m, 10) end
        werror("out of range immediate `"..imm.."'")
    else
        wactionl("IMMWIDTH2", bit64 and 1 or 0, imm)
        return 0
    end
end

local function parse_imm_shift(param, bit64)
    imm = match(imm, "^#(.*)$")
    if not imm then werror("expected immediate operand") end
    local n = tonumber(imm)
    if n then
        local num = bit64 and 63 or 31
        if n >= 0 and n <= num then
            local immr, imms = band(-n, num), band(num-n, 63)
            return shl(immr, 16) + shl(imms, 10)
        end
    else
        wactionl("IMMSHIFT", bit64 and 1 or 0, imm)
        return 0
    end
    werror("invalid number `"..param.."'")
end

local function parse_imm_move_lsl(param, bit64)
    local shift = match(param, "^lsl%s+#(%d+)$")
    local num = tonumber(shift)
    if bit64 and (num == 0 or num == 16 or num == 32 or num == 48) then
        return shl(shr(num,4), 21)
    elseif not bit64 and (num == 0 or num == 16) then
        return shl(shr(num,4), 21)
    end
    werror("invalid shift for mov instruction: `"..param.."'")
end

local function parse_label(label, def)
    local prefix = sub(label, 1, 2)
    -- =>label (pc label reference)
    if prefix == "=>" then
        return "PC", 0, sub(label, 3)
    end
    -- ->name (global label reference)
    if prefix == "->" then
        return "LG", map_global[sub(label, 3)]
    end
    if def then
        -- [1-9] (local label definition)
        if match(label, "^[1-9]$") then
            return "LG", 10+tonumber(label)
        end
    else
        -- [<>][1-9] (local label reference)
        local dir, lnum = match(label, "^([<>])([1-9])$")
        if dir then -- Fwd: 1-9, Bkwd: 11-19.
            return "LG", lnum + (dir == ">" and 0 or 10)
        end
        -- extern label (extern label reference)
        local extname = match(label, "^extern%s+(%S+)$")
        if extname then
            return "EXT", map_extern[extname]
        end
    end
    werror("bad label `"..label.."'")
end

local address_extension_map = {
    uxtw = 2,
    lsl = 3,
    sxtw = 6,
    sxtx = 7
}

local function parse_caddress(param, bits, shift, scale, signed)
    local reg, tailr = match(param, "^([%w_:]+)%s*(.*)$")
    if reg and tailr ~= "" then
        local sf, gpr, tp = parse_gpr(reg, 1)
        if tp then
            scale = scale and scale or 0
            wactionl("IMM", (signed and 32768 or 0)+scale*1024+bits*32+shift, format(tp.ctypefmt, tailr))
            return gpr, 0
        end
    end
    werror("invalid address `"..param.."'")
end

local function parse_address0(param)
    local base = match(param, "^%[%s*(%w+)%s*%]$")
    if not base then
       base = match(param, "^%[%s*(%w+)%s*,%s*#0%s*]$")
    end
    if not base then werror("invalid address specification `"..param.."'") end
    local sf, gpr = parse_gpr(base, 1)
    return gpr
end

local function parse_address1(param, scale)
    local base, imm
    base, imm = match(param, "^%[%s*(%w+)%s*,?%s*(%S*)%s*%]$")
    if not base then
        return parse_caddress(param, 7, 15, scale, true)
    else
        local sf, gpr = parse_gpr(base, 1)
        scale = scale and scale or 0
        imm = imm == "" and 0 or parse_imm(imm, 7, 15, scale, true)
        return gpr, imm
    end
end

local function parse_address2(param)
    local base = match(param, "^%[%s*(%w+)%s*%]$")
    local sf,gpr = parse_gpr(base, 1)
    return gpr
end

local function parse_address3(param, scale)
    local base, imm
    base, imm = match(param, "^%[%s*(%w+)%s*,?%s*(%S*)%s*%]!$")
    local sf, gpr = parse_gpr(base, 1)
    scale = scale and scale or 0
    imm = imm == "" and 0 or parse_imm(imm, 7, 15, scale, true)
    return gpr, imm
end

local function parse_address4(param, scale)
    local base, imm
    base, imm = match(param, "^%[%s*(%w+)%s*,?%s*(%S*)%s*%]!$")
    local sf, gpr = parse_gpr(base, 1)
    scale = scale and scale or 0
    imm = imm == "" and 0 or parse_imm(imm, 9, 12, scale, true)
    return gpr, imm
end

local function parse_address5(param, scale)
    local base, imm
    base, imm = match(param, "^%[%s*(%w+)%s*,?%s*(%S*)%s*%]$")
    if not base then
        local reg, tailr = match(param, "^([%w_:]+)%s*(.*)$")
        if reg and tailr ~= "" then
            local sf, gpr, tp = parse_gpr(reg, 1)
            if tp then
                wactionl("IMMADDROFF", scale*1024, format(tp.ctypefmt, tailr))
                return gpr, 0
            end
        end
        werror("invalid immediate operand")
    else
        local sf, gpr = parse_gpr(base, 1)
        scale = scale and scale or 0
        if imm ~= "" then
            imm = match(imm, "^#(.*)$")
            if not imm then werror("expect immediate operand") end
            wactionl("IMMADDROFF", scale*1024, imm)
        end
        return gpr, 0
    end
end

local function parse_address6(param, bigamount)
    local base, index, extend, amount = match(param, "^%[%s*(%S+)%s*,%s*(%S+)%s*,?%s*(%S*)%s*(%S*)%]$")
    if base and index and extend and amount then
        local sf, rn = parse_gpr(base, 1)
        local sf, rm = parse_gpr(index)
        local nextend, namount
        if extend == "" then
            nextend = 3
        else
            nextend = address_extension_map[extend]
        end
        if amount == "" then
            namount = -1
        else
            namount = tonumber(match(amount, "^#([0-4])$"))
        end
        if nextend and namount then
            local s
            local littleamount = bigamount == 0 and -1 or 0
            if namount == littleabount then
                s = 0
            elseif namount == bigamount then
                s = 1
            end
            if s then
                 return shl(rn, 5) + shl(rm, 16) + shl(nextend, 13) + shl(s, 12)
            end
        end
    end
    werror("invalid address `"..param.."'")
end

local function parse_address7(param, scale)
    local base, imm
    base, imm = match(param, "^%[%s*(%w+)%s*,?%s*(%S*)%s*%]$")
    if not base then
        return parse_caddress(param, 9, 12, scale, true)
    else
        local sf, gpr = parse_gpr(base, 1)
        scale = scale and scale or 0
        imm = imm == "" and 0 or parse_imm(imm, 9, 12, scale, true)
        return gpr, imm
    end
end

------------------------------------------------------------------------------
-- address translate instruction type
local sys_at = {
    s1e1r = 0x00007800,
    s1e2r = 0x00047800,
    s1e3r = 0x00067800,
    s1e1w = 0x00007820,
    s1e2w = 0x00047820,
    s1e3w = 0x00067820,
    s1e0r = 0x00007840,
    s1e0w = 0x00007860,
    s12e1r = 0x00047880,
    s12e1w = 0x000478a0,
    s12e0r = 0x000478c0,
    s12e0w = 0x000478e0
}

-- data cache instruction type
local sys_dc = {
    zva = 0x00037420,
    ivac = 0x00007620,
    isw = 0x00007640,
    cvac = 0x00037a20,
    csw = 0x00007a40,
    cvau = 0x00037b20,
    civac = 0x00037e20,
    cisw = 0x00007e40
}

-- instruction cache instruction type
local sys_ic = {
    ialluis = 0x00007100,
    iallu = 0x00007500,
    ivau = 0x00037520
}

-- tlb instruction type
local sys_tlb = {
    ipas2e1is = 0x00048020,
    ipas2le1is = 0x000480a0,
    vmalle1is = 0x00008300,
    alle2is = 0x00048300,
    alle3is = 0x00068300,
    vae1is = 0x00008320,
    vae2is = 0x00048320,
    vae3is = 0x00068320,
    aside1is = 0x00008340,
    vaae1is = 0x00008360,
    alle1is = 0x00048380,
    vale1is = 0x000083a0,
    vale2is = 0x000483a0,
    vale3is = 0x000683a0,
    vmalls12e1is = 0x000483c0,
    vaale1is = 0x000083e0,
    ipas2e1 = 0x00048420,
    ipas2le1 = 0x000484a0,
    vmalle1 = 0x00008700,
    alle2 = 0x00048700,
    alle3 = 0x00068700,
    vae1 = 0x00008720,
    vae2 = 0x00048720,
    vae3 = 0x00068720,
    aside1 = 0x00008740,
    vaae1 = 0x00008760,
    alle1 = 0x00048780,
    vale1 = 0x000087a0,
    vale2 = 0x000487a0,
    vale3 = 0x000687a0,
    vmalls12e1 = 0x000487c0,
    vaale1 = 0x000087e0
}

-- Barrier option names
local barrier_options = {
    oshld = 1,
    oshst = 2,
    osh   = 3,
    nshld = 5,
    nshst = 6,
    nsh   = 7,
    ishld = 9,
    ishst = 10,
    ish   = 11,
    ld    = 13,
    st    = 14,
    sy    = 15
}

local system_register_map = {
    -- General system control registers
    actlr_el1        = 0x00181020,
    actlr_el2        = 0x001c1020,
    actlr_el3        = 0x001e1020,
    afsr0_el1        = 0x00185100,
    afsr0_el2        = 0x001c5100,
    afsr0_el3        = 0x001e5100,
    afsr1_el1        = 0x00185120,
    afsr1_el2        = 0x001c5120,
    afsr1_el3        = 0x001e5120,
    aidr_el1         = 0x001900e0,
    amair_el1        = 0x0018a300,
    amair_el2        = 0x001ca300,
    amair_el3        = 0x001ea300,
    ccsidr_el1       = 0x00190000,
    clidr_el1        = 0x00190020,
    contextidr_el1   = 0x0018d020,
    cpacr_el1        = 0x00181040,
    cptr_el2         = 0x001c1140,
    cptr_el3         = 0x001e1140,
    csselr_el1       = 0x001a0000,
    ctr_el0          = 0x001b0020,
    dacr32_el2       = 0x001c3000,
    dczid_el0        = 0x001b00e0,
    esr_el1          = 0x00185200,
    esr_el2          = 0x001c5200,
    esr_el3          = 0x001e5200,
    esr_elx          = 0x00000000, -- invalid, NYI
    far_el1          = 0x00186000,
    far_el1          = 0x001c6000,
    far_el1          = 0x001e6000,
    fpexc32_el2      = 0x001c5300,
    hacr_el2         = 0x001c11e0,
    hcr_el2          = 0x001c1100,
    hpfar_el2        = 0x001c6080,
    hstr_el2         = 0x001c1160,
    id_aa64afr0_el1  = 0x00180580,
    id_aa64afr1_el1  = 0x001805a0,
    id_aa64dfr0_el1  = 0x00180500,
    id_aa64dfr1_el1  = 0x00180520,
    id_aa64isar0_el1 = 0x00180600,
    id_aa64isar1_el1 = 0x00180620,
    id_aa64mmfr0_el1 = 0x00180700,
    id_aa64mmfr1_el1 = 0x00180720,
    id_aa64pfr0_el1  = 0x00180400,
    id_aa64pfr1_el1  = 0x00180420,
    id_afr0_el1      = 0x00180160,
    id_dfr0_el1      = 0x00180140,
    id_isar0_el1     = 0x00180200,
    id_isar1_el1     = 0x00180220,
    id_isar2_el1     = 0x00180240,
    id_isar3_el1     = 0x00180260,
    id_isar4_el1     = 0x00180280,
    id_isar5_el1     = 0x001802a0,
    id_mmfr0_el1     = 0x00180180,
    id_mmfr1_el1     = 0x001801a0,
    id_mmfr2_el1     = 0x001801c0,
    id_mmfr3_el1     = 0x001801e0,
    id_pfr0_el1      = 0x00180100,
    id_pfr2_el1      = 0x00180120,
    ifsr32_el2       = 0x001c5020,
    isr_el1          = 0x0018c100,
    mair_el1         = 0x0018a200,
    mair_el1         = 0x001ca200,
    mair_el1         = 0x001ea200,
    midr_el1         = 0x00180000,
    mpidr_el1        = 0x001800a0,
    mvfr0_el1        = 0x00180300,
    mvfr1_el1        = 0x00180320,
    mvfr2_el1        = 0x00180340,
    par_el1          = 0x00187400,
    revidr_el1       = 0x001800c0,
    rmr_el1          = 0x0018c040,
    rmr_el2          = 0x001cc040,
    rmr_el3          = 0x001ec040,
    rvbar_el1        = 0x0018c020,
    rvbar_el2        = 0x001cc020,
    rvbar_el3        = 0x001ec020,
  --S3_<op1>_<Cn>_<Cm>_<op2>  implementation defined registers
    scr_el3          = 0x001e1100,
    sctlr_el1        = 0x00181000,
    sctlr_el2        = 0x001c1000,
    sctlr_el3        = 0x001e1000,
    tcr_el1          = 0x00182040,
    tcr_el2          = 0x001c2040,
    tcr_el3          = 0x001e2040,
    tpidr_el0        = 0x001bd040,
    tpidr_el1        = 0x0018d080,
    tpidr_el2        = 0x001cd040,
    tpidr_el3        = 0x001ed040,
    tpidrro_el0      = 0x001bd060,
    ttbr0_el1        = 0x00182000,
    ttbr0_el2        = 0x001c2000,
    ttbr0_el3        = 0x001e2000,
    ttbr1_el1        = 0x00182020,
    vbar_el1         = 0x0018c000,
    vbar_el2         = 0x001cc000,
    vbar_el3         = 0x001ec000,
    vmpidr_el2       = 0x001c00a0,
    vpidr_el2        = 0x001c0000,
    vtcr_el2         = 0x001c2140,
    vttbr_el2        = 0x001c2100,
   
    --Debug registers
    dbgauthstatus_el1  = 0x00107ec0,
    dbgbcr0_el1        = 0x001000a0, 
    dbgbcr1_el1        = 0x001001a0, 
    dbgbcr2_el1        = 0x001002a0, 
    dbgbcr3_el1        = 0x001003a0, 
    dbgbcr4_el1        = 0x001004a0, 
    dbgbcr5_el1        = 0x001005a0, 
    dbgbcr6_el1        = 0x001006a0, 
    dbgbcr7_el1        = 0x001007a0, 
    dbgbcr8_el1        = 0x001008a0, 
    dbgbcr9_el1        = 0x001009a0, 
    dbgbcr10_el1       = 0x00100aa0, 
    dbgbcr11_el1       = 0x00100ba0, 
    dbgbcr12_el1       = 0x00100ca0, 
    dbgbcr13_el1       = 0x00100da0, 
    dbgbcr14_el1       = 0x00100ea0, 
    dbgbcr15_el1       = 0x00100fa0, 
    dbgbvr0_el1        = 0x00100080,
    dbgbvr1_el1        = 0x00100180,
    dbgbvr2_el1        = 0x00100280,
    dbgbvr3_el1        = 0x00100380,
    dbgbvr4_el1        = 0x00100480,
    dbgbvr5_el1        = 0x00100580,
    dbgbvr6_el1        = 0x00100680,
    dbgbvr7_el1        = 0x00100780,
    dbgbvr8_el1        = 0x00100880,
    dbgbvr9_el1        = 0x00100980,
    dbgbvr10_el1       = 0x00100a80,
    dbgbvr11_el1       = 0x00100b80,
    dbgbvr12_el1       = 0x00100c80,
    dbgbvr13_el1       = 0x00100d80,
    dbgbvr14_el1       = 0x00100e80,
    dbgbvr15_el1       = 0x00100f80,
    dbgclaimclr_el1    = 0x001079c0,
    dbgclaimset_el1    = 0x001078c0,
    dbgdtr_el0         = 0x00130400,
    dbgdtrrx_el0       = 0x00130500,
    dbgdtrtx_el0       = 0x00130500,
    dbgprcr_el1        = 0x00101480,
    dbgvcr32_el2       = 0x00140700,
    dbgwcr0_el1        = 0x001000e0,
    dbgwcr1_el1        = 0x001001e0,
    dbgwcr2_el1        = 0x001002e0,
    dbgwcr3_el1        = 0x001003e0,
    dbgwcr4_el1        = 0x001004e0,
    dbgwcr5_el1        = 0x001005e0,
    dbgwcr6_el1        = 0x001006e0,
    dbgwcr7_el1        = 0x001007e0,
    dbgwcr8_el1        = 0x001008e0,
    dbgwcr9_el1        = 0x001009e0,
    dbgwcr10_el1       = 0x00100ae0,
    dbgwcr11_el1       = 0x00100be0,
    dbgwcr12_el1       = 0x00100ce0,
    dbgwcr13_el1       = 0x00100de0,
    dbgwcr14_el1       = 0x00100ee0,
    dbgwcr15_el1       = 0x00100fe0,
    dbgwvr0_el1        = 0x001000c0,
    dbgwvr1_el1        = 0x001001c0,
    dbgwvr2_el1        = 0x001002c0,
    dbgwvr3_el1        = 0x001003c0,
    dbgwvr4_el1        = 0x001004c0,
    dbgwvr5_el1        = 0x001005c0,
    dbgwvr6_el1        = 0x001006c0,
    dbgwvr7_el1        = 0x001007c0,
    dbgwvr8_el1        = 0x001008c0,
    dbgwvr9_el1        = 0x001009c0,
    dbgwvr10_el1       = 0x00100ac0,
    dbgwvr11_el1       = 0x00100bc0,
    dbgwvr12_el1       = 0x00100cc0,
    dbgwvr13_el1       = 0x00100dc0,
    dbgwvr14_el1       = 0x00100ec0,
    dbgwvr15_el1       = 0x00100fc0,
    dlr_el0            = 0x001b4520,
    dspsr_el0          = 0x001b4500,
    mdccint_el1        = 0x00100200,
    mdccsr_el0         = 0x00130100,
    mdcr_el2           = 0x001c1120,
    mdcr_el3           = 0x001e1320,
    mdrar_el1          = 0x00101000,
    mdscr_el1          = 0x00100240,
    osdlr_el1          = 0x00101380,
    osdtrrx_el1        = 0x00100040,
    osdtrtx_el1        = 0x00100340,
    oseccr_el1         = 0x00100640,
    oslar_el1          = 0x00101080,
    oslsr_el1          = 0x00101180,
    sder32_el3         = 0x001e1120,
 
    -- performance monitors registers
    pmccfiltr_el0      = 0x001befe0,
    pmccntr_el0        = 0x001b9d00,
    pmceid0_el0        = 0x001b9cc0,
    pmceid1_el0        = 0x001b9ce0,
    pmcntenclr_el0     = 0x001b9c40,
    pmcntenset_el0     = 0x001b9c20,
    pmcr_el0           = 0x001b9c00,
    pmevcntr0_el0      = 0x001be800,
    pmevcntr1_el0      = 0x001be820,
    pmevcntr2_el0      = 0x001be840,
    pmevcntr3_el0      = 0x001be860,
    pmevcntr4_el0      = 0x001be880,
    pmevcntr5_el0      = 0x001be8a0,
    pmevcntr6_el0      = 0x001be8c0,
    pmevcntr7_el0      = 0x001be8e0,
    pmevcntr8_el0      = 0x001be900,
    pmevcntr9_el0      = 0x001be920,
    pmevcntr10_el0     = 0x001be940,
    pmevcntr11_el0     = 0x001be960,
    pmevcntr12_el0     = 0x001be980,
    pmevcntr13_el0     = 0x001be9a0,
    pmevcntr14_el0     = 0x001be9c0,
    pmevcntr15_el0     = 0x001be9e0,
    pmevcntr16_el0     = 0x001bea00,
    pmevcntr17_el0     = 0x001bea20,
    pmevcntr18_el0     = 0x001bea40,
    pmevcntr19_el0     = 0x001bea60,
    pmevcntr20_el0     = 0x001bea80,
    pmevcntr21_el0     = 0x001beaa0,
    pmevcntr22_el0     = 0x001beac0,
    pmevcntr23_el0     = 0x001beae0,
    pmevcntr24_el0     = 0x001beb00,
    pmevcntr25_el0     = 0x001beb20,
    pmevcntr26_el0     = 0x001beb40,
    pmevcntr27_el0     = 0x001beb60,
    pmevcntr28_el0     = 0x001beb80,
    pmevcntr29_el0     = 0x001beba0,
    pmevcntr30_el0     = 0x001bebc0,
    pmevtyper0_el0     = 0x001bec00,
    pmevtyper1_el0     = 0x001bec20,
    pmevtyper2_el0     = 0x001bec40,
    pmevtyper3_el0     = 0x001bec60,
    pmevtyper4_el0     = 0x001bec80,
    pmevtyper5_el0     = 0x001beca0,
    pmevtyper6_el0     = 0x001becc0,
    pmevtyper7_el0     = 0x001bece0,
    pmevtyper8_el0     = 0x001bed00,
    pmevtyper9_el0     = 0x001bed20,
    pmevtyper10_el0    = 0x001bed40,
    pmevtyper11_el0    = 0x001bed60,
    pmevtyper12_el0    = 0x001bed80,
    pmevtyper13_el0    = 0x001beda0,
    pmevtyper14_el0    = 0x001bedc0,
    pmevtyper15_el0    = 0x001bede0,
    pmevtyper16_el0    = 0x001bee00,
    pmevtyper17_el0    = 0x001bee20,
    pmevtyper18_el0    = 0x001bee40,
    pmevtyper19_el0    = 0x001bee60,
    pmevtyper20_el0    = 0x001bee80,
    pmevtyper21_el0    = 0x001beea0,
    pmevtyper22_el0    = 0x001beec0,
    pmevtyper23_el0    = 0x001beee0,
    pmevtyper24_el0    = 0x001bef00,
    pmevtyper25_el0    = 0x001bef20,
    pmevtyper26_el0    = 0x001bef40,
    pmevtyper27_el0    = 0x001bef60,
    pmevtyper28_el0    = 0x001bef80,
    pmevtyper29_el0    = 0x001befa0,
    pmevtyper30_el0    = 0x001befc0,
    pmintenclr_el1     = 0x00189e40,
    pmintenset_el1     = 0x00189e20,
    pmovsclr_el0       = 0x001b9c60,
    pmovsset_el0       = 0x001b9e60,
    pmselr_el0         = 0x001b9ca0,
    pmswinc_el0        = 0x001b9c80,
    pmuserenr_el0      = 0x001b9e00,
    pmxevcntr_el0      = 0x001b9d40,
    pmxevtyper_el0     = 0x001b9d20,
 
    --Generic timer registers
    cntfrq_el0         = 0x001be000,
    cnthctl_el2        = 0x001ce100,
    cnthp_ctl_el2      = 0x001ce220,
    cnthp_cval_el2     = 0x001ce240,
    cnthp_tval_el2     = 0x001ce200,
    cntkctl_el1        = 0x0018e100,
    cntp_ctl_el0       = 0x001be220,
    cntp_cval_el0      = 0x001be240,
    cntp_tval_el0      = 0x001be200,
    cntpct_el0         = 0x001be020,
    cntps_ctl_el1      = 0x001fe220,
    cntps_cval_el0     = 0x001fe240,
    cntps_tval_el0     = 0x001fe200,
    cntv_ctl_el0       = 0x001be320,
    cntv_cval_el0      = 0x001be340,
    cntv_tval_el0      = 0x001be300,
    cntvct_el0         = 0x001be040,
    cntvoff_el2        = 0x001ce060,
 
    --Generic Interrupt controller CPU interface registers
    icc_ap0r0_el1      = 0x0018c880,
    icc_ap0r1_el1      = 0x0018c8a0,
    icc_ap0r2_el1      = 0x0018c8c0,
    icc_ap0r3_el1      = 0x0018c8e0,
    icc_ap1r0_el1      = 0x0018c900,
    icc_ap1r1_el1      = 0x0018c920,
    icc_ap1r2_el1      = 0x0018c940,
    icc_ap1r3_el1      = 0x0018c960,
    icc_asgi1r_el1     = 0x0018cbc0,
    icc_bpr0_el1       = 0x0018c860,
    icc_bpr1_el1       = 0x0018cc60,
    icc_ctlr_el1       = 0x0018cc80,
    icc_ctlr_el3       = 0x001ecc80,
    icc_dir_el1        = 0x0018cb20,
    icc_eoir0_el1      = 0x0018c820,
    icc_eoir1_el1      = 0x0018cc20,
    icc_hppir0_el1     = 0x0018c840,
    icc_hppir1_el1     = 0x0018cc40,
    icc_iar0_el1       = 0x0018c800,
    icc_iar1_el1       = 0x0018cc00,
    icc_igrpen0_el1    = 0x0018ccc0,
    icc_igrpen1_el1    = 0x0018cce0,
    icc_igrpen1_el3    = 0x001ecce0,
    icc_pmr_el1        = 0x00184600,
    icc_rpr_el1        = 0x0018cb60,
    icc_sgi0r_el1      = 0x0018cbe0,
    icc_sgi1r_el1      = 0x0018cba0,
    icc_sre_el1        = 0x0018cca0,
    icc_sre_el2        = 0x001cc9a0,
    icc_sre_el3        = 0x001ecca0,
    ich_ap0r0_el2      = 0x001cc800,
    ich_ap0r1_el2      = 0x001cc820,
    ich_ap0r2_el2      = 0x001cc840,
    ich_ap0r3_el2      = 0x001cc860,
    ich_ap1r0_el2      = 0x001cc900,
    ich_ap1r1_el2      = 0x001cc920,
    ich_ap1r2_el2      = 0x001cc940,
    ich_ap1r3_el2      = 0x001cc960,
    ich_eisr_el2       = 0x001ccb60,
    ich_elrsr_el2      = 0x001ccba0,
    ich_hcr_el2        = 0x001ccb00,
    ich_lr0_el2        = 0x001ccc00,
    ich_lr1_el2        = 0x001ccc20,
    ich_lr2_el2        = 0x001ccc40,
    ich_lr3_el2        = 0x001ccc60,
    ich_lr4_el2        = 0x001ccc80,
    ich_lr5_el2        = 0x001ccca0,
    ich_lr6_el2        = 0x001cccc0,
    ich_lr7_el2        = 0x001ccce0,
    ich_lr8_el2        = 0x001ccd00,
    ich_lr9_el2        = 0x001ccd20,
    ich_lr10_el2       = 0x001ccd40,
    ich_lr11_el2       = 0x001ccd60,
    ich_lr12_el2       = 0x001ccd80,
    ich_lr13_el2       = 0x001ccda0,
    ich_lr14_el2       = 0x001ccdc0,
    ich_lr15_el2       = 0x001ccde0,
    ich_misr_el2       = 0x001ccb40,
    ich_vmcr_el2       = 0x001ccbe0,
    ich_vtr_el2        = 0x001ccb20
}

local pstate_map = {
    spsel = 0x000000a0,
    daifset = 0x000300c0,
    daifclr = 0x000300e0
}

local prefetch_op_map = {
    pldl1keep = 0,
    pldl1strm = 1,
    pldl2keep = 2,
    pldl2strm = 3,
    pldl3keep = 4,
    pldl3strm = 5,
    ["#6"]    = 6,
    ["#7"]    = 7,
    plil1keep = 8,
    plil1strm = 9,
    plil2keep = 10,
    plil2strm = 11,
    plil3keep = 12,
    plil3strm = 13,
    ["#14"]   = 14,
    ["#15"]   = 15,
    pstl1keep = 16,
    pstl1strm = 17,
    pstl2keep = 18,
    pstl2strm = 19,
    pstl3keep = 20,
    pstl3strm = 21,
    ["#22"]   = 22,
    ["#23"]   = 23,
    ["#24"]   = 24,
    ["#25"]   = 25,
    ["#26"]   = 26,
    ["#27"]   = 27,
    ["#28"]   = 28,
    ["#29"]   = 29,
    ["#30"]   = 30,
    ["#31"]   = 31
}

-- Handle opcodes defined with template strings.
local function parse_template(params, template, nparams, pos)
    local op = tonumber(sub(template, 1, 8), 16)
    local n = 1
   
    -- refer to comment to map_op for the meaning of each cmd
    for cmd,var,bp1,bp2,bp3 in gmatch(sub(template, 9), "(%u%l?)(%d*)%.?(%-?%d*)%.?(%-?%d*)%.?(%-?%d*)") do
        local param = params[n]
        var = tonumber(var)
        bp1 = tonumber(bp1)
        bp2 = tonumber(bp2)
        bp3 = tonumber(bp3)
        if cmd == "G" then --Rd/Rt
            local sf, gpr = parse_gpr(param, bp1)
            if var == 1 then --Rn
                gpr = shl(gpr, 5)
            elseif var == 2 then --Rm
                gpr = shl(gpr, 16)
            elseif var == 3 then --Rn and Rm
                gpr = shl(gpr, 5) + shl(gpr, 16)
            elseif var == 4 then --Rt2
                gpr = shl(gpr, 10)
            elseif var == 5 then --Rn where Rd=SP or Rn=SP
                if gpr ~= 31 and band(op, 31) ~= 31 then
                    werror("invalid register")
                end
                gpr = shl(gpr, 5)
            end 
            op = op + gpr
            n = n + 1
        elseif cmd == "E" then
            if var == 1 then
                op = parse_ext_or_sr(op, params, n, nparams)
            elseif var == 2 then
                op = op + parse_sr(op, params, n, nparams)
            elseif var == 3 then
                local bo = barrier_options[param]
                if bo then
                    if band(op, 0x40) == 1 and bo ~= 15 then
                        werror("only sy is allowed for ISB")
                    end
                    op = op + shl(bo, 8)
                else
                    op = op + parse_imm(param, 4, 8, 0, false)
                end
            else
                werror("invalid template `"..template..".")
            end
            n = n + 1
        elseif cmd == "L" then
            local mode, val, arg = parse_label(param)
            
            -- var is label type
            if var >=0 and var <= 4 then
                wactionl("REL_"..mode, val + shl(var, 12), arg, 1)
            else
                werror("invalid template `"..template..".")
            end
            n = n + 1
        elseif cmd == "I" then
            local bit64 = bp1 == 1
            if var == 0 then
                if (bp1 and param ~= ("#"..bp1)) or
                   (not bp1 and param ~= "#0" and param ~= "#0.0") then
                    werror("invalide value `"..param.."'")
                end
            elseif var == 1 then
                op = op + parse_imm(param, 6, 16, 0, false)
            elseif var == 2 then
                op = op + parse_imm(param, 6, 10, 0, false)
            elseif var == 3 then
                op = op + parse_immlsb(param, bit64)
            elseif var == 4 then
                op = op + parse_immwidth1(op, param, bit64)
            elseif var == 5 then
                op = op + parse_immwidth2(op, param, bit64)
            elseif var == 6 then
                op = op + parse_imm(param, 16, 5, 0, false)
            elseif var == 7 then
                op = op + parse_imm(param, 7, 5, 0, false)
            elseif var == 8 then
                op = op + parse_imm(param, 4, 8, 0, false)
            elseif var == 9 then
                op = op + parse_imm_move_lsl(param, bit64)
            elseif var == 10 then
                op = op + parse_shifted_imm12(params, n, nparams)
            elseif var == 11 then
                op = op + parse_immnsr(param, bit64)
            elseif var == 12 then
                op = op + parse_imm(param, 5, 16, 0, false)
            elseif var == 13 then
                op = op + parse_imm_shift(param, bit64)
            elseif var == 14 then
                op = op + parse_immmov(param, bit64)
            elseif var == 15 then
                local scale = bp1 == nil and 0 or bp1
                op = op + parse_imm(param, 7, 15, scale, true)
            elseif var == 16 then
                local scale = bp1 == nil and 0 or bp1
                op = op + parse_imm(param, 9, 12, scale, true)
            elseif var == 17 then
                op = op + parse_imm(param, 3, 16, 0, false)
            elseif var == 18 then
                op = op + parse_imm(param, 3, 5, 0, false)
            elseif var == 19 then
                op = op + parse_immtbn(param, bit64)
            elseif var == 20 then
                op = op + parse_imma2h(param)
            elseif var == 21 then
                op = op + parse_immlsl(param, bp1)
            elseif var == 22 then
                op = op + parse_immmsl(param)
            elseif var == 23 then
                op = op + parse_imma2h64(param)
            elseif var == 24 then
                local q = bp1
                if q == 0 then
                    op = op + parse_imm(param, 3, 11, 0, false)
                elseif q == 1 then
                    op = op + parse_imm(param, 4, 11, 0, false)
                end
            elseif var == 25 then
                local bits = bp1
                op = op + parse_immhb(param, bits)
            elseif var == 26 then
                local q = bp1
                op = op + parse_immscale(param, q)
            elseif var == 27 then
                op = op + parse_imma2hfp(param)
            elseif var == 28 then --for fmov
                op = op + parse_imm8fp(param)
            elseif var == 29 then
                local bits = bp1
                op = op + parse_immhb1(param, bits)
            else
               werror("invalid template `"..template..".")
            end
            n = n + 1
        elseif cmd == "Sy" then
            if var == 1 then
                local at = sys_at[param]
                if not at then werror("invalid address translate operation `"..param.."'") end
                op = op + at
            elseif var == 2 then
                local dc = sys_dc[param]
                if not dc then werror("invalid data cache operation `"..param..".") end
                op = op + dc
            elseif var == 3 then
                local ic = sys_ic[param]
                if not ic then werror("invalid instruction cache operation `"..param..".") end
                op = op + ic
            elseif var == 4 then
                local tlb = sys_tlb[param]
                if not tlb then werror("invalid TLB operation `"..param..".") end
                op = op + tlb
            elseif var == 5 then
                local sreg = system_register_map[param]
                if not sreg then werror("invalid system register `"..param.."'") end
                op = op + band(sreg, 0xffefffff)
            elseif var == 6 then
                local pstate = pstate_map[param]
                if not pstate then werror("invalid pstate `"..param..".") end
                op = op + pstate
            else
                werror("invalid template `"..template..".")
            end
            n = n + 1
        elseif cmd == "Cd" then
             local cv = map_cond[param]
             if not cv then werror("invalid condition `"..param.."'") end
             op = op + shl(cv, 12)
             n = n + 1
        elseif cmd == "F" then
             op = op + parse_imm(param, 4, 0, 0, false)
             n = n + 1
        elseif cmd == "A" then
            if var == 0 then
                local base = parse_address0(param)
                op = op + shl(base, 5)
            elseif var == 1 then
                local base, imm = parse_address1(param, bp1)
                op = op + shl(base, 5) + imm
            elseif var == 2 then
                local base = parse_address2(param)
                op = op + shl(base, 5)
            elseif var == 3 then
                local base, imm = parse_address3(param, bp1)
                op = op + shl(base, 5) + imm
            elseif var == 4 then
                local base, imm = parse_address4(param, bp1)
                op = op + shl(base, 5) + imm
            elseif var == 5 then
                local base, imm = parse_address5(param, bp1)
                op = op + shl(base, 5) + imm
            elseif var == 6 then
                local addr = parse_address6(param, bp1)
                op = op + addr
            elseif var == 7 then
                local base, imm = parse_address7(param, bp1)
                op = op + shl(base, 5) + imm
            else
               werror("invalid template `"..template..".")
            end
            n = n + 1
        elseif cmd == "P" then
            local prefetch = prefetch_op_map[param]
            if not prefetch then werror("invalid prefetch operation `"..param.."'") end
            op = op + prefetch
            n = n + 1
        elseif cmd == "Cn" then
            local control = parse_control(param)
            if var == 1 then
               op = op + shl(control, 12)
            elseif var == 2 then
               op = op + shl(control, 8)
            else
               werror("invalid template `"..template.."'")
            end
            n = n + 1
        elseif cmd == "N" then
            local kind = bp1
            local scr = parse_scr(param, kind)
            if var == 0 then
                op = op + scr 
            elseif var == 1 then
                op = op + shl(scr, 5)
            elseif var == 2 then
                op = op + shl(scr, 16)
            elseif var == 4 then
                op = op + shl(scr, 10)
            end
            n = n + 1
        elseif cmd == "V" then
            local q = bp1
            local kind = bp2
            local vr = parse_vr(param, kind, q)
            if var == 0 then
                op = op + vr
            elseif var == 1 then
                op = op + shl(vr, 5)
            elseif var == 2 then
                op = op + shl(vr, 16)
            end
            n = n + 1
        elseif cmd == "Ev" then
            local ekind = bp1
            local indextype = bp2
            local vr, imm = parse_ve(param, ekind, indextype)
            if var == 0 then
                op = op + vr + imm
            elseif var == 1 then
                op = op + shl(vr, 5) + imm
            elseif var == 2 then
                -- TODO if size=01, Rm should < 16
                op = op + shl(vr, 16) + imm
            end
            n = n + 1
        elseif cmd == "El" then
            local llen = var
            local ekind = bp1
            local vr, imm = parse_vle(param, llen, ekind)
            op = op + vr + imm
            n = n + 1
        elseif cmd == "Lv" then
            local llen = bp1
            local q = bp2
            local ekind = bp3
            local vr = parse_vl(param, llen, ekind, q)
            if var == 0 then
                op = op + vr
            elseif var == 1 then
                op = op + shl(vr, 5)
            elseif var == 2 then
                op = op + shl(vr, 16)
            end
            n = n + 1
        else
            assert(false)
        end
    end
    wputpos(pos, op)
end


map_op[".template__"] = function(params, template)
    if not params then return sub(template, 9) end

    -- Limit number of section buffer positions used by a single dasm_put().
    -- A single opcode needs a maximum of 3 positions.
    if secpos+3 > maxsecpos then wflush() end
    local pos = wpos()
    local apos, spos = #actargs, secpos

    local ok, err
    for t in gmatch(template, "[^|]+") do
        ok, err = pcall(parse_template, params, t, #params, pos)
        if ok then return end
        secpos = spos
        actargs[apos+1] = nil
        actargs[apos+2] = nil
        actargs[apos+3] = nil
    end
    error(err, 0)
end

------------------------------------------------------------------------------

-- Pseudo-opcode to mark the position where the action list is to be emitted.
map_op[".actionlist_1"] = function(params)
    if not params then return "cvar" end
    local name = params[1] -- No syntax check. You get to keep the pieces.
    wline(function(out) writeactions(out, name) end)
end

-- Pseudo-opcode to mark the position where the global enum is to be emitted.
map_op[".globals_1"] = function(params)
    if not params then return "prefix" end
    local prefix = params[1] -- No syntax check. You get to keep the pieces.
    wline(function(out) writeglobals(out, prefix) end)
end

-- Pseudo-opcode to mark the position where the global names are to be emitted.
map_op[".globalnames_1"] = function(params)
    if not params then return "cvar" end
    local name = params[1] -- No syntax check. You get to keep the pieces.
    wline(function(out) writeglobalnames(out, name) end)
end

-- Pseudo-opcode to mark the position where the extern names are to be emitted.
map_op[".externnames_1"] = function(params)
    if not params then return "cvar" end
    local name = params[1] -- No syntax check. You get to keep the pieces.
    wline(function(out) writeexternnames(out, name) end)
end

------------------------------------------------------------------------------

-- Label pseudo-opcode (converted from trailing colon form).
map_op[".label_1"] = function(params)
    if not params then return "[1-9] | ->global | =>pcexpr" end
    if secpos+1 > maxsecpos then wflush() end
    local mode, n, s = parse_label(params[1], true)
    if mode == "EXT" then werror("bad label definition") end
    wactionl("LABEL_"..mode, n, s, 1)
end

------------------------------------------------------------------------------

-- Pseudo-opcodes for data storage.
map_op[".long_*"] = function(params)
    if not params then return "imm..." end
    for _,p in ipairs(params) do
        local n = tonumber(p)
        if not n then werror("bad immediate `"..p.."'") end
        if n < 0 then n = n + 2^32 end
        wputw(n)
        if secpos+2 > maxsecpos then wflush() end
    end
end

-- Alignment pseudo-opcode.
map_op[".align_1"] = function(params)
    if not params then return "numpow2" end
    if secpos+1 > maxsecpos then wflush() end
    local align = tonumber(params[1])
    if align then
        local x = align
        -- Must be a power of 2 in the range (2 ... 256).
        for i=1,8 do
            x = x / 2
            if x == 1 then
                waction("ALIGN", align-1, nil, 1) -- Action byte is 2**n-1.
                return
            end
        end
    end
    werror("bad alignment")
end

------------------------------------------------------------------------------

-- Pseudo-opcode for (primitive) type definitions (map to C types).
map_op[".type_3"] = function(params, nparams)
    if not params then
        return nparams == 2 and "name, ctype" or "name, ctype, reg"
    end
    local name, ctype, reg = params[1], params[2], params[3]
    if not match(name, "^[%a_][%w_]*$") then
        werror("bad type name `"..name.."'")
    end
    local tp = map_type[name]
    if tp then
        werror("duplicate type `"..name.."'")
    end
    -- Add #type to defines. A bit unclean to put it in map_archdef.
    map_archdef["#"..name] = "sizeof("..ctype..")"
    -- Add new type and emit shortcut define.
    local num = ctypenum + 1
    map_type[name] = {
        ctype = ctype,
        ctypefmt = format("Dt%X(%%s)", num),
        reg = reg,
    }
    wline(format("#define Dt%X(_V) (int)(ptrdiff_t)&(((%s *)0)_V)", num, ctype))
    ctypenum = num
end
map_op[".type_2"] = map_op[".type_3"]

-- Dump type definitions.
local function dumptypes(out, lvl)
    local t = {}
    for name in pairs(map_type) do t[#t+1] = name end
    sort(t)
    out:write("Type definitions:\n")
    for _,name in ipairs(t) do
        local tp = map_type[name]
        local reg = tp.reg or ""
        out:write(format("  %-20s %-20s %s\n", name, tp.ctype, reg))
    end
    out:write("\n")
end

------------------------------------------------------------------------------

-- Set the current section.
function _M.section(num)
    waction("SECTION", num)
    wflush(true) -- SECTION is a terminal action.
end

------------------------------------------------------------------------------

-- Dump architecture description.
function _M.dumparch(out)
    out:write(format("DynASM %s version %s, released %s\n\n",
                     _info.arch, _info.version, _info.release))
    dumpactions(out)
end

-- Dump all user defined elements.
function _M.dumpdef(out, lvl)
    dumptypes(out, lvl)
    dumpglobals(out, lvl)
    dumpexterns(out, lvl)
end

------------------------------------------------------------------------------

-- Pass callbacks from/to the DynASM core.
function _M.passcb(wl, we, wf, ww)
    wline, werror, wfatal, wwarn = wl, we, wf, ww
    return wflush
end

-- Setup the arch-specific module.
function _M.setup(arch, opt)
    g_arch, g_opt = arch, opt
end

-- Merge the core maps and the arch-specific maps.
function _M.mergemaps(map_coreop, map_def)
    local indexf = function(t, k)
        local v = map_coreop[k]
        if v then return v end
        local cc = match(k, "^b%.(..)_1$")
        local cv = map_cond[cc]
        if cv then
            local v = rawget(t, "b.cc_1")
            if type(v) == "string" then
                local scv = format("%x", cv)
                return sub(v,1,-4)..scv..sub(v,-2)
            end
        end
    end
    setmetatable(map_op, { __index = indexf })
    setmetatable(map_def, { __index = map_archdef })
    return map_op, map_def
end

return _M

------------------------------------------------------------------------------

