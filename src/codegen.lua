-- codegen.lua  |  sector_8:ir_emit
-- walks the ast and writes qbe il text.
-- qbe handles register allocation, abi, and machine selection.
-- our job: bookkeeping, type routing, and spill slots.
--
-- qbe type legend:
--   w = 32-bit word     (int, bool, char)
--   l = 64-bit integer  (long, str, any pointer)
--   d = 64-bit double   (float — qbe has no f32)
--
-- all locals are alloca'd at function entry regardless of declaration site.
-- short-circuit && / || spill through a stack slot; no phi nodes.

local n_labels      = 0
local n_temps       = 0
local interned_strs = {}
local n_strs        = 0

local function fresh_label(tag)   n_labels = n_labels+1; return "@ir_"..tag..n_labels  end
local function fresh_tmp(tag)     n_temps  = n_temps+1;  return "ir_"..tag..n_temps    end
local function push_line(buf, ln) buf[#buf+1] = ln                                      end

local function die_at(msg, node)
    local ln = node and node.line
    error(ln and ("lpp: line "..ln..": "..msg) or ("lpp: "..msg))
end

local function intern_str_literal(raw)
    n_strs = n_strs+1
    local lbl = "strlit_"..n_strs
    interned_strs[#interned_strs+1] = {lbl=lbl, val=raw}
    return lbl
end

local function qbe_type_of(decl_type)
    if not decl_type                   then return "w"   end
    if decl_type == "float"            then return "d"   end
    if decl_type == "str"              then return "l"   end
    if decl_type == "long"             then return "l"   end
    if decl_type == "char"             then return "w"   end
    if decl_type:match("%[%]$")        then return "l"   end
    if decl_type:match("%[%d+%]$")     then return "arr" end
    return "w"
end

local function scalar_byte_size(t)
    if t == "float" then return 8 end
    if t == "str"   then return 8 end
    if t == "long"  then return 8 end
    if t == "char"  then return 1 end
    return 4
end

local function scalar_qtype(t)
    if t == "float" then return "d" end
    if t == "str"   then return "l" end
    if t == "long"  then return "l" end
    return "w"
end

local function split_array_type(vtype)
    local base, sz = vtype:match("^(.+)%[(%d+)%]$")
    if base and sz then return base, tonumber(sz) end
    local dyn = vtype:match("^(.+)%[%]$")
    if dyn then return dyn, nil end
    return nil, nil
end

local int_ops = {
    PLUS="add",  MINUS="sub",  STAR="mul",  SLASH="div",  PCENT="rem",
    EQ="ceqw",   NEQ="cnew",   GT="csgtw",  LT="csltw",
    GE="csgew",  LE="cslew",
    AMP="and",   PIPE="or",    CARET="xor", SHL="shl",    SHR="sar",
}
local float_ops = {
    PLUS="add",  MINUS="sub",  STAR="mul",  SLASH="div",
    EQ="ceqd",   NEQ="cned",   GT="cgtd",   LT="cltd",
    GE="cged",   LE="cled",
}
local long_ops = {
    PLUS="add",  MINUS="sub",  STAR="mul",  SLASH="div",  PCENT="rem",
    EQ="ceql",   NEQ="cnel",   GT="csgtl",  LT="csltl",
    GE="csgel",  LE="cslel",
    AMP="and",   PIPE="or",    CARET="xor", SHL="shl",    SHR="sar",
}

local cur_vartypes    = {}
local cur_structs     = {}
local fn_return_types = {}
local global_types    = {}
local cur_self_struct = nil

local function var_qtype(vname)
    local t = cur_vartypes[vname] or global_types[vname]
    return t and qbe_type_of(t) or "w"
end

-- sector_8:type_inference
-- is_float_node and node_qtype are mutually recursive.
-- forward-declare is_float_node, assign body after node_qtype exists.
local is_float_node

local function node_qtype(n)
    if not n then return "w" end
    local k = n.kind
    if k == "lit_float" then return "d" end
    if k == "lit_str"   then return "l" end
    if k == "lit_int"   then
        return (n.ival > 2147483647 or n.ival < -2147483648) and "l" or "w"
    end
    if k == "var" then
        local qt = var_qtype(n.vname)
        return qt == "arr" and "l" or qt
    end
    if k == "arr_get" then
        local vt   = cur_vartypes[n.vname] or "int[1]"
        local base = vt:match("^(.+)%[%d+%]$") or vt:match("^(.+)%[%]$") or "int"
        return scalar_qtype(base)
    end
    if k == "field_get" then
        local raw   = cur_vartypes[n.vname] or ""
        local sname = raw:match("^struct:(.+)$") or raw
        if cur_self_struct and cur_vartypes[n.vname] == "long" then sname = cur_self_struct end
        local sdef  = cur_structs[sname]
        if sdef then
            for _, f in ipairs(sdef.fields) do
                if f.name == n.field then return scalar_qtype(f.ftype) end
            end
        end
        return "w"
    end
    if k == "call" then
        local fname = n.fname == "print" and "print_int" or n.fname
        return fn_return_types[fname] or "w"
    end
    if k == "method_call" then
        local recv  = cur_vartypes[n.receiver] or global_types[n.receiver] or ""
        local sname = recv:match("^struct:(.+)$") or recv
        return fn_return_types[sname.."_"..n.method] or "w"
    end
    if k == "binop" then
        local op     = n.op
        local is_cmp = op=="EQ" or op=="NEQ" or op=="GT" or op=="LT" or op=="GE" or op=="LE"
        if is_cmp then return "w" end
        local function is_str_val(x)
            if not x then return false end
            if x.kind == "lit_str" then return true end
            if x.kind == "var" then return (cur_vartypes[x.vname] or global_types[x.vname]) == "str" end
            return false
        end
        if op == "PLUS" and (is_str_val(n.lhs) or is_str_val(n.rhs)) then return "l" end
        if is_float_node(n.lhs) or is_float_node(n.rhs)              then return "d" end
        if cur_vartypes[(n.lhs.vname or "")] == "long"
        or cur_vartypes[(n.rhs.vname or "")] == "long"                then return "l" end
        return "w"
    end
    if k == "uneg" then return node_qtype(n.x) end
    if k == "unot" then return "w" end
    return "w"
end

is_float_node = function(n)
    if not n then return false end
    if n.kind == "lit_float" then return true end
    if n.kind == "var"       then return var_qtype(n.vname) == "d" end
    if n.kind == "uneg"      then return is_float_node(n.x) end
    if n.kind == "binop"     then return is_float_node(n.lhs) or is_float_node(n.rhs) end
    if n.kind == "field_get" or n.kind == "call"
    or n.kind == "method_call" or n.kind == "arr_get" then
        return node_qtype(n) == "d"
    end
    return false
end

local function is_long_node(n)
    if not n then return false end
    if n.kind == "var"   then return cur_vartypes[n.vname] == "long" end
    if n.kind == "binop" then return is_long_node(n.lhs) or is_long_node(n.rhs) end
    return false
end

-- sector_8:xpr_emit
local emit_xpr, emit_block, emit_stmt

emit_xpr = function(buf, node, dest)
    local k = node.kind

    if k == "lit_int" then
        if node.ival > 2147483647 or node.ival < -2147483648 then
            push_line(buf, string.format("    %%%s =l copy %d", dest, node.ival))
        else
            push_line(buf, string.format("    %%%s =w copy %d", dest, node.ival))
        end

    elseif k == "lit_float" then
        push_line(buf, string.format("    %%%s =d copy d_%s", dest, tostring(node.fval)))

    elseif k == "lit_str" then
        push_line(buf, string.format("    %%%s =l copy $%s", dest, intern_str_literal(node.sval)))

    elseif k == "var" then
        local qt = var_qtype(node.vname)
        if global_types[node.vname] then
            if     qt=="d" then push_line(buf, string.format("    %%%s =d loadd $%s", dest, node.vname))
            elseif qt=="l" then push_line(buf, string.format("    %%%s =l loadl $%s", dest, node.vname))
            else                push_line(buf, string.format("    %%%s =w loadw $%s", dest, node.vname))
            end
        else
            if     qt=="d" then push_line(buf, string.format("    %%%s =d loadd %%%s_slot", dest, node.vname))
            elseif qt=="l" then push_line(buf, string.format("    %%%s =l loadl %%%s_slot", dest, node.vname))
            else                push_line(buf, string.format("    %%%s =w loadw %%%s_slot", dest, node.vname))
            end
        end

    elseif k == "arr_get" then
        local vt = cur_vartypes[node.vname] or global_types[node.vname] or "int[1]"
        if vt == "long" then vt = "int[]" end
        local base, fixed_sz = split_array_type(vt)
        base          = base or "int"
        local elem_qt = scalar_qtype(base)
        local elem_sz = scalar_byte_size(base)
        local t_idx   = fresh_tmp("idx")
        local t_off   = fresh_tmp("off")
        local t_ptr   = fresh_tmp("ptr")
        emit_xpr(buf, node.idx, t_idx)
        push_line(buf, string.format("    %%%s =l extsw %%%s",    t_off, t_idx))
        push_line(buf, string.format("    %%%s =l mul %%%s, %d",  t_off, t_off, elem_sz))
        if fixed_sz then
            push_line(buf, string.format("    %%%s =l add %%%s_slot, %%%s", t_ptr, node.vname, t_off))
        else
            local t_base = fresh_tmp("base")
            push_line(buf, string.format("    %%%s =l loadl %%%s_slot", t_base, node.vname))
            push_line(buf, string.format("    %%%s =l add %%%s, %%%s",   t_ptr, t_base, t_off))
        end
        if     elem_qt=="d" then push_line(buf, string.format("    %%%s =d loadd %%%s", dest, t_ptr))
        elseif elem_qt=="l" then push_line(buf, string.format("    %%%s =l loadl %%%s", dest, t_ptr))
        else                     push_line(buf, string.format("    %%%s =w loadw %%%s", dest, t_ptr))
        end

    elseif k == "field_get" then
        local raw    = cur_vartypes[node.vname] or ""
        local sname  = raw:match("^struct:(.+)$") or raw
        local via_ptr = cur_vartypes[node.vname] == "long" and cur_self_struct
        if via_ptr then sname = cur_self_struct end
        local sdef = cur_structs[sname]
        if not sdef then die_at("'"..node.vname.."' type '"..tostring(sname).."' unknown struct", node) end
        local fdef
        for _, f in ipairs(sdef.fields) do if f.name == node.field then fdef = f; break end end
        if not fdef then
            local names = {}
            for _, f in ipairs(sdef.fields) do names[#names+1] = f.name end
            die_at("no field '"..node.field.."' on '"..sname.."' — have: "..table.concat(names,", "), node)
        end
        local t_ptr = fresh_tmp("fptr")
        local fqt   = scalar_qtype(fdef.ftype)
        if via_ptr then
            local t_base = fresh_tmp("sbase")
            push_line(buf, string.format("    %%%s =l loadl %%%s_slot", t_base, node.vname))
            push_line(buf, string.format("    %%%s =l add %%%s, %d",    t_ptr,  t_base, fdef.offset))
        else
            push_line(buf, string.format("    %%%s =l add %%%s_slot, %d", t_ptr, node.vname, fdef.offset))
        end
        if     fqt=="d" then push_line(buf, string.format("    %%%s =d loadd %%%s", dest, t_ptr))
        elseif fqt=="l" then push_line(buf, string.format("    %%%s =l loadl %%%s", dest, t_ptr))
        else                 push_line(buf, string.format("    %%%s =w loadw %%%s", dest, t_ptr))
        end

    elseif k == "uneg" then
        local t = fresh_tmp("neg")
        emit_xpr(buf, node.x, t)
        if is_float_node(node.x) then
            push_line(buf, string.format("    %%%s =d sub d_0, %%%s", dest, t))
        else
            push_line(buf, string.format("    %%%s =w sub 0, %%%s", dest, t))
        end

    elseif k == "unot" then
        local t = fresh_tmp("notx")
        emit_xpr(buf, node.x, t)
        push_line(buf, string.format("    %%%s =w ceqw %%%s, 0", dest, t))

    elseif k == "binop" then
        local op = node.op

        if op == "AND" then
            local sp    = fresh_tmp("and_spill")
            local l_rhs = fresh_label("and_rhs")
            local l_no  = fresh_label("and_no")
            local l_end = fresh_label("and_end")
            push_line(buf, string.format("    %%%s_slot =l alloc4 4", sp))
            local lv = fresh_tmp("and_lhs"); emit_xpr(buf, node.lhs, lv)
            push_line(buf, string.format("    jnz %%%s, %s, %s", lv, l_rhs, l_no))
            push_line(buf, l_rhs)
            local rv = fresh_tmp("and_rhs"); local rb = fresh_tmp("and_bool")
            emit_xpr(buf, node.rhs, rv)
            push_line(buf, string.format("    %%%s =w csgtw %%%s, 0", rb, rv))
            push_line(buf, string.format("    storew %%%s, %%%s_slot", rb, sp))
            push_line(buf, "    jmp "..l_end)
            push_line(buf, l_no)
            push_line(buf, string.format("    storew 0, %%%s_slot", sp))
            push_line(buf, "    jmp "..l_end)
            push_line(buf, l_end)
            push_line(buf, string.format("    %%%s =w loadw %%%s_slot", dest, sp))
            return
        end

        if op == "OR" then
            local sp    = fresh_tmp("or_spill")
            local l_rhs = fresh_label("or_rhs")
            local l_yes = fresh_label("or_yes")
            local l_end = fresh_label("or_end")
            push_line(buf, string.format("    %%%s_slot =l alloc4 4", sp))
            local lv = fresh_tmp("or_lhs"); emit_xpr(buf, node.lhs, lv)
            push_line(buf, string.format("    jnz %%%s, %s, %s", lv, l_yes, l_rhs))
            push_line(buf, l_rhs)
            local rv = fresh_tmp("or_rhs"); local rb = fresh_tmp("or_bool")
            emit_xpr(buf, node.rhs, rv)
            push_line(buf, string.format("    %%%s =w csgtw %%%s, 0", rb, rv))
            push_line(buf, string.format("    storew %%%s, %%%s_slot", rb, sp))
            push_line(buf, "    jmp "..l_end)
            push_line(buf, l_yes)
            push_line(buf, string.format("    storew 1, %%%s_slot", sp))
            push_line(buf, "    jmp "..l_end)
            push_line(buf, l_end)
            push_line(buf, string.format("    %%%s =w loadw %%%s_slot", dest, sp))
            return
        end

        local function is_str_val(x)
            if not x then return false end
            if x.kind == "lit_str" then return true end
            if x.kind == "var" then return (cur_vartypes[x.vname] or global_types[x.vname]) == "str" end
            return false
        end
        if op == "PLUS" and (is_str_val(node.lhs) or is_str_val(node.rhs)) then
            local t_sb  = fresh_tmp("sb")
            local t_lhs = fresh_tmp("cat_lhs")
            local t_rhs = fresh_tmp("cat_rhs")
            local t_a1  = fresh_tmp("cat_a1")
            local t_a2  = fresh_tmp("cat_a2")
            emit_xpr(buf, node.lhs, t_lhs)
            emit_xpr(buf, node.rhs, t_rhs)
            push_line(buf, string.format("    %%%s =l call $sb_new()", t_sb))
            push_line(buf, string.format("    %%%s =l call $sb_append(l %%%s, l %%%s)", t_a1, t_sb, t_lhs))
            push_line(buf, string.format("    %%%s =l call $sb_append(l %%%s, l %%%s)", t_a2, t_a1, t_rhs))
            push_line(buf, string.format("    %%%s =l call $sb_get(l %%%s)", dest, t_a2))
            return
        end

        local use_float = is_float_node(node.lhs) or is_float_node(node.rhs)
        local use_long  = (not use_float) and (is_long_node(node.lhs) or is_long_node(node.rhs))
        local opmap     = use_float and float_ops or (use_long and long_ops or int_ops)
        local qop       = opmap[op]
        if not qop then die_at("operator '"..op.."' unsupported for this type pair", node) end

        local lv = fresh_tmp("lhs"); local rv = fresh_tmp("rhs")
        emit_xpr(buf, node.lhs, lv)
        emit_xpr(buf, node.rhs, rv)

        if use_long then
            if not is_long_node(node.lhs) then
                local ext = fresh_tmp("widen_l")
                push_line(buf, string.format("    %%%s =l extsw %%%s", ext, lv))
                lv = ext
            end
            if not is_long_node(node.rhs) then
                local ext = fresh_tmp("widen_r")
                push_line(buf, string.format("    %%%s =l extsw %%%s", ext, rv))
                rv = ext
            end
        end

        local is_cmp  = op=="EQ" or op=="NEQ" or op=="GT" or op=="LT" or op=="GE" or op=="LE"
        local res_type = is_cmp and "w" or (use_float and "d" or (use_long and "l" or "w"))
        push_line(buf, string.format("    %%%s =%s %s %%%s, %%%s", dest, res_type, qop, lv, rv))

    elseif k == "call" then
        local call_args = {}
        for _, arg in ipairs(node.args) do
            if arg.kind == "var" then
                local vt = cur_vartypes[arg.vname] or global_types[arg.vname] or ""
                if cur_structs[vt] then
                    call_args[#call_args+1] = global_types[arg.vname]
                        and "l $"..arg.vname
                        or  "l %"..arg.vname.."_slot"
                    goto next_call_arg
                end
            end
            do
                local t   = fresh_tmp("carg")
                local aqt = node_qtype(arg)
                if aqt == "arr" then aqt = "l" end
                emit_xpr(buf, arg, t)
                call_args[#call_args+1] = aqt.." %"..t
            end
            ::next_call_arg::
        end
        local callee  = node.fname == "print" and "print_int" or node.fname
        local call_rt = fn_return_types[callee] or "w"
        push_line(buf, string.format("    %%%s =%s call $%s(%s)",
            dest, call_rt, callee, table.concat(call_args, ", ")))

    elseif k == "method_call" then
        local recv_type = cur_vartypes[node.receiver] or global_types[node.receiver] or ""
        local sname     = recv_type:match("^struct:(.+)$") or recv_type
        local callee    = sname.."_"..node.method
        local call_args = {
            global_types[node.receiver]
                and "l $"..node.receiver
                or  "l %"..node.receiver.."_slot"
        }
        for _, arg in ipairs(node.args) do
            local t   = fresh_tmp("marg")
            local aqt = node_qtype(arg)
            if aqt == "arr" then aqt = "l" end
            emit_xpr(buf, arg, t)
            call_args[#call_args+1] = aqt.." %"..t
        end
        local call_rt = fn_return_types[callee] or "w"
        push_line(buf, string.format("    %%%s =%s call $%s(%s)",
            dest, call_rt, callee, table.concat(call_args, ", ")))

    else
        die_at("unhandled expr '"..tostring(k).."' — compiler bug", node)
    end
end

-- sector_8:stmt_emit
emit_stmt = function(buf, s, brk_lbl, cont_lbl)
    local k = s.kind

    if k == "decl" then
        if s.rhs then
            local t  = fresh_tmp("init")
            local qt = var_qtype(s.vname)
            emit_xpr(buf, s.rhs, t)
            local raw = cur_vartypes[s.vname] or ""
            if raw == "long" and node_qtype(s.rhs) == "w" then
                local ext = fresh_tmp("widen")
                push_line(buf, string.format("    %%%s =l extsw %%%s", ext, t))
                t = ext
            end
            if     qt=="d"   then push_line(buf, string.format("    stored %%%s, %%%s_slot", t, s.vname))
            elseif qt=="l"   then push_line(buf, string.format("    storel %%%s, %%%s_slot", t, s.vname))
            elseif qt~="arr" then push_line(buf, string.format("    storew %%%s, %%%s_slot", t, s.vname))
            end
        end

    elseif k == "assign" then
        local t  = fresh_tmp("asgn")
        local qt = var_qtype(s.vname)
        emit_xpr(buf, s.rhs, t)
        local raw = cur_vartypes[s.vname] or global_types[s.vname] or ""
        if raw == "long" and node_qtype(s.rhs) == "w" then
            local ext = fresh_tmp("widen")
            push_line(buf, string.format("    %%%s =l extsw %%%s", ext, t))
            t = ext
        end
        if global_types[s.vname] then
            if     qt=="d" then push_line(buf, string.format("    stored %%%s, $%s", t, s.vname))
            elseif qt=="l" then push_line(buf, string.format("    storel %%%s, $%s", t, s.vname))
            else                push_line(buf, string.format("    storew %%%s, $%s", t, s.vname))
            end
        else
            if     qt=="d" then push_line(buf, string.format("    stored %%%s, %%%s_slot", t, s.vname))
            elseif qt=="l" then push_line(buf, string.format("    storel %%%s, %%%s_slot", t, s.vname))
            else                push_line(buf, string.format("    storew %%%s, %%%s_slot", t, s.vname))
            end
        end

    elseif k == "arr_set" then
        local vt = cur_vartypes[s.vname] or global_types[s.vname] or "int[1]"
        if vt == "long" then vt = "int[]" end
        local base, fixed_sz = split_array_type(vt)
        base = base or "int"
        local eqt   = scalar_qtype(base)
        local esz   = scalar_byte_size(base)
        local t_idx = fresh_tmp("idx"); local t_off = fresh_tmp("off")
        local t_ptr = fresh_tmp("ptr"); local t_val = fresh_tmp("val")
        emit_xpr(buf, s.idx, t_idx)
        push_line(buf, string.format("    %%%s =l extsw %%%s",   t_off, t_idx))
        push_line(buf, string.format("    %%%s =l mul %%%s, %d", t_off, t_off, esz))
        if fixed_sz then
            push_line(buf, string.format("    %%%s =l add %%%s_slot, %%%s", t_ptr, s.vname, t_off))
        else
            local t_base = fresh_tmp("base")
            push_line(buf, string.format("    %%%s =l loadl %%%s_slot", t_base, s.vname))
            push_line(buf, string.format("    %%%s =l add %%%s, %%%s",   t_ptr, t_base, t_off))
        end
        emit_xpr(buf, s.rhs, t_val)
        if     eqt=="d" then push_line(buf, string.format("    stored %%%s, %%%s", t_val, t_ptr))
        elseif eqt=="l" then push_line(buf, string.format("    storel %%%s, %%%s", t_val, t_ptr))
        else                 push_line(buf, string.format("    storew %%%s, %%%s", t_val, t_ptr))
        end

    elseif k == "field_set" then
        local raw    = cur_vartypes[s.vname] or ""
        local sname  = raw:match("^struct:(.+)$") or raw
        local via_ptr = cur_vartypes[s.vname] == "long" and cur_self_struct
        if via_ptr then sname = cur_self_struct end
        local sdef = cur_structs[sname]
        if not sdef then die_at("'"..s.vname.."' type '"..tostring(sname).."' unknown struct", s) end
        local fdef
        for _, f in ipairs(sdef.fields) do if f.name == s.field then fdef = f; break end end
        if not fdef then
            local names = {}
            for _, f in ipairs(sdef.fields) do names[#names+1] = f.name end
            die_at("no field '"..s.field.."' on '"..sname.."' — have: "..table.concat(names,", "), s)
        end
        local t_ptr = fresh_tmp("fptr"); local t_val = fresh_tmp("fval")
        local fqt   = scalar_qtype(fdef.ftype)
        if via_ptr then
            local t_base = fresh_tmp("sbase")
            push_line(buf, string.format("    %%%s =l loadl %%%s_slot", t_base, s.vname))
            push_line(buf, string.format("    %%%s =l add %%%s, %d",    t_ptr,  t_base, fdef.offset))
        else
            push_line(buf, string.format("    %%%s =l add %%%s_slot, %d", t_ptr, s.vname, fdef.offset))
        end
        emit_xpr(buf, s.rhs, t_val)
        if     fqt=="d" then push_line(buf, string.format("    stored %%%s, %%%s", t_val, t_ptr))
        elseif fqt=="l" then push_line(buf, string.format("    storel %%%s, %%%s", t_val, t_ptr))
        else                 push_line(buf, string.format("    storew %%%s, %%%s", t_val, t_ptr))
        end

    elseif k == "xstmt" then
        emit_xpr(buf, s.expr, fresh_tmp("drop"))

    elseif k == "ret" then
        local t = fresh_tmp("retv")
        emit_xpr(buf, s.val, t)
        push_line(buf, "    ret %"..t)
        return true

    elseif k == "brk" then
        if not brk_lbl  then die_at("break outside loop",    s) end
        push_line(buf, "    jmp "..brk_lbl)
        return true

    elseif k == "cont" then
        if not cont_lbl then die_at("continue outside loop", s) end
        push_line(buf, "    jmp "..cont_lbl)
        return true

    elseif k == "loop" then
        local l_cond = fresh_label("wcond")
        local l_body = fresh_label("wbody")
        local l_exit = fresh_label("wexit")
        push_line(buf, "    jmp "..l_cond)
        push_line(buf, l_cond)
        local cv = fresh_tmp("wcv"); emit_xpr(buf, s.cond, cv)
        push_line(buf, string.format("    jnz %%%s, %s, %s", cv, l_body, l_exit))
        push_line(buf, l_body)
        if not emit_block(buf, s.body, l_exit, l_cond) then push_line(buf, "    jmp "..l_cond) end
        push_line(buf, l_exit)

    elseif k == "forloop" then
        local l_cond = fresh_label("fcond")
        local l_body = fresh_label("fbody")
        local l_step = fresh_label("fstep")
        local l_exit = fresh_label("fexit")
        local t_init = fresh_tmp("finit")
        emit_xpr(buf, s.start, t_init)
        push_line(buf, string.format("    storew %%%s, %%%s_slot", t_init, s.iname))
        push_line(buf, "    jmp "..l_cond)
        push_line(buf, l_cond)
        local t_iv  = fresh_tmp("fiv")
        local t_lim = fresh_tmp("flim")
        local t_cmp = fresh_tmp("fcmp")
        push_line(buf, string.format("    %%%s =w loadw %%%s_slot", t_iv, s.iname))
        emit_xpr(buf, s.limit, t_lim)
        push_line(buf, string.format("    %%%s =w csltw %%%s, %%%s", t_cmp, t_iv, t_lim))
        push_line(buf, string.format("    jnz %%%s, %s, %s", t_cmp, l_body, l_exit))
        push_line(buf, l_body)
        local all_stmts  = s.body.stmts
        local step_stmt  = all_stmts[#all_stmts]
        local user_block = {kind="block", stmts={}}
        for i = 1, #all_stmts-1 do user_block.stmts[i] = all_stmts[i] end
        if not emit_block(buf, user_block, l_exit, l_step) then push_line(buf, "    jmp "..l_step) end
        push_line(buf, l_step)
        emit_stmt(buf, step_stmt, l_exit, l_step)
        push_line(buf, "    jmp "..l_cond)
        push_line(buf, l_exit)

    elseif k == "ifx" then
        local l_yes  = fresh_label("iy")
        local l_no   = fresh_label("in")
        local l_done = fresh_label("id")
        local cv = fresh_tmp("icv"); emit_xpr(buf, s.cond, cv)
        push_line(buf, string.format("    jnz %%%s, %s, %s", cv, l_yes, s.no and l_no or l_done))
        push_line(buf, l_yes)
        if not emit_block(buf, s.yes, brk_lbl, cont_lbl) then push_line(buf, "    jmp "..l_done) end
        if s.no then
            push_line(buf, l_no)
            if not emit_block(buf, s.no, brk_lbl, cont_lbl) then push_line(buf, "    jmp "..l_done) end
        end
        push_line(buf, l_done)

    elseif k == "casex" then
        local l_done = fresh_label("cdone")
        local sv = fresh_tmp("csub"); emit_xpr(buf, s.subject, sv)
        for _, arm in ipairs(s.arms) do
            local l_arm  = fresh_label("carm")
            local l_next = fresh_label("cnext")
            local av = fresh_tmp("cval"); emit_xpr(buf, arm.val, av)
            local cv = fresh_tmp("ccmp")
            push_line(buf, string.format("    %%%s =w ceqw %%%s, %%%s", cv, sv, av))
            push_line(buf, string.format("    jnz %%%s, %s, %s", cv, l_arm, l_next))
            push_line(buf, l_arm)
            if not emit_block(buf, arm.body, brk_lbl, cont_lbl) then push_line(buf, "    jmp "..l_done) end
            push_line(buf, l_next)
        end
        if s.default then
            if not emit_block(buf, s.default, brk_lbl, cont_lbl) then push_line(buf, "    jmp "..l_done) end
        else
            push_line(buf, "    jmp "..l_done)
        end
        push_line(buf, l_done)

    else
        die_at("unhandled stmt '"..tostring(k).."' — compiler bug", s)
    end
    return false
end

emit_block = function(buf, block, brk_lbl, cont_lbl)
    for _, s in ipairs(block.stmts) do
        if emit_stmt(buf, s, brk_lbl, cont_lbl) then return true end
    end
    return false
end

-- sector_8:decl_hoist
local function hoist_decls(block, seen)
    for _, s in ipairs(block.stmts) do
        if s.kind == "decl" then seen[s.vname] = s.vtype or "int" end
        if     s.kind == "ifx"     then hoist_decls(s.yes, seen); if s.no then hoist_decls(s.no, seen) end
        elseif s.kind == "loop"    then hoist_decls(s.body, seen)
        elseif s.kind == "forloop" then seen[s.iname] = "int"; hoist_decls(s.body, seen)
        elseif s.kind == "casex"   then
            for _, arm in ipairs(s.arms) do hoist_decls(arm.body, seen) end
            if s.default then hoist_decls(s.default, seen) end
        end
    end
end

-- sector_8:fn_emit
local function emit_func(buf, fn)
    cur_structs     = fn.structs or {}
    cur_self_struct = fn.impl_struct or nil

    local param_sigs = {}
    for _, p in ipairs(fn.params) do
        local pt = p.ptype or "int"
        local qt = qbe_type_of(pt)
        if qt == "arr"     then qt = "l" end
        if cur_structs[pt] then qt = "l" end
        param_sigs[#param_sigs+1] = qt.." %p_"..p.pname
    end

    local export_name = fn.fname == "main" and "lang_main" or fn.fname
    local ret_qt      = fn.rtype=="float" and "d" or fn.rtype=="long" and "l" or "w"
    push_line(buf, string.format("export function %s $%s(%s) {",
        ret_qt, export_name, table.concat(param_sigs, ", ")))
    push_line(buf, "@fn_entry")

    cur_vartypes = {}
    hoist_decls(fn.body, cur_vartypes)
    for _, p in ipairs(fn.params) do cur_vartypes[p.pname] = p.ptype or "int" end

    for vname, vtype in pairs(cur_vartypes) do
        local base, fixed_sz = split_array_type(vtype)
        if base and fixed_sz then
            local esz   = scalar_byte_size(base)
            local align = esz >= 8 and 8 or 4
            push_line(buf, string.format("    %%%s_slot =l alloc%d %d", vname, align, esz*fixed_sz))
        elseif base and not fixed_sz then
            push_line(buf, string.format("    %%%s_slot =l alloc8 8", vname))
        elseif cur_structs[vtype] then
            push_line(buf, string.format("    %%%s_slot =l alloc8 %d", vname, cur_structs[vtype].size))
        else
            local qt = qbe_type_of(vtype)
            push_line(buf, qt == "w"
                and string.format("    %%%s_slot =l alloc4 4", vname)
                or  string.format("    %%%s_slot =l alloc8 8", vname))
        end
    end

    for _, p in ipairs(fn.params) do
        local pn = p.pname
        local pt = p.ptype or "int"
        local qt = qbe_type_of(pt)
        if qt == "arr" then qt = "l" end
        if cur_structs[pt] then
            push_line(buf, string.format("    %%%s_mc_sz =w copy %d", pn, cur_structs[pt].size))
            push_line(buf, string.format("    call $memcpy(l %%%s_slot, l %%p_%s, w %%%s_mc_sz)", pn, pn, pn))
        elseif qt == "d" then push_line(buf, string.format("    stored %%p_%s, %%%s_slot", pn, pn))
        elseif qt == "l" then push_line(buf, string.format("    storel %%p_%s, %%%s_slot", pn, pn))
        else                  push_line(buf, string.format("    storew %%p_%s, %%%s_slot", pn, pn))
        end
    end

    if not emit_block(buf, fn.body, nil, nil) then push_line(buf, "    ret 0") end
    push_line(buf, "}")
end

local function emit_str_data(buf)
    for _, sl in ipairs(interned_strs) do
        local esc = sl.val:gsub('\\','\\\\'):gsub('"','\\"')
        push_line(buf, string.format('data $%s = { b "%s", b 0 }', sl.lbl, esc))
    end
end

-- sector_8:codegen_entry
local function codegen(prog)
    n_labels = 0; n_temps = 0
    interned_strs = {}; n_strs = 0
    cur_structs     = prog.structs or {}
    cur_self_struct = nil

    global_types = {}
    for _, g in ipairs(prog.globals or {}) do global_types[g.gname] = g.gtype end

    fn_return_types = {}
    for _, ex in ipairs(prog.externs) do fn_return_types[ex.fname] = qbe_type_of(ex.rtype or "int") end
    for _, fn in ipairs(prog.funcs)   do fn_return_types[fn.fname] = qbe_type_of(fn.rtype or "int") end

    local buf = {}

    for _, g in ipairs(prog.globals or {}) do
        local qt = qbe_type_of(g.gtype)
        if qt == "d" then
            local v = g.init and g.init.kind=="lit_float" and tostring(g.init.fval) or "d_0"
            push_line(buf, string.format("data $%s = { d %s }", g.gname, v))
        elseif qt == "l" then
            local v = 0
            if g.init then
                if     g.init.kind=="lit_int" then v = g.init.ival
                elseif g.init.kind=="lit_str" then
                    local lbl = intern_str_literal(g.init.sval)
                    push_line(buf, string.format("data $%s = { l $%s }", g.gname, lbl))
                    v = nil
                end
            end
            if v ~= nil then push_line(buf, string.format("data $%s = { l %d }", g.gname, v)) end
        else
            local v = g.init and g.init.kind=="lit_int" and g.init.ival or 0
            push_line(buf, string.format("data $%s = { w %d }", g.gname, v))
        end
    end
    if #(prog.globals or {}) > 0 then push_line(buf, "") end

    local has_toplevel = prog.toplevel_stmts and #prog.toplevel_stmts > 0
    if has_toplevel then
        emit_func(buf, {
            fname="__init", params={}, rtype="int",
            body   = {kind="block", stmts=prog.toplevel_stmts},
            structs= prog.structs or {},
            impl_struct=nil,
        })
        push_line(buf, "")
    end

    local has_main = false
    for _, fn in ipairs(prog.funcs) do if fn.fname == "main" then has_main=true; break end end

    if has_toplevel and not has_main then
        emit_func(buf, {
            fname="main", params={}, rtype="int",
            body={kind="block", stmts={
                {kind="xstmt", expr={kind="call", fname="__init", args={}}},
                {kind="ret",   val ={kind="lit_int", ival=0}},
            }},
            structs=prog.structs or {}, impl_struct=nil,
        })
        push_line(buf, "")
    end

    for _, fn in ipairs(prog.funcs) do
        if fn.fname == "main" and has_toplevel then
            table.insert(fn.body.stmts, 1, {kind="xstmt", expr={kind="call", fname="__init", args={}}})
        end
        emit_func(buf, fn)
        push_line(buf, "")
    end

    if #interned_strs > 0 then push_line(buf, ""); emit_str_data(buf) end

    return table.concat(buf, "\n")
end

return codegen