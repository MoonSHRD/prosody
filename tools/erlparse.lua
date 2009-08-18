-- Prosody IM
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--



local file = nil;
local last = nil;
local function read(expected)
	local ch;
	if last then
		ch = last; last = nil;
	else ch = file:read(1); end
	if expected and ch ~= expected then error("expected: "..expected.."; got: "..(ch or "nil")); end
	return ch;
end
local function pushback(ch)
	if last then error(); end
	last = ch;
end
local function peek()
	if not last then last = read(); end
	return last;
end

local _A, _a, _Z, _z, _0, _9, __, _at, _space = string.byte("AaZz09@_ ", 1, 9);
local function isLowerAlpha(ch)
	ch = string.byte(ch) or 0;
	return (ch >= _a and ch <= _z);
end
local function isNumeric(ch)
	ch = string.byte(ch) or 0;
	return (ch >= _0 and ch <= _9);
end
local function isAtom(ch)
	ch = string.byte(ch) or 0;
	return (ch >= _A and ch <= _Z) or (ch >= _a and ch <= _z) or (ch >= _0 and ch <= _9) or ch == __ or ch == _at;
end
local function isSpace(ch)
	ch = string.byte(ch) or "x";
	return ch <= _space;
end

local function readString()
	read("\""); -- skip quote
	local slash = nil;
	local str = "";
	while true do
		local ch = read();
		if ch == "\"" and not slash then break; end
		str = str..ch;
	end
	str = str:gsub("\\.", {["\\b"]="\b", ["\\d"]="\d", ["\\e"]="\e", ["\\f"]="\f", ["\\n"]="\n", ["\\r"]="\r", ["\\s"]="\s", ["\\t"]="\t", ["\\v"]="\v", ["\\\""]="\"", ["\\'"]="'", ["\\\\"]="\\"});
	return str;
end
local function readAtom1()
	local var = read();
	while isAtom(peek()) do
		var = var..read();
	end
	return var;
end
local function readAtom2()
	local str = read("'");
	local slash = nil;
	while true do
		local ch = read();
		str = str..ch;
		if ch == "'" and not slash then break; end
	end
	return str;
end
local function readNumber()
	local num = read();
	while isNumeric(peek()) do
		num = num..read();
	end
	return tonumber(num);
end
local readItem = nil;
local function readTuple()
	local t = {};
	local s = ""; -- string representation
	read(); -- read {, or [, or <
	while true do
		local item = readItem();
		if not item then break; end
		if type(item) ~= type(0) or item > 255 then
			s = nil;
		elseif s then
			s = s..string.char(item);
		end
		table.insert(t, item);
	end
	read(); -- read }, or ], or >
	if s and s ~= "" then
		return s
	else
		return t
	end;
end
local function readBinary()
	read("<"); -- read <
	local t = readTuple();
	read(">") -- read >
	local ch = peek();
	if type(t) == type("") then
		-- binary is a list of integers
		return t;
	elseif type(t) == type({}) then
		if t[1] then
			-- binary contains string
			return t[1];
		else
			-- binary is empty
			return "";
		end;
	else
		error();
	end
end
readItem = function()
	local ch = peek();
	if ch == nil then return nil end
	if ch == "{" or ch == "[" then
		return readTuple();
	elseif isLowerAlpha(ch) then
		return readAtom1();
	elseif ch == "'" then
		return readAtom2();
	elseif isNumeric(ch) then
		return readNumber();
	elseif ch == "\"" then
		return readString();
	elseif ch == "<" then
		return readBinary();
	elseif isSpace(ch) or ch == "," or ch == "|" then
		read();
		return readItem();
	else
		--print("Unknown char: "..ch);
		return nil;
	end
end
local function readChunk()
	local x = readItem();
	if x then read("."); end
	return x;
end
local function readFile(filename)
	file = io.open(filename);
	if not file then error("File not found: "..filename); os.exit(0); end
	return function()
		local x = readChunk();
		if not x and peek() then error("Invalid char: "..peek()); end
		return x;
	end;
end

module "erlparse"

function parseFile(file)
	return readFile(file);
end

return _M;
