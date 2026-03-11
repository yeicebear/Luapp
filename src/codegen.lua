-- lpp codegen
-- takes the AST and spits out QBE IR.
-- QBE then turns that into real machine code so we don't have to.
-- honestly QBE does most of the hard work here. we just do the bookkeeping.
--
-- QBE type mapping (aka the part i always forget):
--   int / bool / char -> w  (32-bit word)
--   long              -> l  (64-bit integer, also used for pointers)
--   float             -> d  (64-bit double — QBE has no f32, we use d for everything)
--   str               -> l  (pointer to null-terminated char data)
--   fixed array       -> stack block, we do pointer arithmetic to index
--   dynamic array     -> l  (pointer to heap block managed by stdlib.c)
--   struct            -> stack block, fields at pre-calculated byte offsets
--
-- all locals get alloca'd at function entry regardless of where they appear in source.
-- this sidesteps QBE's dominance checker complaining about temporaries that aren't defined
-- on all paths. yes it wastes stack space. no i don't care.
-- corny ass reviewer
--
-- AND/OR short-circuit by spilling through a stack slot and loading after the join label.
-- there are no phi nodes here. QBE handles SSA form internally after we give it the IR.

local lpp_nlabels  = 0
local lpp_ntemps   = 0
local lpp_str_lits = {}  -- collected string literals to emit in the data section at the end
local lpp_nstrs    = 0

local function lpp_mklbl(hint)
    lpp_nlabels = lpp_nlabels+1
    return "@lpp_"..hint..lpp_nlabels
end

local function lpp_mktmp(hint)
    lpp_ntemps = lpp_ntemps+1
    return "lpp_"..hint..lpp_ntemps
end

