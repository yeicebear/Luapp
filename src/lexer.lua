-- lpp lexer. turns source text into a flat list of tokens.
-- nothing here is clever. it's just a big while loop.

local function lpp_tokenize(src)
    local lpp_tokbuf = {}
    local lpp_pos = 1

    -- keywords that become their own token type instead of IDENT
    -- "print" is intentionally NOT here so it parses like a normal call
    local lpp_kwds = {
        ["func"]=1, ["local"]=1, ["if"]=1, ["else"]=1,
        ["while"]=1, ["return"]=1, ["break"]=1,
        ["int"]=1, ["bool"]=1, ["true"]=1, ["false"]=1,
    }

    local function lpp_pushtok(tag, v)
        lpp_tokbuf[#lpp_tokbuf+1] = v ~= nil and {tag=tag, val=v} or {tag=tag}
    end

    while lpp_pos <= #src do
        local c = src:sub(lpp_pos, lpp_pos)

        if c:match("%s") then
            lpp_pos = lpp_pos+1

        elseif src:sub(lpp_pos, lpp_pos+1) == "//" then
            -- eat the whole line comment
            while lpp_pos <= #src and src:sub(lpp_pos,lpp_pos) ~= "\n" do
                lpp_pos = lpp_pos+1
            end

        elseif c:match("%d") then
            local s = lpp_pos
            while lpp_pos <= #src and src:sub(lpp_pos,lpp_pos):match("%d") do
                lpp_pos = lpp_pos+1
            end
            lpp_pushtok("NUMBER", tonumber(src:sub(s, lpp_pos-1)))

        elseif c:match("[%a_]") then
            local s = lpp_pos
            while lpp_pos <= #src and src:sub(lpp_pos,lpp_pos):match("[%w_]") do
                lpp_pos = lpp_pos+1
            end
            local word = src:sub(s, lpp_pos-1)
            if lpp_kwds[word] then lpp_pushtok(word:upper())
            else lpp_pushtok("IDENT", word) end

        -- two-char operators, must check before single-char
        elseif src:sub(lpp_pos,lpp_pos+1) == "==" then lpp_pushtok("EQ");  lpp_pos=lpp_pos+2
        elseif src:sub(lpp_pos,lpp_pos+1) == "!=" then lpp_pushtok("NEQ"); lpp_pos=lpp_pos+2
        elseif src:sub(lpp_pos,lpp_pos+1) == "<=" then lpp_pushtok("LE");  lpp_pos=lpp_pos+2
        elseif src:sub(lpp_pos,lpp_pos+1) == ">=" then lpp_pushtok("GE");  lpp_pos=lpp_pos+2

        elseif c == "=" then lpp_pushtok("ASSIGN"); lpp_pos=lpp_pos+1
        elseif c == ":" then lpp_pushtok("COLON");  lpp_pos=lpp_pos+1
        elseif c == "(" then lpp_pushtok("LPAREN"); lpp_pos=lpp_pos+1
        elseif c == ")" then lpp_pushtok("RPAREN"); lpp_pos=lpp_pos+1
        elseif c == "{" then lpp_pushtok("LBRACE"); lpp_pos=lpp_pos+1
        elseif c == "}" then lpp_pushtok("RBRACE"); lpp_pos=lpp_pos+1
        elseif c == "," then lpp_pushtok("COMMA");  lpp_pos=lpp_pos+1
        elseif c == "+" then lpp_pushtok("PLUS");   lpp_pos=lpp_pos+1
        elseif c == "-" then lpp_pushtok("MINUS");  lpp_pos=lpp_pos+1
        elseif c == "*" then lpp_pushtok("STAR");   lpp_pos=lpp_pos+1
        elseif c == "/" then lpp_pushtok("SLASH");  lpp_pos=lpp_pos+1
        elseif c == "%" then lpp_pushtok("PCENT");  lpp_pos=lpp_pos+1
        elseif c == ">" then lpp_pushtok("GT");     lpp_pos=lpp_pos+1
        elseif c == "<" then lpp_pushtok("LT");     lpp_pos=lpp_pos+1
        elseif c == "!" then lpp_pushtok("BANG");   lpp_pos=lpp_pos+1
        else lpp_pos=lpp_pos+1  -- not our problem
        end
    end

    return lpp_tokbuf
end

return lpp_tokenize