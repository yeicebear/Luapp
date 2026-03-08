-- lpp lexer
-- turns source text into flat list of tokens
-- nothing here is clever its just big while loop and table of keywords
-- if u came here looking for smart code wrong file

local function lpp_tokenize(src)
    local lpp_tokbuf = {}
    local lpp_pos = 1

    -- every keyword that gets its own token type instead of being IDENT
    -- print is NOT here on purpose it parses like normal function call
    local lpp_kwds = {
        ["func"]=1,   ["local"]=1,  ["if"]=1,     ["else"]=1,
        ["while"]=1,  ["return"]=1, ["break"]=1,
        ["int"]=1,    ["bool"]=1,   ["true"]=1,   ["false"]=1,
        ["extern"]=1, ["linkto"]=1, ["float"]=1,  ["str"]=1,
        ["case"]=1,   ["struct"]=1, ["char"]=1,   ["long"]=1,
        ["global"]=1, ["impl"]=1,
    }

    local function lpp_pushtok(tag, v)
        lpp_tokbuf[#lpp_tokbuf+1] = v ~= nil and {tag=tag, val=v} or {tag=tag}
    end

    while lpp_pos <= #src do
        local c = src:sub(lpp_pos, lpp_pos)

        -- skip whitespace we dont care about indentation or newlines
        if c:match("%s") then
            lpp_pos = lpp_pos+1

        -- single line comments skip until end of line
        elseif src:sub(lpp_pos, lpp_pos+1) == "//" then
            while lpp_pos <= #src and src:sub(lpp_pos,lpp_pos) ~= "\n" do
                lpp_pos = lpp_pos+1
            end

        -- string literal grab everything inside quotes
        -- handles backslash escapes so we dont eat closing quote
        elseif c == '"' then
            lpp_pos = lpp_pos+1
            local s = lpp_pos
            while lpp_pos <= #src and src:sub(lpp_pos,lpp_pos) ~= '"' do
                if src:sub(lpp_pos,lpp_pos) == '\\' then lpp_pos = lpp_pos+1 end
                lpp_pos = lpp_pos+1
            end
            lpp_pushtok("STRING", src:sub(s, lpp_pos-1))
            lpp_pos = lpp_pos+1

        -- char literal like A or escape like newline
        -- we convert it to ascii number immediatly
        -- char is just fancy int anyway
        elseif c == "'" then
            lpp_pos = lpp_pos+1
            local ch
            if src:sub(lpp_pos,lpp_pos) == '\\' then
                lpp_pos = lpp_pos+1
                local esc = src:sub(lpp_pos,lpp_pos)
                lpp_pos = lpp_pos+1
                if     esc == 'n'  then ch = 10
                elseif esc == 't'  then ch = 9
                elseif esc == 'r'  then ch = 13
                elseif esc == '0'  then ch = 0
                elseif esc == '\\' then ch = 92
                elseif esc == "'"  then ch = 39
                else ch = esc:byte(1) end
            else
                ch = src:sub(lpp_pos,lpp_pos):byte(1)
                lpp_pos = lpp_pos+1
            end
            if src:sub(lpp_pos,lpp_pos) == "'" then lpp_pos = lpp_pos+1 end
            lpp_pushtok("CHAR", ch)

        -- number could be int or float we check for dot
        elseif c:match("%d") then
            local s = lpp_pos
            while lpp_pos <= #src and src:sub(lpp_pos,lpp_pos):match("%d") do
                lpp_pos = lpp_pos+1
            end
            if lpp_pos <= #src and src:sub(lpp_pos,lpp_pos) == "." then
                -- has dot so its float
                lpp_pos = lpp_pos+1
                while lpp_pos <= #src and src:sub(lpp_pos,lpp_pos):match("%d") do
                    lpp_pos = lpp_pos+1
                end
                lpp_pushtok("FLOAT", tonumber(src:sub(s, lpp_pos-1)))
            else
                lpp_pushtok("NUMBER", tonumber(src:sub(s, lpp_pos-1)))
            end

        -- identifier or keyword eat letters numbers underscores
        -- then check keyword table
        elseif c:match("[%a_]") then
            local s = lpp_pos
            while lpp_pos <= #src and src:sub(lpp_pos,lpp_pos):match("[%w_]") do
                lpp_pos = lpp_pos+1
            end
            local word = src:sub(s, lpp_pos-1)
            if lpp_kwds[word] then lpp_pushtok(word:upper())
            else lpp_pushtok("IDENT", word) end

        -- two char operators check before single char ones
        elseif src:sub(lpp_pos,lpp_pos+1) == "==" then lpp_pushtok("EQ");    lpp_pos=lpp_pos+2
        elseif src:sub(lpp_pos,lpp_pos+1) == "!=" then lpp_pushtok("NEQ");   lpp_pos=lpp_pos+2
        elseif src:sub(lpp_pos,lpp_pos+1) == "<=" then lpp_pushtok("LE");    lpp_pos=lpp_pos+2
        elseif src:sub(lpp_pos,lpp_pos+1) == ">=" then lpp_pushtok("GE");    lpp_pos=lpp_pos+2

        -- single char operators and punctuation boring stuff
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
        else lpp_pos=lpp_pos+1
        end
    end

    return lpp_tokbuf
end

return lpp_tokenize