-- lpp -> QBE IR
--
-- QBE type mapping:
--   int/bool  -> w (32-bit word)
--   float     -> d (64-bit double)
--   str/ptr   -> l (64-bit long)
--   arrays    -> stack block, indexed by pointer arithmetic
--   structs   -> stack block, fields at fixed offsets
--
-- AND/OR short-circuit through spill slots.
-- All locals hoisted to function entry to avoid QBE dominance errors.

local lpp_nlabels  = 0
local lpp_ntemps   = 0
local lpp_str_lits = {}
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

local function lpp_intern_str(s)
    lpp_nstrs = lpp_nstrs+1
    local lbl = "lpp_strlit"..lpp_nstrs
    lpp_str_lits[#lpp_str_lits+1] = {lbl=lbl, val=s}
    return lbl
end

-- parse array type string e.g. "int[10]" -> base="int", size=10
local function lpp_parse_arrtype(vtype)
    local base, sz = vtype:match("^(.+)%[(%d+)%]$")
    if base and sz then return base, tonumber(sz) end
    return nil, nil
end

-- qbe type for a base type string
local function lpp_basetype_qt(t)
    if t == "float" then return "d" end
    if t == "str"   then return "l" end
    return "w"
end

-- element byte size for a base type
local function lpp_basetype_sz(t)
    if t == "float" then return 8 end
    if t == "str"   then return 8 end
    return 4
end

-- int binop -> QBE instruction
local lpp_int_opmap = {
    PLUS="add",  MINUS="sub",  STAR="mul",  SLASH="div",  PCENT="rem",
    EQ="ceqw",   NEQ="cnew",   GT="csgtw",  LT="csltw",
    GE="csgew",  LE="cslew",
}

-- float binop -> QBE instruction
local lpp_flt_opmap = {
    PLUS="add",  MINUS="sub",  STAR="mul",  SLASH="div",
    EQ="ceqd",   NEQ="cned",   GT="cgtd",   LT="cltd",
    GE="cged",   LE="cled",
}

local lpp_lower_xpr, lpp_lower_block, lpp_lower_stmt

-- vartypes: map from varname -> qbe type ("w","d","l","arr:base:sz","struct:Name")
-- structs: map from struct name -> {fields, size}
local lpp_cur_vartypes = {}
local lpp_cur_structs  = {}

local function lpp_qt_for_var(vname)
    return lpp_cur_vartypes[vname] or "w"
end

lpp_lower_xpr = function(buf, node, dest)
    local k = node.kind

    if k == "lit_int" then
        lpp_emit(buf, string.format("    %%%s =w copy %d", dest, node.ival))

    elseif k == "lit_float" then
        lpp_emit(buf, string.format("    %%%s =d copy d_%s", dest, tostring(node.fval)))

    elseif k == "lit_str" then
        local lbl = lpp_intern_str(node.sval)
        lpp_emit(buf, string.format("    %%%s =l copy $%s", dest, lbl))

    elseif k == "var" then
        local qt = lpp_qt_for_var(node.vname)
        if qt == "d" then
            lpp_emit(buf, string.format("    %%%s =d loadd %%%s_slot", dest, node.vname))
        elseif qt == "l" then
            lpp_emit(buf, string.format("    %%%s =l loadl %%%s_slot", dest, node.vname))
        else
            lpp_emit(buf, string.format("    %%%s =w loadw %%%s_slot", dest, node.vname))
        end

    elseif k == "arr_get" then
        -- load element from array: base + idx * elemsize
        local qt = lpp_qt_for_var(node.vname)
        -- qt is "arr:base:sz" — extract base type
        local arrbase = qt:match("^arr:([^:]+)") or "int"
        local eqt  = lpp_basetype_qt(arrbase)
        local esz  = lpp_basetype_sz(arrbase)
        local tidx = lpp_mktmp("arridx")
        local toff = lpp_mktmp("arroff")
        local tptr = lpp_mktmp("arrptr")
        lpp_lower_xpr(buf, node.idx, tidx)
        lpp_emit(buf, string.format("    %%%s =l extsw %%%s", toff, tidx))
        lpp_emit(buf, string.format("    %%%s =l mul %%%s, %d", toff, toff, esz))
        lpp_emit(buf, string.format("    %%%s =l add %%%s_slot, %%%s", tptr, node.vname, toff))
        if eqt == "d" then
            lpp_emit(buf, string.format("    %%%s =d loadd %%%s", dest, tptr))
        elseif eqt == "l" then
            lpp_emit(buf, string.format("    %%%s =l loadl %%%s", dest, tptr))
        else
            lpp_emit(buf, string.format("    %%%s =w loadw %%%s", dest, tptr))
        end

    elseif k == "field_get" then
        -- load struct field: base + field_offset
        local qt = lpp_qt_for_var(node.vname)
        local sname = qt:match("^struct:(.+)$")
        local sdef  = sname and lpp_cur_structs[sname]
        if not sdef then error("lpp codegen: unknown struct for '"..node.vname.."'") end
        local fdef
        for i=1,#sdef.fields do
            if sdef.fields[i].name == node.field then fdef = sdef.fields[i]; break end
        end
        if not fdef then error("lpp codegen: no field '"..node.field.."' in struct") end
        local tptr = lpp_mktmp("fldptr")
        local fqt  = lpp_basetype_qt(fdef.ftype)
        lpp_emit(buf, string.format("    %%%s =l add %%%s_slot, %d", tptr, node.vname, fdef.offset))
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
        local qt = lpp_qt_for_var(node.x.vname or "")
        if qt == "d" or node.x.kind == "lit_float" then
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

        if op == "AND" then
            local lpp_spill   = lpp_mktmp("andspill")
            local lpp_rhs_lbl = lpp_mklbl("and_rhs")
            local lpp_no_lbl  = lpp_mklbl("and_no")
            local lpp_end_lbl = lpp_mklbl("and_end")
            lpp_emit(buf, string.format("    %%%s_slot =l alloc4 4", lpp_spill))
            local lv = lpp_mktmp("andl")
            lpp_lower_xpr(buf, node.lhs, lv)
            lpp_emit(buf, string.format("    jnz %%%s, %s, %s", lv, lpp_rhs_lbl, lpp_no_lbl))
            lpp_emit(buf, lpp_rhs_lbl)
            local rv = lpp_mktmp("andr"); local rb = lpp_mktmp("andrbool")
            lpp_lower_xpr(buf, node.rhs, rv)
            lpp_emit(buf, string.format("    %%%s =w csgtw %%%s, 0", rb, rv))
            lpp_emit(buf, string.format("    storew %%%s, %%%s_slot", rb, lpp_spill))
            lpp_emit(buf, "    jmp "..lpp_end_lbl)
            lpp_emit(buf, lpp_no_lbl)
            lpp_emit(buf, string.format("    storew 0, %%%s_slot", lpp_spill))
            lpp_emit(buf, "    jmp "..lpp_end_lbl)
            lpp_emit(buf, lpp_end_lbl)
            lpp_emit(buf, string.format("    %%%s =w loadw %%%s_slot", dest, lpp_spill))
            return
        end

        if op == "OR" then
            local lpp_spill   = lpp_mktmp("orspill")
            local lpp_rhs_lbl = lpp_mklbl("or_rhs")
            local lpp_yes_lbl = lpp_mklbl("or_yes")
            local lpp_end_lbl = lpp_mklbl("or_end")
            lpp_emit(buf, string.format("    %%%s_slot =l alloc4 4", lpp_spill))
            local lv = lpp_mktmp("orl")
            lpp_lower_xpr(buf, node.lhs, lv)
            lpp_emit(buf, string.format("    jnz %%%s, %s, %s", lv, lpp_yes_lbl, lpp_rhs_lbl))
            lpp_emit(buf, lpp_rhs_lbl)
            local rv = lpp_mktmp("orr"); local rb = lpp_mktmp("orrbool")
            lpp_lower_xpr(buf, node.rhs, rv)
            lpp_emit(buf, string.format("    %%%s =w csgtw %%%s, 0", rb, rv))
            lpp_emit(buf, string.format("    storew %%%s, %%%s_slot", rb, lpp_spill))
            lpp_emit(buf, "    jmp "..lpp_end_lbl)
            lpp_emit(buf, lpp_yes_lbl)
            lpp_emit(buf, string.format("    storew 1, %%%s_slot", lpp_spill))
            lpp_emit(buf, "    jmp "..lpp_end_lbl)
            lpp_emit(buf, lpp_end_lbl)
            lpp_emit(buf, string.format("    %%%s =w loadw %%%s_slot", dest, lpp_spill))
            return
        end

        -- figure out if either side is float
        local function lpp_is_float_node(n)
            if n.kind == "lit_float" then return true end
            if n.kind == "var" then return lpp_qt_for_var(n.vname) == "d" end
            if n.kind == "binop" then return lpp_is_float_node(n.lhs) or lpp_is_float_node(n.rhs) end
            return false
        end
        local isf = lpp_is_float_node(node.lhs) or lpp_is_float_node(node.rhs)

        local opmap = isf and lpp_flt_opmap or lpp_int_opmap
        local qi = opmap[op]
        if not qi then error("lpp codegen: no QBE op for '"..op.."'") end

        local lv = lpp_mktmp("boplhs"); local rv = lpp_mktmp("boprhs")
        lpp_lower_xpr(buf, node.lhs, lv)
        lpp_lower_xpr(buf, node.rhs, rv)

        -- comparisons always return w even for floats
        local is_cmp = op=="EQ" or op=="NEQ" or op=="GT" or op=="LT" or op=="GE" or op=="LE"
        local rtype = is_cmp and "w" or (isf and "d" or "w")
        lpp_emit(buf, string.format("    %%%s =%s %s %%%s, %%%s", dest, rtype, qi, lv, rv))

    elseif k == "call" then
        local lpp_callargs = {}
        for i=1,#node.args do
            local arg = node.args[i]
            local t = lpp_mktmp("callarg")
            lpp_lower_xpr(buf, arg, t)
            -- determine arg qbe type
            local aqt = "w"
            if arg.kind == "lit_str" then aqt = "l"
            elseif arg.kind == "lit_float" then aqt = "d"
            elseif arg.kind == "var" then aqt = lpp_qt_for_var(arg.vname) end
            lpp_callargs[#lpp_callargs+1] = aqt.." %"..t
        end
        local lpp_callee = node.fname
        if lpp_callee == "print" then lpp_callee = "print_int" end
        lpp_emit(buf, string.format("    %%%s =w call $%s(%s)",
            dest, lpp_callee, table.concat(lpp_callargs, ", ")))

    else
        error("lpp codegen: unhandled expr '"..tostring(k).."'")
    end
end

lpp_lower_stmt = function(buf, s, lpp_brk_lbl)
    local k = s.kind

    if k == "decl" then
        if s.rhs then
            local t = lpp_mktmp("store")
            lpp_lower_xpr(buf, s.rhs, t)
            local qt = lpp_cur_vartypes[s.vname] or "w"
            if qt == "d" then
                lpp_emit(buf, string.format("    stored %%%s, %%%s_slot", t, s.vname))
            elseif qt == "l" then
                lpp_emit(buf, string.format("    storel %%%s, %%%s_slot", t, s.vname))
            elseif qt:match("^arr:") or qt:match("^struct:") then
                -- no store for arrays/structs on decl without initializer
            else
                lpp_emit(buf, string.format("    storew %%%s, %%%s_slot", t, s.vname))
            end
        end

    elseif k == "assign" then
        local t = lpp_mktmp("store")
        lpp_lower_xpr(buf, s.rhs, t)
        local qt = lpp_cur_vartypes[s.vname] or "w"
        if qt == "d" then
            lpp_emit(buf, string.format("    stored %%%s, %%%s_slot", t, s.vname))
        elseif qt == "l" then
            lpp_emit(buf, string.format("    storel %%%s, %%%s_slot", t, s.vname))
        else
            lpp_emit(buf, string.format("    storew %%%s, %%%s_slot", t, s.vname))
        end

    elseif k == "arr_set" then
        local qt = lpp_cur_vartypes[s.vname] or "arr:int:0"
        local arrbase = qt:match("^arr:([^:]+)") or "int"
        local eqt = lpp_basetype_qt(arrbase)
        local esz = lpp_basetype_sz(arrbase)
        local tidx = lpp_mktmp("arridx")
        local toff = lpp_mktmp("arroff")
        local tptr = lpp_mktmp("arrptr")
        local tval = lpp_mktmp("arrval")
        lpp_lower_xpr(buf, s.idx, tidx)
        lpp_emit(buf, string.format("    %%%s =l extsw %%%s", toff, tidx))
        lpp_emit(buf, string.format("    %%%s =l mul %%%s, %d", toff, toff, esz))
        lpp_emit(buf, string.format("    %%%s =l add %%%s_slot, %%%s", tptr, s.vname, toff))
        lpp_lower_xpr(buf, s.rhs, tval)
        if eqt == "d" then
            lpp_emit(buf, string.format("    stored %%%s, %%%s", tval, tptr))
        elseif eqt == "l" then
            lpp_emit(buf, string.format("    storel %%%s, %%%s", tval, tptr))
        else
            lpp_emit(buf, string.format("    storew %%%s, %%%s", tval, tptr))
        end

    elseif k == "field_set" then
        local qt = lpp_cur_vartypes[s.vname] or ""
        local sname = qt:match("^struct:(.+)$")
        local sdef  = sname and lpp_cur_structs[sname]
        if not sdef then error("lpp codegen: unknown struct for '"..s.vname.."'") end
        local fdef
        for i=1,#sdef.fields do
            if sdef.fields[i].name == s.field then fdef = sdef.fields[i]; break end
        end
        if not fdef then error("lpp codegen: no field '"..s.field.."'") end
        local tptr = lpp_mktmp("fldptr")
        local tval = lpp_mktmp("fldval")
        local fqt  = lpp_basetype_qt(fdef.ftype)
        lpp_emit(buf, string.format("    %%%s =l add %%%s_slot, %d", tptr, s.vname, fdef.offset))
        lpp_lower_xpr(buf, s.rhs, tval)
        if fqt == "d" then
            lpp_emit(buf, string.format("    stored %%%s, %%%s", tval, tptr))
        elseif fqt == "l" then
            lpp_emit(buf, string.format("    storel %%%s, %%%s", tval, tptr))
        else
            lpp_emit(buf, string.format("    storew %%%s, %%%s", tval, tptr))
        end

    elseif k == "xstmt" then
        lpp_lower_xpr(buf, s.expr, lpp_mktmp("discard"))

    elseif k == "ret" then
        local t = lpp_mktmp("retval")
        lpp_lower_xpr(buf, s.val, t)
        lpp_emit(buf, "    ret %"..t)
        return true

    elseif k == "brk" then
        if not lpp_brk_lbl then error("lpp: break outside loop") end
        lpp_emit(buf, "    jmp "..lpp_brk_lbl)
        return true

    elseif k == "loop" then
        local lpp_cond_lbl = lpp_mklbl("loopcond")
        local lpp_body_lbl = lpp_mklbl("loopbody")
        local lpp_exit_lbl = lpp_mklbl("loopexit")
        lpp_emit(buf, "    jmp "..lpp_cond_lbl)
        lpp_emit(buf, lpp_cond_lbl)
        local cv = lpp_mktmp("loopcv")
        lpp_lower_xpr(buf, s.cond, cv)
        lpp_emit(buf, string.format("    jnz %%%s, %s, %s", cv, lpp_body_lbl, lpp_exit_lbl))
        lpp_emit(buf, lpp_body_lbl)
        lpp_lower_block(buf, s.body, lpp_exit_lbl)
        lpp_emit(buf, "    jmp "..lpp_cond_lbl)
        lpp_emit(buf, lpp_exit_lbl)

    elseif k == "ifx" then
        local lpp_yes_lbl  = lpp_mklbl("ifyes")
        local lpp_no_lbl   = lpp_mklbl("ifno")
        local lpp_done_lbl = lpp_mklbl("ifdone")
        local cv = lpp_mktmp("ifcv")
        lpp_lower_xpr(buf, s.cond, cv)
        lpp_emit(buf, string.format("    jnz %%%s, %s, %s",
            cv, lpp_yes_lbl, s.no and lpp_no_lbl or lpp_done_lbl))
        lpp_emit(buf, lpp_yes_lbl)
        if not lpp_lower_block(buf, s.yes, lpp_brk_lbl) then
            lpp_emit(buf, "    jmp "..lpp_done_lbl)
        end
        if s.no then
            lpp_emit(buf, lpp_no_lbl)
            if not lpp_lower_block(buf, s.no, lpp_brk_lbl) then
                lpp_emit(buf, "    jmp "..lpp_done_lbl)
            end
        end
        lpp_emit(buf, lpp_done_lbl)

    elseif k == "casex" then
        -- compile as a chain of if/else comparisons jumping to a shared done label
        local lpp_done_lbl = lpp_mklbl("casedone")
        local sv = lpp_mktmp("casesub")
        lpp_lower_xpr(buf, s.subject, sv)
        for i=1,#s.arms do
            local arm = s.arms[i]
            local lpp_match_lbl = lpp_mklbl("casearm")
            local lpp_next_lbl  = lpp_mklbl("casenext")
            local av = lpp_mktmp("casearmval")
            lpp_lower_xpr(buf, arm.val, av)
            local cv = lpp_mktmp("casecmp")
            lpp_emit(buf, string.format("    %%%s =w ceqw %%%s, %%%s", cv, sv, av))
            lpp_emit(buf, string.format("    jnz %%%s, %s, %s", cv, lpp_match_lbl, lpp_next_lbl))
            lpp_emit(buf, lpp_match_lbl)
            lpp_lower_block(buf, arm.body, lpp_brk_lbl)
            lpp_emit(buf, "    jmp "..lpp_done_lbl)
            lpp_emit(buf, lpp_next_lbl)
        end
        if s.default then
            lpp_lower_block(buf, s.default, lpp_brk_lbl)
        end
        lpp_emit(buf, "    jmp "..lpp_done_lbl)
        lpp_emit(buf, lpp_done_lbl)

    else
        error("lpp codegen: unhandled stmt '"..tostring(k).."'")
    end
    return false
end

lpp_lower_block = function(buf, block, lpp_brk_lbl)
    for i=1,#block.stmts do
        if lpp_lower_stmt(buf, block.stmts[i], lpp_brk_lbl) then return true end
    end
    return false
end

-- hoist all declared variable names + infer their qbe types
local function lpp_hoist_decls(block, lpp_seen)
    for i=1,#block.stmts do
        local s = block.stmts[i]
        if s.kind == "decl" then
            local vtype = s.vtype or "int"
            local arrbase, arrsz = lpp_parse_arrtype(vtype)
            if arrbase then
                lpp_seen[s.vname] = "arr:"..arrbase..":"..arrsz
            elseif lpp_cur_structs[vtype] then
                lpp_seen[s.vname] = "struct:"..vtype
            elseif vtype == "float" then
                lpp_seen[s.vname] = "d"
            elseif vtype == "str" then
                lpp_seen[s.vname] = "l"
            else
                -- infer from rhs if no explicit type says float
                if s.rhs and s.rhs.kind == "lit_float" then
                    lpp_seen[s.vname] = "d"
                else
                    lpp_seen[s.vname] = "w"
                end
            end
        end
        if s.kind == "ifx" then
            lpp_hoist_decls(s.yes, lpp_seen)
            if s.no then lpp_hoist_decls(s.no, lpp_seen) end
        elseif s.kind == "loop" then
            lpp_hoist_decls(s.body, lpp_seen)
        elseif s.kind == "casex" then
            for j=1,#s.arms do lpp_hoist_decls(s.arms[j].body, lpp_seen) end
            if s.default then lpp_hoist_decls(s.default, lpp_seen) end
        end
    end
end

local function lpp_lower_func(buf, fn)
    -- set up struct context for this function
    lpp_cur_structs = fn.structs or {}

    local lpp_paramsigs = {}
    for i=1,#fn.params do
        local pt = fn.params[i].ptype or "int"
        local qt = lpp_basetype_qt(pt)
        lpp_paramsigs[i] = qt.." %lpp_p_"..fn.params[i].pname
    end

    local lpp_export_nm = fn.fname == "main" and "lang_main" or fn.fname
    local lpp_rqt = (fn.rtype == "float") and "d" or "w"
    lpp_emit(buf, string.format("export function %s $%s(%s) {",
        lpp_rqt, lpp_export_nm, table.concat(lpp_paramsigs, ", ")))
    lpp_emit(buf, "@lpp_entry")

    -- hoist all locals
    lpp_cur_vartypes = {}
    lpp_hoist_decls(fn.body, lpp_cur_vartypes)
    for i=1,#fn.params do
        local pt = fn.params[i].ptype or "int"
        lpp_cur_vartypes[fn.params[i].pname] = lpp_basetype_qt(pt)
    end

    -- alloca for each variable
    for vname, qt in pairs(lpp_cur_vartypes) do
        local arrbase, arrsz = qt:match("^arr:([^:]+):(%d+)$")
        if arrbase and arrsz then
            local esz = lpp_basetype_sz(arrbase)
            local total = esz * tonumber(arrsz)
            lpp_emit(buf, string.format("    %%%s_slot =l alloc%d %d", vname, esz, total))
        elseif qt:match("^struct:") then
            local sname = qt:match("^struct:(.+)$")
            local sdef  = lpp_cur_structs[sname]
            if sdef then
                lpp_emit(buf, string.format("    %%%s_slot =l alloc8 %d", vname, sdef.size))
            end
        elseif qt == "d" then
            lpp_emit(buf, string.format("    %%%s_slot =l alloc8 8", vname))
        elseif qt == "l" then
            lpp_emit(buf, string.format("    %%%s_slot =l alloc8 8", vname))
        else
            lpp_emit(buf, string.format("    %%%s_slot =l alloc4 4", vname))
        end
    end

    -- store params into slots
    for i=1,#fn.params do
        local pn = fn.params[i].pname
        local qt = lpp_cur_vartypes[pn] or "w"
        if qt == "d" then
            lpp_emit(buf, string.format("    stored %%lpp_p_%s, %%%s_slot", pn, pn))
        elseif qt == "l" then
            lpp_emit(buf, string.format("    storel %%lpp_p_%s, %%%s_slot", pn, pn))
        else
            lpp_emit(buf, string.format("    storew %%lpp_p_%s, %%%s_slot", pn, pn))
        end
    end

    if not lpp_lower_block(buf, fn.body, nil) then lpp_emit(buf, "    ret 0") end
    lpp_emit(buf, "}")
end

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
    local buf = {}

    for i=1,#prog.funcs do
        lpp_lower_func(buf, prog.funcs[i])
        lpp_emit(buf, "")
    end

    if #lpp_str_lits > 0 then
        lpp_emit(buf, "")
        lpp_emit_data(buf)
    end

    return table.concat(buf, "\n")
end

return lpp_codegen
