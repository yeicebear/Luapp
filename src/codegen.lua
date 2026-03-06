-- lpp -> QBE IR
--
-- QBE's simple backend has no phi nodes, so AND/OR short-circuit
-- by spilling through a stack slot and loading after the join label.
-- all locals get alloca'd at function entry regardless of where they
-- appear in source — sidesteps dominance complaints from QBE.

local lpp_nlabels = 0
local lpp_ntemps  = 0

local function lpp_mklbl(hint)
    lpp_nlabels = lpp_nlabels+1
    return "@lpp_"..hint..lpp_nlabels
end

local function lpp_mktmp(hint)
    lpp_ntemps = lpp_ntemps+1
    return "lpp_"..hint..lpp_ntemps
end

local function lpp_emit(buf, line) buf[#buf+1] = line end

-- AST binop tag -> QBE instruction
local lpp_opmap = {
    PLUS="add",  MINUS="sub",  STAR="mul",  SLASH="div",  PCENT="rem",
    EQ="ceqw",   NEQ="cnew",   GT="csgtw",  LT="csltw",
    GE="csgew",  LE="cslew",
}

local lpp_lower_xpr, lpp_lower_block

lpp_lower_xpr = function(buf, node, dest)
    local k = node.kind

    if k == "lit_int" then
        lpp_emit(buf, string.format("    %%%s =w copy %d", dest, node.ival))

    elseif k == "var" then
        lpp_emit(buf, string.format("    %%%s =w loadw %%%s_slot", dest, node.vname))

    elseif k == "uneg" then
        local t = lpp_mktmp("neg")
        lpp_lower_xpr(buf, node.x, t)
        lpp_emit(buf, string.format("    %%%s =w sub 0, %%%s", dest, t))

    elseif k == "unot" then
        local t = lpp_mktmp("not")
        lpp_lower_xpr(buf, node.x, t)
        lpp_emit(buf, string.format("    %%%s =w ceqw %%%s, 0", dest, t))

    elseif k == "binop" then
        local op = node.op

        if op == "AND" then
            -- lhs false -> skip rhs, result=0. lhs true -> result=(rhs!=0)
            local lpp_spill = lpp_mktmp("andspill")
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
            -- lhs true -> skip rhs, result=1. lhs false -> result=(rhs!=0)
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

        local qi = lpp_opmap[op]
        if not qi then error("lpp codegen: no QBE op for '"..op.."'") end
        local lv = lpp_mktmp("boplhs"); local rv = lpp_mktmp("boprhs")
        lpp_lower_xpr(buf, node.lhs, lv)
        lpp_lower_xpr(buf, node.rhs, rv)
        lpp_emit(buf, string.format("    %%%s =w %s %%%s, %%%s", dest, qi, lv, rv))

    elseif k == "call" then
        local lpp_callargs = {}
        for i=1,#node.args do
            local t = lpp_mktmp("callarg")
            lpp_lower_xpr(buf, node.args[i], t)
            lpp_callargs[#lpp_callargs+1] = "w %"..t
        end
        local lpp_callee = node.fname == "print" and "print_int" or node.fname
        lpp_emit(buf, string.format("    %%%s =w call $%s(%s)",
            dest, lpp_callee, table.concat(lpp_callargs, ", ")))

    else
        error("lpp codegen: lpp_lower_xpr unhandled kind '"..tostring(k).."'")
    end
end

local function lpp_lower_stmt(buf, s, lpp_brk_lbl)
    local k = s.kind

    if k == "decl" or k == "assign" then
        local t = lpp_mktmp("store")
        lpp_lower_xpr(buf, s.rhs, t)
        lpp_emit(buf, string.format("    storew %%%s, %%%s_slot", t, s.vname))

    elseif k == "xstmt" then
        lpp_lower_xpr(buf, s.expr, lpp_mktmp("discard"))

    elseif k == "ret" then
        local t = lpp_mktmp("retval")
        lpp_lower_xpr(buf, s.val, t)
        lpp_emit(buf, "    ret %"..t)
        return true

    elseif k == "brk" then
        if not lpp_brk_lbl then error("lpp: break outside a while loop") end
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

    else
        error("lpp codegen: lpp_lower_stmt unhandled kind '"..tostring(k).."'")
    end
    return false
end

lpp_lower_block = function(buf, block, lpp_brk_lbl)
    for i=1,#block.stmts do
        if lpp_lower_stmt(buf, block.stmts[i], lpp_brk_lbl) then return true end
    end
    return false
end

-- walk the whole function body and collect every variable name that gets
-- written to, so we can alloca all of them up at @entry
local function lpp_hoist_decls(block, lpp_seen)
    for i=1,#block.stmts do
        local s = block.stmts[i]
        if s.kind == "decl" or s.kind == "assign" then lpp_seen[s.vname] = true end
        if s.kind == "ifx" then
            lpp_hoist_decls(s.yes, lpp_seen)
            if s.no then lpp_hoist_decls(s.no, lpp_seen) end
        elseif s.kind == "loop" then
            lpp_hoist_decls(s.body, lpp_seen)
        end
    end
end

local function lpp_lower_func(buf, fn)
    local lpp_paramsigs = {}
    for i=1,#fn.params do
        lpp_paramsigs[i] = "w %lpp_p_"..fn.params[i].pname
    end

    local lpp_export_nm = fn.fname == "main" and "lang_main" or fn.fname
    lpp_emit(buf, string.format("export function w $%s(%s) {",
        lpp_export_nm, table.concat(lpp_paramsigs, ", ")))
    lpp_emit(buf, "@lpp_entry")

    local lpp_allvars = {}
    lpp_hoist_decls(fn.body, lpp_allvars)
    for i=1,#fn.params do lpp_allvars[fn.params[i].pname] = true end

    for vname in pairs(lpp_allvars) do
        lpp_emit(buf, string.format("    %%%s_slot =l alloc4 4", vname))
    end
    for i=1,#fn.params do
        local pn = fn.params[i].pname
        lpp_emit(buf, string.format("    storew %%lpp_p_%s, %%%s_slot", pn, pn))
    end

    if not lpp_lower_block(buf, fn.body, nil) then lpp_emit(buf, "    ret 0") end
    lpp_emit(buf, "}")
end

local function lpp_codegen(prog)
    lpp_nlabels = 0; lpp_ntemps = 0
    local buf = {}
    for i=1,#prog.funcs do
        lpp_lower_func(buf, prog.funcs[i])
        lpp_emit(buf, "")
    end
    return table.concat(buf, "\n")
end

return lpp_codegen