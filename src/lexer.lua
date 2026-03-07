-- lpp lexer
-- turns source text into a flat list of tokens.
-- nothing here is clever. it's just a big while loop and a table of keywords.
-- if you're reading this looking for something smart, wrong file.

local function lpp_tokenize(src)
    local lpp_tokbuf = {}
    local lpp_pos = 1

    -- every keyword that gets its own token type instead of being an IDENT.
    -- "print" is NOT here on purpose — it parses like a normal function call.
    local lpp_kwds = {
        ["func"]=1,   ["local"]=1,  ["if"]=1,     ["else"]=1,
        ["while"]=1,  ["return"]=1, ["break"]=1,
        ["int"]=1,    ["bool"]=1,   ["true"]=1,   ["false"]=1,
        ["extern"]=1, ["linkto"]=1, ["float"]=1,  ["str"]=1,
        ["case"]=1,   ["struct"]=1, ["char"]=1,   ["long"]=1,
    }

    local function lpp_pushtok(tag, v)
        lpp_tokbuf[#lpp_tokbuf+1] = v ~= nil and {tag=tag, val=v} or {tag=tag}
    end

    while lpp_pos <= #src do
        local c = src:sub(lpp_pos, lpp_pos)

        -- skip whitespace, we don't care about indentation or newlines
        if c:match("%s") then
            lpp_pos = lpp_pos+1

        -- single line comments, just skip to end of line
        elseif src:sub(lpp_pos, lpp_pos+1) == "//" then
            while lpp_pos <= #src and src:sub(lpp_pos,lpp_pos) ~= "\n" do
                lpp_pos = lpp_pos+1
            end

        -- string literal, grab everything between the quotes
        -- handles backslash escapes so we don't eat the closing quote by accident
        elseif c == '"' then
            lpp_pos = lpp_pos+1
            local s = lpp_pos
            while lpp_pos <= #src and src:sub(lpp_pos,lpp_pos) ~= '"' do
                if src:sub(lpp_pos,lpp_pos) == '\\' then lpp_pos = lpp_pos+1 end
                lpp_pos = lpp_pos+1
            end
            lpp_pushtok("STRING", src:sub(s, lpp_pos-1))
            lpp_pos = lpp_pos+1

        -- char literal: 'A' or escape sequences like '\n'
        -- we just convert it to its ASCII int value immediately,
        -- char is really just a fancy int anyway
        elseif c == "'" then
            lpp_pos = lpp_pos+1
            local ch
            if src:sub(lpp_pos,lpp_pos) == '\\' then
                lpp_pos = lpp_pos+1
                local esc = src:sub(lpp_pos,lpp_pos)
                lpp_pos = lpp_pos+1
                if     esc == 'n'  then ch = 10   -- newline
                elseif esc == 't'  then ch = 9    -- tab
                elseif esc == 'r'  then ch = 13   -- carriage return
                elseif esc == '0'  then ch = 0    -- null
                elseif esc == '\\' then ch = 92   -- backslash
                elseif esc == "'"  then ch = 39   -- single quote
                else ch = esc:byte(1) end
            else
                ch = src:sub(lpp_pos,lpp_pos):byte(1)
                lpp_pos = lpp_pos+1
            end
            if src:sub(lpp_pos,lpp_pos) == "'" then lpp_pos = lpp_pos+1 end
            lpp_pushtok("CHAR", ch)

        -- number — could be int or float, we figure out which by checking for a dot
        elseif c:match("%d") then
            local s = lpp_pos
            while lpp_pos <= #src and src:sub(lpp_pos,lpp_pos):match("%d") do
                lpp_pos = lpp_pos+1
            end
            if lpp_pos <= #src and src:sub(lpp_pos,lpp_pos) == "." then
                -- has a dot, it's a float
                lpp_pos = lpp_pos+1
                while lpp_pos <= #src and src:sub(lpp_pos,lpp_pos):match("%d") do
                    lpp_pos = lpp_pos+1
                end
                lpp_pushtok("FLOAT", tonumber(src:sub(s, lpp_pos-1)))
            else
                lpp_pushtok("NUMBER", tonumber(src:sub(s, lpp_pos-1)))
            end

        -- identifier or keyword — eat alphanumerics+underscores then check the keyword table
        elseif c:match("[%a_]") then
            local s = lpp_pos
            while lpp_pos <= #src and src:sub(lpp_pos,lpp_pos):match("[%w_]") do
                lpp_pos = lpp_pos+1
            end
            local word = src:sub(s, lpp_pos-1)
            if lpp_kwds[word] then lpp_pushtok(word:upper())
            else lpp_pushtok("IDENT", word) end

        -- two-char operators — check these BEFORE the single-char ones or == becomes = =
        elseif src:sub(lpp_pos,lpp_pos+1) == "==" then lpp_pushtok("EQ");    lpp_pos=lpp_pos+2
        elseif src:sub(lpp_pos,lpp_pos+1) == "!=" then lpp_pushtok("NEQ");   lpp_pos=lpp_pos+2
        elseif src:sub(lpp_pos,lpp_pos+1) == "<=" then lpp_pushtok("LE");    lpp_pos=lpp_pos+2
        elseif src:sub(lpp_pos,lpp_pos+1) == ">=" then lpp_pushtok("GE");    lpp_pos=lpp_pos+2

        -- single-char operators and punctuation, boring stuff
        elseif c == "=" then lpp_pushtok("ASSIGN"); lpp_pos=lpp_pos+1
        elseif c == ":" then lpp_pushtok("COLON");  lpp_pos=lpp_pos+1
        elseif c == "(" then lpp_pushtok("LPAREN"); lpp_pos=lpp_pos+1
        elseif c == ")" then lpp_pushtok("RPAREN"); lpp_pos=lpp_pos+1
        elseif c == "{" then lpp_pushtok("LBRACE"); lpp_pos=lpp_pos+1
        elseif c == "}" then lpp_pushtok("RBRACE"); lpp_pos=lpp_pos+1
        elseif c == "[" then lpp_pushtok("LBRACK"); lpp_pos=lpp_pos+1
        elseif c == "]" then lpp_pushtok("RBRACK"); lpp_pos=lpp_pos+1
        elseif c == "." then lpp_pushtok("DOT");    lpp_pos=lpp_pos+1
        elseif c == "," then lpp_pushtok("COMMA");  lpp_pos=lpp_pos+1
        elseif c == "+" then lpp_pushtok("PLUS");   lpp_pos=lpp_pos+1
        elseif c == "-" then lpp_pushtok("MINUS");  lpp_pos=lpp_pos+1
        elseif c == "*" then lpp_pushtok("STAR");   lpp_pos=lpp_pos+1
        elseif c == "/" then lpp_pushtok("SLASH");  lpp_pos=lpp_pos+1
        elseif c == "%" then lpp_pushtok("PCENT");  lpp_pos=lpp_pos+1
        elseif c == ">" then lpp_pushtok("GT");     lpp_pos=lpp_pos+1
        elseif c == "<" then lpp_pushtok("LT");     lpp_pos=lpp_pos+1
        elseif c == "!" then lpp_pushtok("BANG");   lpp_pos=lpp_pos+1
        elseif c == "&" then lpp_pushtok("AMP");    lpp_pos=lpp_pos+1
        else lpp_pos=lpp_pos+1  -- unknown character, just skip it and pretend it didn't happen
        end
    end

    return lpp_tokbuf
end

return lpp_tokenize