local function lpp_emit(buf, line) buf[#buf+1] = line end

-- intern a string literal into the data section and return its label.
-- same string appearing twice will get two separate labels. that's fine, strings are immutable.
local function lpp_intern_str(s)
    lpp_nstrs = lpp_nstrs+1
    local lbl = "lpp_strlit"..lpp_nstrs
    lpp_str_lits[#lpp_str_lits+1] = {lbl=lbl, val=s}
    return lbl
end

-- map a declared type string to its QBE type character
local function lpp_type_qt(t)
    if not t then return "w" end
    if t == "float"  then return "d" end
    if t == "str"    then return "l" end
    if t == "long"   then return "l" end
    if t == "char"   then return "w" end  -- char is just a byte-sized int, we use w anyway
    if t:match("%[%]$")    then return "l" end    -- dynamic array = pointer
    if t:match("%[%d+%]$") then return "arr" end  -- fixed array = special case
    return "w"  -- int, bool, unknown — default to word
end

-- byte size of a scalar element type
local function lpp_basetype_sz(t)
    if t == "float" then return 8 end
    if t == "str"   then return 8 end
    if t == "long"  then return 8 end
    if t == "char"  then return 1 end
    return 4  -- int, bool, char (padded), etc.
end

local function lpp_basetype_qt(t)
    if t == "float" then return "d" end
    if t == "str"   then return "l" end
    if t == "long"  then return "l" end
    return "w"
end

-- parse an array type string like "int[10]" -> "int", 10
-- or "float[]" -> "float", nil  (nil size = dynamic)
local function lpp_parse_arrtype(vtype)
    local base, sz = vtype:match("^(.+)%[(%d+)%]$")
    if base and sz then return base, tonumber(sz) end
    local dbase = vtype:match("^(.+)%[%]$")
    if dbase then return dbase, nil end
    return nil, nil
end

-- QBE integer comparison ops
local lpp_int_opmap = {
    PLUS="add",  MINUS="sub",  STAR="mul",  SLASH="div",  PCENT="rem",
    EQ="ceqw",   NEQ="cnew",   GT="csgtw",  LT="csltw",
    GE="csgew",  LE="cslew",
    AMP="and",   PIPE="or",    CARET="xor",  SHL="shl",   SHR="sar",
}

-- QBE float comparison ops (d suffix = double)
local lpp_flt_opmap = {
    PLUS="add",  MINUS="sub",  STAR="mul",  SLASH="div",
    EQ="ceqd",   NEQ="cned",   GT="cgtd",   LT="cltd",
    GE="cged",   LE="cled",
}

-- QBE 64-bit integer ops
local lpp_long_opmap = {
    PLUS="add",  MINUS="sub",  STAR="mul",  SLASH="div",  PCENT="rem",
    EQ="ceql",   NEQ="cnel",   GT="csgtl",  LT="csltl",
    GE="csgel",  LE="cslel",
    AMP="and",   PIPE="or",    CARET="xor",  SHL="shl",   SHR="sar",
}

local lpp_lower_xpr, lpp_lower_block, lpp_lower_stmt

-- these get set per-function so all the lower_* functions can see them
local lpp_cur_vartypes = {}  -- varname -> declared type string (e.g. "int", "float", "int[10]")
local lpp_cur_structs  = {}  -- struct name -> {fields, size}
local lpp_fn_rtypes    = {}  -- function name -> qbe return type ("w", "d", "l")
local lpp_globals      = {}  -- global varname -> type string (for load/store routing)
local lpp_cur_self_struct = nil  -- if inside a method, the struct name "self" points to

local function lpp_qt_for_var(vname)
    local vt = lpp_cur_vartypes[vname] or lpp_globals[vname]
    if not vt then return "w" end
    return lpp_type_qt(vt)
end

-- check if an expression node will produce a float value
-- used to decide which opmap to use for binary operations
local function lpp_is_float_node(n)
    if not n then return false end
    if n.kind == "lit_float" then return true end
    if n.kind == "var" then return lpp_qt_for_var(n.vname) == "d" end
    if n.kind == "binop" then return lpp_is_float_node(n.lhs) or lpp_is_float_node(n.rhs) end
    return false
end

-- same but for long (64-bit int)
local function lpp_is_long_node(n)
    if not n then return false end
    if n.kind == "var" then return lpp_cur_vartypes[n.vname] == "long" end
    if n.kind == "binop" then return lpp_is_long_node(n.lhs) or lpp_is_long_node(n.rhs) end
    return false
end

lpp_lower_xpr = function(buf, node, dest)
    local k = node.kind

    if k == "lit_int" then
        lpp_emit(buf, string.format("    %%%s =w copy %d", dest, node.ival))

    elseif k == "lit_float" then
        -- QBE double literals use the d_ prefix
        lpp_emit(buf, string.format("    %%%s =d copy d_%s", dest, tostring(node.fval)))

    elseif k == "lit_str" then
        local lbl = lpp_intern_str(node.sval)
        lpp_emit(buf, string.format("    %%%s =l copy $%s", dest, lbl))

    elseif k == "var" then
        local qt = lpp_qt_for_var(node.vname)
        if lpp_globals[node.vname] then
            -- global: address is $name, load directly from it
            if qt == "d" then
                lpp_emit(buf, string.format("    %%%s =d loadd $%s", dest, node.vname))
            elseif qt == "l" then
                lpp_emit(buf, string.format("    %%%s =l loadl $%s", dest, node.vname))
            else
                lpp_emit(buf, string.format("    %%%s =w loadw $%s", dest, node.vname))
            end
        else
            if qt == "d" then
                lpp_emit(buf, string.format("    %%%s =d loadd %%%s_slot", dest, node.vname))
            elseif qt == "l" then
                lpp_emit(buf, string.format("    %%%s =l loadl %%%s_slot", dest, node.vname))
            else
                lpp_emit(buf, string.format("    %%%s =w loadw %%%s_slot", dest, node.vname))
            end
        end

    elseif k == "arr_get" then
        -- index into an array: base_ptr + idx * elem_size
        -- for fixed arrays the base is the slot itself (stack pointer)
        -- for dynamic arrays we load the pointer first then offset
        local vt = lpp_cur_vartypes[node.vname] or "int[1]"
        local arrbase, arrsz = lpp_parse_arrtype(vt)
        arrbase = arrbase or "int"
        local eqt = lpp_basetype_qt(arrbase)
        local esz = lpp_basetype_sz(arrbase)
        local tidx = lpp_mktmp("arridx")
        local toff = lpp_mktmp("arroff")
        local tptr = lpp_mktmp("arrptr")
        lpp_lower_xpr(buf, node.idx, tidx)
        lpp_emit(buf, string.format("    %%%s =l extsw %%%s", toff, tidx))  -- sign-extend idx to 64-bit
        lpp_emit(buf, string.format("    %%%s =l mul %%%s, %d", toff, toff, esz))
        if arrsz then
            -- fixed array: slot IS the array, just add offset
            lpp_emit(buf, string.format("    %%%s =l add %%%s_slot, %%%s", tptr, node.vname, toff))
        else
            -- dynamic array: load the pointer from the slot, then add offset
            local tbase = lpp_mktmp("dynbase")
            lpp_emit(buf, string.format("    %%%s =l loadl %%%s_slot", tbase, node.vname))
            lpp_emit(buf, string.format("    %%%s =l add %%%s, %%%s", tptr, tbase, toff))
        end
        if eqt == "d" then
            lpp_emit(buf, string.format("    %%%s =d loadd %%%s", dest, tptr))
        elseif eqt == "l" then
            lpp_emit(buf, string.format("    %%%s =l loadl %%%s", dest, tptr))
        else
            lpp_emit(buf, string.format("    %%%s =w loadw %%%s", dest, tptr))
        end

    elseif k == "field_get" then
        -- struct field access: base_ptr + field_offset (calculated at parse time)
        local qt = lpp_cur_vartypes[node.vname] or ""
        local sname = qt:match("^struct:(.+)$") or qt
        -- if the variable is "self" (a long/pointer) inside a method, use self_struct
        local is_ptr_access = (lpp_cur_vartypes[node.vname] == "long" and lpp_cur_self_struct)
        if is_ptr_access then sname = lpp_cur_self_struct end
        local sdef  = lpp_cur_structs[sname]
        if not sdef then error("lpp codegen: unknown struct '"..tostring(sname).."' for '"..node.vname.."'") end
        local fdef
        for i=1,#sdef.fields do
            if sdef.fields[i].name == node.field then fdef = sdef.fields[i]; break end
        end
        if not fdef then error("lpp codegen: no field '"..node.field.."' — did you spell it right?") end
        local tptr = lpp_mktmp("fldptr")
        local fqt  = lpp_basetype_qt(fdef.ftype)
        if is_ptr_access then
            -- self is already a pointer — load it then offset
            local tbase = lpp_mktmp("selfbase")
            lpp_emit(buf, string.format("    %%%s =l loadl %%%s_slot", tbase, node.vname))
            lpp_emit(buf, string.format("    %%%s =l add %%%s, %d", tptr, tbase, fdef.offset))
        else
            lpp_emit(buf, string.format("    %%%s =l add %%%s_slot, %d", tptr, node.vname, fdef.offset))
        end
        if fqt == "d" then
            lpp_emit(buf, string.format("    %%%s =d loadd %%%s", dest, tptr))
        elseif fqt == "l" then
            lpp_emit(buf, string.format("    %%%s =l loadl %%%s", dest, tptr))
        else
            lpp_emit(buf, string.format("    %%%s =w loadw %%%s", dest, tptr))
        end

    elseif k == "uneg" then
        local t = lpp_mktmp("neg")
        lpp_lower_xpr(buf, node.x, t)
        if lpp_is_float_node(node.x) then
            lpp_emit(buf, string.format("    %%%s =d neg %%%s", dest, t))
        else
            lpp_emit(buf, string.format("    %%%s =w sub 0, %%%s", dest, t))
        end

    elseif k == "unot" then
        local t = lpp_mktmp("not")
        lpp_lower_xpr(buf, node.x, t)
        lpp_emit(buf, string.format("    %%%s =w ceqw %%%s, 0", dest, t))

    elseif k == "binop" then
        local op = node.op

        -- AND: short-circuit. if left is false, skip right entirely.
        -- spill result through a stack slot so we can load it after the join.
        if op == "AND" then
            local sp = lpp_mktmp("andspill")
            local r  = lpp_mklbl("and_rhs"); local no = lpp_mklbl("and_no"); local en = lpp_mklbl("and_end")
            lpp_emit(buf, string.format("    %%%s_slot =l alloc4 4", sp))
            local lv = lpp_mktmp("andl"); lpp_lower_xpr(buf, node.lhs, lv)
            lpp_emit(buf, string.format("    jnz %%%s, %s, %s", lv, r, no))
            lpp_emit(buf, r)
            local rv = lpp_mktmp("andr"); local rb = lpp_mktmp("andrbool")
            lpp_lower_xpr(buf, node.rhs, rv)
            lpp_emit(buf, string.format("    %%%s =w csgtw %%%s, 0", rb, rv))
            lpp_emit(buf, string.format("    storew %%%s, %%%s_slot", rb, sp))
            lpp_emit(buf, "    jmp "..en); lpp_emit(buf, no)
            lpp_emit(buf, string.format("    storew 0, %%%s_slot", sp))
            lpp_emit(buf, "    jmp "..en); lpp_emit(buf, en)
            lpp_emit(buf, string.format("    %%%s =w loadw %%%s_slot", dest, sp))
            return
        end

        -- OR: short-circuit. if left is true, skip right.
        if op == "OR" then
            local sp = lpp_mktmp("orspill")
            local r  = lpp_mklbl("or_rhs"); local y = lpp_mklbl("or_yes"); local en = lpp_mklbl("or_end")
            lpp_emit(buf, string.format("    %%%s_slot =l alloc4 4", sp))
            local lv = lpp_mktmp("orl"); lpp_lower_xpr(buf, node.lhs, lv)
            lpp_emit(buf, string.format("    jnz %%%s, %s, %s", lv, y, r))
            lpp_emit(buf, r)
            local rv = lpp_mktmp("orr"); local rb = lpp_mktmp("orrbool")
            lpp_lower_xpr(buf, node.rhs, rv)
            lpp_emit(buf, string.format("    %%%s =w csgtw %%%s, 0", rb, rv))
            lpp_emit(buf, string.format("    storew %%%s, %%%s_slot", rb, sp))
            lpp_emit(buf, "    jmp "..en); lpp_emit(buf, y)
            lpp_emit(buf, string.format("    storew 1, %%%s_slot", sp))
            lpp_emit(buf, "    jmp "..en); lpp_emit(buf, en)
            lpp_emit(buf, string.format("    %%%s =w loadw %%%s_slot", dest, sp))
            return
        end

        -- string concatenation: str + str -> call sb_new, sb_append twice, sb_get
        local function lpp_is_str_node(n)
            if not n then return false end
            if n.kind == "lit_str" then return true end
            if n.kind == "var" then return (lpp_cur_vartypes[n.vname] or lpp_globals[n.vname]) == "str" end
            return false
        end
        if op == "PLUS" and (lpp_is_str_node(node.lhs) or lpp_is_str_node(node.rhs)) then
            local tsb  = lpp_mktmp("sb")
            local tlhs = lpp_mktmp("slhs")
            local trhs = lpp_mktmp("srhs")
            local tr1  = lpp_mktmp("sbr1")
            local tr2  = lpp_mktmp("sbr2")
            lpp_lower_xpr(buf, node.lhs, tlhs)
            lpp_lower_xpr(buf, node.rhs, trhs)
            lpp_emit(buf, string.format("    %%%s =l call $sb_new()", tsb))
            lpp_emit(buf, string.format("    %%%s =l call $sb_append(l %%%s, l %%%s)", tr1, tsb, tlhs))
            lpp_emit(buf, string.format("    %%%s =l call $sb_append(l %%%s, l %%%s)", tr2, tr1, trhs))
            lpp_emit(buf, string.format("    %%%s =l call $sb_get(l %%%s)", dest, tr2))
            return
        end

        -- pick the right opmap based on what types we're dealing with
        local isf = lpp_is_float_node(node.lhs) or lpp_is_float_node(node.rhs)
        local isl = (not isf) and (lpp_is_long_node(node.lhs) or lpp_is_long_node(node.rhs))
        local opmap = isf and lpp_flt_opmap or (isl and lpp_long_opmap or lpp_int_opmap)
        local qi = opmap[op]
        if not qi then error("lpp codegen: no QBE op for '"..op.."' — this shouldn't happen") end

        local lv = lpp_mktmp("boplhs"); local rv = lpp_mktmp("boprhs")
        lpp_lower_xpr(buf, node.lhs, lv)
        lpp_lower_xpr(buf, node.rhs, rv)

        -- comparison ops always produce a w (0 or 1) even when comparing floats or longs
        local is_cmp = op=="EQ" or op=="NEQ" or op=="GT" or op=="LT" or op=="GE" or op=="LE"
        local rtype = is_cmp and "w" or (isf and "d" or (isl and "l" or "w"))
        lpp_emit(buf, string.format("    %%%s =%s %s %%%s, %%%s", dest, rtype, qi, lv, rv))

    elseif k == "call" then
        local lpp_callargs = {}
        for i=1,#node.args do
            local arg = node.args[i]
            local t = lpp_mktmp("callarg")
            lpp_lower_xpr(buf, arg, t)
            -- figure out the QBE type for each argument
            local aqt = "w"
            if arg.kind == "lit_str"   then aqt = "l"
            elseif arg.kind == "lit_float" then aqt = "d"
            elseif arg.kind == "var"   then aqt = lpp_qt_for_var(arg.vname) end
            if aqt == "arr" then aqt = "l" end  -- arrays pass as pointers
            lpp_callargs[#lpp_callargs+1] = aqt.." %"..t
        end
        local lpp_callee = node.fname
        if lpp_callee == "print" then lpp_callee = "print_int" end  -- print is an alias
        -- use the correct return type for this function so we don't store a long into a word slot
        local lpp_call_rqt = lpp_fn_rtypes[lpp_callee] or "w"
        lpp_emit(buf, string.format("    %%%s =%s call $%s(%s)",
            dest, lpp_call_rqt, lpp_callee, table.concat(lpp_callargs, ", ")))

    elseif k == "method_call" then
        -- obj.method(args) -> StructName_method(l &obj, args...)
        -- resolve struct type from vartypes
        local receiver_type = lpp_cur_vartypes[node.receiver] or lpp_globals[node.receiver] or ""
        local sname = receiver_type:match("^struct:(.+)$") or receiver_type
        local callee = sname.."_"..node.method
        local lpp_callargs = {}
        -- first arg: pointer to receiver (its stack slot address, or global address)
        if lpp_globals[node.receiver] then
            lpp_callargs[1] = "l $"..node.receiver
        else
            lpp_callargs[1] = "l %"..node.receiver.."_slot"
        end
        for i=1,#node.args do
            local arg = node.args[i]
            local t = lpp_mktmp("marg")
            lpp_lower_xpr(buf, arg, t)
            local aqt = "w"
            if arg.kind == "lit_str"   then aqt = "l"
            elseif arg.kind == "lit_float" then aqt = "d"
            elseif arg.kind == "var"   then aqt = lpp_qt_for_var(arg.vname) end
            if aqt == "arr" then aqt = "l" end
            lpp_callargs[#lpp_callargs+1] = aqt.." %"..t
        end
        local lpp_call_rqt = lpp_fn_rtypes[callee] or "w"
        lpp_emit(buf, string.format("    %%%s =%s call $%s(%s)",
            dest, lpp_call_rqt, callee, table.concat(lpp_callargs, ", ")))

    else
        error("lpp codegen: unhandled expression kind '"..tostring(k).."' — compiler bug")
    end
end

lpp_lower_stmt = function(buf, s, lpp_brk_lbl, lpp_cont_lbl)
    local k = s.kind

    if k == "decl" then
        -- if there's an initializer, lower it and store to the slot
        -- arrays and structs without an initializer just get their memory, no store needed
        if s.rhs then
            local t = lpp_mktmp("store")
            lpp_lower_xpr(buf, s.rhs, t)
            local qt = lpp_qt_for_var(s.vname)
            if qt == "d" then
                lpp_emit(buf, string.format("    stored %%%s, %%%s_slot", t, s.vname))
            elseif qt == "l" then
                lpp_emit(buf, string.format("    storel %%%s, %%%s_slot", t, s.vname))
            elseif qt ~= "arr" then
                lpp_emit(buf, string.format("    storew %%%s, %%%s_slot", t, s.vname))
            end
        end

    elseif k == "assign" then
        local t = lpp_mktmp("store")
        lpp_lower_xpr(buf, s.rhs, t)
        local qt = lpp_qt_for_var(s.vname)
        if lpp_globals[s.vname] then
            if qt == "d" then
                lpp_emit(buf, string.format("    stored %%%s, $%s", t, s.vname))
            elseif qt == "l" then
                lpp_emit(buf, string.format("    storel %%%s, $%s", t, s.vname))
            else
                lpp_emit(buf, string.format("    storew %%%s, $%s", t, s.vname))
            end
        else
            if qt == "d" then
                lpp_emit(buf, string.format("    stored %%%s, %%%s_slot", t, s.vname))
            elseif qt == "l" then
                lpp_emit(buf, string.format("    storel %%%s, %%%s_slot", t, s.vname))
            else
                lpp_emit(buf, string.format("    storew %%%s, %%%s_slot", t, s.vname))
            end
        end

    elseif k == "arr_set" then
        -- same pointer arithmetic as arr_get but we store instead of load
        local vt = lpp_cur_vartypes[s.vname] or "int[1]"
        local arrbase, arrsz = lpp_parse_arrtype(vt)
        arrbase = arrbase or "int"
        local eqt = lpp_basetype_qt(arrbase)
        local esz = lpp_basetype_sz(arrbase)
        local tidx = lpp_mktmp("arridx"); local toff = lpp_mktmp("arroff")
        local tptr = lpp_mktmp("arrptr"); local tval = lpp_mktmp("arrval")
        lpp_lower_xpr(buf, s.idx, tidx)
        lpp_emit(buf, string.format("    %%%s =l extsw %%%s", toff, tidx))
        lpp_emit(buf, string.format("    %%%s =l mul %%%s, %d", toff, toff, esz))
        if arrsz then
            lpp_emit(buf, string.format("    %%%s =l add %%%s_slot, %%%s", tptr, s.vname, toff))
        else
            local tbase = lpp_mktmp("dynbase")
            lpp_emit(buf, string.format("    %%%s =l loadl %%%s_slot", tbase, s.vname))
            lpp_emit(buf, string.format("    %%%s =l add %%%s, %%%s", tptr, tbase, toff))
        end
        lpp_lower_xpr(buf, s.rhs, tval)
        if eqt == "d" then lpp_emit(buf, string.format("    stored %%%s, %%%s", tval, tptr))
        elseif eqt == "l" then lpp_emit(buf, string.format("    storel %%%s, %%%s", tval, tptr))
        else lpp_emit(buf, string.format("    storew %%%s, %%%s", tval, tptr)) end

    elseif k == "field_set" then
        local qt = lpp_cur_vartypes[s.vname] or ""
        local sname = qt:match("^struct:(.+)$") or qt
        local is_ptr_access = (lpp_cur_vartypes[s.vname] == "long" and lpp_cur_self_struct)
        if is_ptr_access then sname = lpp_cur_self_struct end
        local sdef  = lpp_cur_structs[sname]
        if not sdef then error("lpp codegen: unknown struct for '"..s.vname.."'") end
        local fdef
        for i=1,#sdef.fields do
            if sdef.fields[i].name == s.field then fdef = sdef.fields[i]; break end
        end
        if not fdef then error("lpp codegen: no field '"..s.field.."'") end
        local tptr = lpp_mktmp("fldptr"); local tval = lpp_mktmp("fldval")
        local fqt  = lpp_basetype_qt(fdef.ftype)
        if is_ptr_access then
            local tbase = lpp_mktmp("selfbase")
            lpp_emit(buf, string.format("    %%%s =l loadl %%%s_slot", tbase, s.vname))
            lpp_emit(buf, string.format("    %%%s =l add %%%s, %d", tptr, tbase, fdef.offset))
        else
            lpp_emit(buf, string.format("    %%%s =l add %%%s_slot, %d", tptr, s.vname, fdef.offset))
        end
        lpp_lower_xpr(buf, s.rhs, tval)
        if fqt == "d" then lpp_emit(buf, string.format("    stored %%%s, %%%s", tval, tptr))
        elseif fqt == "l" then lpp_emit(buf, string.format("    storel %%%s, %%%s", tval, tptr))
        else lpp_emit(buf, string.format("    storew %%%s, %%%s", tval, tptr)) end

    elseif k == "xstmt" then
        -- expression statement — evaluate and throw away the result
        lpp_lower_xpr(buf, s.expr, lpp_mktmp("discard"))

    elseif k == "ret" then
        local t = lpp_mktmp("retval")
        lpp_lower_xpr(buf, s.val, t)
        lpp_emit(buf, "    ret %"..t)
        return true  -- signal to stop emitting the block

    elseif k == "brk" then
        if not lpp_brk_lbl then error("lpp: break outside a loop") end
        lpp_emit(buf, "    jmp "..lpp_brk_lbl)
        return true

    elseif k == "cont" then
        if not lpp_cont_lbl then error("lpp: continue outside a loop") end
        lpp_emit(buf, "    jmp "..lpp_cont_lbl)
        return true

    elseif k == "loop" then
        local lc = lpp_mklbl("loopcond"); local lb = lpp_mklbl("loopbody"); local le = lpp_mklbl("loopexit")
        lpp_emit(buf, "    jmp "..lc); lpp_emit(buf, lc)
        local cv = lpp_mktmp("loopcv"); lpp_lower_xpr(buf, s.cond, cv)
        lpp_emit(buf, string.format("    jnz %%%s, %s, %s", cv, lb, le))
        lpp_emit(buf, lb); lpp_lower_block(buf, s.body, le, lc)
        lpp_emit(buf, "    jmp "..lc); lpp_emit(buf, le)

    elseif k == "forloop" then
        -- for i = start, limit [, step]
        -- emit: i_slot = start; loop { if i >= limit break; body; i += step }
        local lc = lpp_mklbl("forcond"); local lb = lpp_mklbl("forbody"); local le = lpp_mklbl("forexit")
        -- init
        local tinit = lpp_mktmp("forinit")
        lpp_lower_xpr(buf, s.start, tinit)
        lpp_emit(buf, string.format("    storew %%%s, %%%s_slot", tinit, s.iname))
        -- condition check
        lpp_emit(buf, "    jmp "..lc); lpp_emit(buf, lc)
        local tiv = lpp_mktmp("foriv"); local tlim = lpp_mktmp("forlim"); local tcmp = lpp_mktmp("forcmp")
        lpp_emit(buf, string.format("    %%%s =w loadw %%%s_slot", tiv, s.iname))
        lpp_lower_xpr(buf, s.limit, tlim)
        lpp_emit(buf, string.format("    %%%s =w csltw %%%s, %%%s", tcmp, tiv, tlim))
        lpp_emit(buf, string.format("    jnz %%%s, %s, %s", tcmp, lb, le))
        lpp_emit(buf, lb)
        -- body (last stmt is the step increment injected by parser)
        lpp_lower_block(buf, s.body, le, lc)
        lpp_emit(buf, "    jmp "..lc); lpp_emit(buf, le)

    elseif k == "ifx" then
        local ly = lpp_mklbl("ifyes"); local ln = lpp_mklbl("ifno"); local ld = lpp_mklbl("ifdone")
        local cv = lpp_mktmp("ifcv"); lpp_lower_xpr(buf, s.cond, cv)
        lpp_emit(buf, string.format("    jnz %%%s, %s, %s", cv, ly, s.no and ln or ld))
        lpp_emit(buf, ly)
        if not lpp_lower_block(buf, s.yes, lpp_brk_lbl, lpp_cont_lbl) then lpp_emit(buf, "    jmp "..ld) end
        if s.no then
            lpp_emit(buf, ln)
            if not lpp_lower_block(buf, s.no, lpp_brk_lbl, lpp_cont_lbl) then lpp_emit(buf, "    jmp "..ld) end
        end
        lpp_emit(buf, ld)

    elseif k == "casex" then
        -- case compiles as a chain of comparisons, not a jump table.
        -- simple and correct. not the fastest for 100+ arms but you're not writing that.
        local ld = lpp_mklbl("casedone")
        local sv = lpp_mktmp("casesub"); lpp_lower_xpr(buf, s.subject, sv)
        for i=1,#s.arms do
            local arm = s.arms[i]
            local lm = lpp_mklbl("casearm"); local ln = lpp_mklbl("casenext")
            local av = lpp_mktmp("casearmval"); lpp_lower_xpr(buf, arm.val, av)
            local cv = lpp_mktmp("casecmp")
            lpp_emit(buf, string.format("    %%%s =w ceqw %%%s, %%%s", cv, sv, av))
            lpp_emit(buf, string.format("    jnz %%%s, %s, %s", cv, lm, ln))
            lpp_emit(buf, lm); lpp_lower_block(buf, arm.body, lpp_brk_lbl, lpp_cont_lbl)
            lpp_emit(buf, "    jmp "..ld); lpp_emit(buf, ln)
        end
        if s.default then lpp_lower_block(buf, s.default, lpp_brk_lbl, lpp_cont_lbl) end
        lpp_emit(buf, "    jmp "..ld); lpp_emit(buf, ld)

    else
        error("lpp codegen: unhandled statement '"..tostring(k).."' — this is a bug, not your fault")
    end
    return false
end

lpp_lower_block = function(buf, block, lpp_brk_lbl, lpp_cont_lbl)
    for i=1,#block.stmts do
        if lpp_lower_stmt(buf, block.stmts[i], lpp_brk_lbl, lpp_cont_lbl) then return true end
    end
    return false
end

-- walk the AST and collect every declared variable name and its type.
-- we do this before emitting any code so we can alloca everything at function entry.
local function lpp_hoist_decls(block, lpp_seen)
    for i=1,#block.stmts do
        local s = block.stmts[i]
        if s.kind == "decl" then
            lpp_seen[s.vname] = s.vtype or "int"
        end
        -- recurse into nested blocks
        if s.kind == "ifx" then
            lpp_hoist_decls(s.yes, lpp_seen)
            if s.no then lpp_hoist_decls(s.no, lpp_seen) end
        elseif s.kind == "loop" then
            lpp_hoist_decls(s.body, lpp_seen)
        elseif s.kind == "forloop" then
            lpp_seen[s.iname] = "int"  -- for loop variable
            lpp_hoist_decls(s.body, lpp_seen)
        elseif s.kind == "casex" then
            for j=1,#s.arms do lpp_hoist_decls(s.arms[j].body, lpp_seen) end
            if s.default then lpp_hoist_decls(s.default, lpp_seen) end
        end
    end
end

local function lpp_lower_func(buf, fn)
    lpp_cur_structs = fn.structs or {}
    lpp_cur_self_struct = fn.impl_struct or nil  -- set for methods, nil for regular functions

    -- build param signatures for QBE
    local lpp_paramsigs = {}
    for i=1,#fn.params do
        local pt = fn.params[i].ptype or "int"
        local qt = lpp_type_qt(pt)
        if qt == "arr" then qt = "l" end  -- arrays pass as pointers
        lpp_paramsigs[i] = qt.." %lpp_p_"..fn.params[i].pname
    end

    -- main() becomes lang_main() so we can wrap it with a real main() in C
    local lpp_export_nm = fn.fname == "main" and "lang_main" or fn.fname
    local lpp_rqt = (fn.rtype == "float") and "d" or (fn.rtype == "long") and "l" or "w"
    lpp_emit(buf, string.format("export function %s $%s(%s) {",
        lpp_rqt, lpp_export_nm, table.concat(lpp_paramsigs, ", ")))
    lpp_emit(buf, "@lpp_entry")

    -- hoist all local declarations to the top of the function
    lpp_cur_vartypes = {}
    lpp_hoist_decls(fn.body, lpp_cur_vartypes)
    -- also include params so we can load them by name
    for i=1,#fn.params do
        lpp_cur_vartypes[fn.params[i].pname] = fn.params[i].ptype or "int"
    end

    -- emit alloca for every variable we found
    for vname, vtype in pairs(lpp_cur_vartypes) do
        local arrbase, arrsz = lpp_parse_arrtype(vtype)
        if arrbase and arrsz then
            -- fixed array: allocate the whole block on the stack
            local esz   = lpp_basetype_sz(arrbase)
            local total = esz * arrsz
            local align = (esz >= 8) and 8 or 4
            lpp_emit(buf, string.format("    %%%s_slot =l alloc%d %d", vname, align, total))
        elseif arrbase and not arrsz then
            -- dynamic array: just a pointer slot, the heap block comes from arr_new()
            lpp_emit(buf, string.format("    %%%s_slot =l alloc8 8", vname))
        elseif lpp_cur_structs[vtype] then
            -- struct: allocate the full struct size
            local sdef = lpp_cur_structs[vtype]
            lpp_emit(buf, string.format("    %%%s_slot =l alloc8 %d", vname, sdef.size))
        else
            local qt = lpp_type_qt(vtype)
            if qt == "d" then
                lpp_emit(buf, string.format("    %%%s_slot =l alloc8 8", vname))
            elseif qt == "l" then
                lpp_emit(buf, string.format("    %%%s_slot =l alloc8 8", vname))
            else
                lpp_emit(buf, string.format("    %%%s_slot =l alloc4 4", vname))
            end
        end
    end

    -- store params into their slots so we can treat them like regular locals
    for i=1,#fn.params do
        local pn = fn.params[i].pname
        local pt = fn.params[i].ptype or "int"
        local qt = lpp_type_qt(pt)
        if qt == "arr" then qt = "l" end
        if qt == "d" then
            lpp_emit(buf, string.format("    stored %%lpp_p_%s, %%%s_slot", pn, pn))
        elseif qt == "l" then
            lpp_emit(buf, string.format("    storel %%lpp_p_%s, %%%s_slot", pn, pn))
        else
            lpp_emit(buf, string.format("    storew %%lpp_p_%s, %%%s_slot", pn, pn))
        end
    end

    -- emit the actual function body
    if not lpp_lower_block(buf, fn.body, nil) then
        lpp_emit(buf, "    ret 0")  -- implicit return 0 if the function falls off the end
    end
    lpp_emit(buf, "}")
end

-- emit all string literals as QBE data sections at the end of the file
local function lpp_emit_data(buf)
    for i=1,#lpp_str_lits do
        local sl = lpp_str_lits[i]
        local escaped = sl.val:gsub('\\', '\\\\'):gsub('"', '\\"')
        lpp_emit(buf, string.format('data $%s = { b "%s", b 0 }', sl.lbl, escaped))
    end
end

local function lpp_codegen(prog)
    lpp_nlabels = 0; lpp_ntemps = 0
    lpp_str_lits = {}; lpp_nstrs = 0
    lpp_cur_structs = prog.structs or {}
    lpp_cur_self_struct = nil

    -- build global variable registry so load/store knows to use $name
    lpp_globals = {}
    for i=1,#(prog.globals or {}) do
        local g = prog.globals[i]
        lpp_globals[g.gname] = g.gtype
    end

    -- build a map of function return types so call expressions emit the right QBE type
    lpp_fn_rtypes = {}
    for i=1,#prog.externs do
        local ex = prog.externs[i]
        lpp_fn_rtypes[ex.fname] = lpp_type_qt(ex.rtype or "int")
    end
    for i=1,#prog.funcs do
        local fn = prog.funcs[i]
        lpp_fn_rtypes[fn.fname] = lpp_type_qt(fn.rtype or "int")
    end

    local buf = {}

    -- emit QBE data sections for global variables
    for i=1,#(prog.globals or {}) do
        local g = prog.globals[i]
        local qt = lpp_type_qt(g.gtype)
        if qt == "d" then
            local v = (g.init and g.init.kind == "lit_float") and tostring(g.init.fval) or "d_0"
            lpp_emit(buf, string.format("data $%s = { d %s }", g.gname, v))
        elseif qt == "l" then
            local v = 0
            if g.init then
                if g.init.kind == "lit_int" then v = g.init.ival
                elseif g.init.kind == "lit_str" then
                    local lbl = lpp_intern_str(g.init.sval)
                    lpp_emit(buf, string.format("data $%s = { l $%s }", g.gname, lbl))
                    v = nil
                end
            end
            if v ~= nil then lpp_emit(buf, string.format("data $%s = { l %d }", g.gname, v)) end
        else
            local v = (g.init and g.init.kind == "lit_int") and g.init.ival or 0
            lpp_emit(buf, string.format("data $%s = { w %d }", g.gname, v))
        end
    end
    if #(prog.globals or {}) > 0 then lpp_emit(buf, "") end

    -- if there are top-level statements, emit them as a synthetic __init function
    local has_toplevel = prog.toplevel_stmts and #prog.toplevel_stmts > 0
    if has_toplevel then
        local init_fn = {
            fname = "__init",
            params = {},
            rtype = "int",
            body = {kind="block", stmts=prog.toplevel_stmts},
            structs = prog.structs or {},
            impl_struct = nil,
        }
        lpp_lower_func(buf, init_fn)
        lpp_emit(buf, "")
    end

    -- check if a user-defined main exists
    local has_main = false
    for i=1,#prog.funcs do
        if prog.funcs[i].fname == "main" then has_main = true; break end
    end

    -- if no main but we have top-level statements, synthesize a main that just calls __init
    if has_toplevel and not has_main then
        local auto_main = {
            fname = "main",
            params = {},
            rtype = "int",
            body = {kind="block", stmts={
                {kind="xstmt", expr={kind="call", fname="__init", args={}}},
                {kind="ret", val={kind="lit_int", ival=0}},
            }},
            structs = prog.structs or {},
            impl_struct = nil,
        }
        lpp_lower_func(buf, auto_main)
        lpp_emit(buf, "")
    end

    for i=1,#prog.funcs do
        local fn = prog.funcs[i]
        -- if this is main and we have top-level statements,
        -- inject a call to __init at the very start of its body
        if fn.fname == "main" and has_toplevel then
            table.insert(fn.body.stmts, 1, {kind="xstmt", expr={kind="call", fname="__init", args={}}})
        end
        lpp_lower_func(buf, fn)
        lpp_emit(buf, "")
    end

    if #lpp_str_lits > 0 then
        lpp_emit(buf, "")
        lpp_emit_data(buf)
    end

    return table.concat(buf, "\n")
end

return lpp_codegen