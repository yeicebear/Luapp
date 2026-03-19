-- lexer.lua  |  sector_8:tokenizer
-- chops source text into a flat token list.
-- one big while loop. nothing clever. the cleverness is elsewhere.

local function tokenize(src)
    local tokens  = {}
    local pos     = 1
    local line    = 1

    local keywords = {
        ["func"]=1,    ["local"]=1,   ["if"]=1,       ["else"]=1,
        ["while"]=1,   ["return"]=1,  ["break"]=1,    ["continue"]=1,
        ["int"]=1,     ["bool"]=1,    ["true"]=1,     ["false"]=1,
        ["extern"]=1,  ["linkto"]=1,  ["float"]=1,    ["str"]=1,
        ["case"]=1,    ["struct"]=1,  ["char"]=1,     ["long"]=1,
        ["for"]=1,     ["global"]=1,  ["impl"]=1,
    }

    local function push(tag, val)
        tokens[#tokens+1] = val ~= nil
            and {tag=tag, val=val, line=line}
            or  {tag=tag,          line=line}
    end

    local function peek2() return src:sub(pos, pos+1) end
    local function cur()   return src:sub(pos, pos)   end

    while pos <= #src do
        local c = cur()

        if c:match("%s") then
            if c == "\n" then line = line+1 end
            pos = pos+1

        elseif peek2() == "//" then
            while pos <= #src and cur() ~= "\n" do pos = pos+1 end

        elseif c == '"' then
            pos = pos+1
            local s = pos
            while pos <= #src and cur() ~= '"' do
                if cur() == '\\' then pos = pos+1 end
                pos = pos+1
            end
            push("STRING", src:sub(s, pos-1))
            pos = pos+1

        elseif c == "'" then
            pos = pos+1
            local ch
            if cur() == '\\' then
                pos = pos+1
                local esc = cur(); pos = pos+1
                local escape_map = {n=10, t=9, r=13, ["0"]=0, ["\\"]= 92, ["'"]=39}
                ch = escape_map[esc] or esc:byte(1)
            else
                ch = cur():byte(1); pos = pos+1
            end
            if cur() == "'" then pos = pos+1 end
            push("CHAR", ch)

        elseif c:match("%d") then
            local s = pos
            if peek2():match("0[xX]") then
                pos = pos+2
                while pos <= #src and cur():match("[%x]") do pos = pos+1 end
                push("NUMBER", tonumber(src:sub(s, pos-1)))
            else
                while pos <= #src and cur():match("%d") do pos = pos+1 end
                if pos <= #src and cur() == "." then
                    pos = pos+1
                    while pos <= #src and cur():match("%d") do pos = pos+1 end
                    push("FLOAT", tonumber(src:sub(s, pos-1)))
                else
                    push("NUMBER", tonumber(src:sub(s, pos-1)))
                end
            end

        elseif c:match("[%a_]") then
            local s = pos
            while pos <= #src and cur():match("[%w_]") do pos = pos+1 end
            local word = src:sub(s, pos-1)
            if keywords[word] then push(word:upper())
            else                   push("IDENT", word)
            end

        elseif peek2()=="==" then push("EQ");      pos=pos+2
        elseif peek2()=="!=" then push("NEQ");     pos=pos+2
        elseif peek2()=="<=" then push("LE");      pos=pos+2
        elseif peek2()==">=" then push("GE");      pos=pos+2
        elseif peek2()=="+=" then push("PLUSEQ");  pos=pos+2
        elseif peek2()=="-=" then push("MINUSEQ"); pos=pos+2
        elseif peek2()=="*=" then push("STAREQ");  pos=pos+2
        elseif peek2()=="/=" then push("SLASHEQ"); pos=pos+2
        elseif peek2()=="%=" then push("PCENTEQ"); pos=pos+2
        elseif peek2()==">>" then push("SHR");     pos=pos+2
        elseif peek2()=="<<" then push("SHL");     pos=pos+2
        elseif peek2()=="&&" then push("AND");     pos=pos+2
        elseif peek2()=="||" then push("OR");      pos=pos+2
        elseif c=="=" then push("ASSIGN"); pos=pos+1
        elseif c==":" then push("COLON");  pos=pos+1
        elseif c=="(" then push("LPAREN"); pos=pos+1
        elseif c==")" then push("RPAREN"); pos=pos+1
        elseif c=="{" then push("LBRACE"); pos=pos+1
        elseif c=="}" then push("RBRACE"); pos=pos+1
        elseif c=="[" then push("LBRACK"); pos=pos+1
        elseif c=="]" then push("RBRACK"); pos=pos+1
        elseif c=="." then push("DOT");    pos=pos+1
        elseif c=="," then push("COMMA");  pos=pos+1
        elseif c=="+" then push("PLUS");   pos=pos+1
        elseif c=="-" then push("MINUS");  pos=pos+1
        elseif c=="*" then push("STAR");   pos=pos+1
        elseif c=="/" then push("SLASH");  pos=pos+1
        elseif c=="%" then push("PCENT");  pos=pos+1
        elseif c=="&" then push("AMP");    pos=pos+1
        elseif c=="|" then push("PIPE");   pos=pos+1
        elseif c=="^" then push("CARET");  pos=pos+1
        elseif c=="~" then push("TILDE");  pos=pos+1
        elseif c==">" then push("GT");     pos=pos+1
        elseif c=="<" then push("LT");     pos=pos+1
        elseif c=="!" then push("BANG");   pos=pos+1
        else pos=pos+1
        end
    end

    return tokens
end

return tokenize
