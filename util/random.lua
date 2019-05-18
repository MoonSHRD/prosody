-- Prosody IM
-- Copyright (C) 2008-2014 Matthew Wild
-- Copyright (C) 2008-2014 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local ok, crand = pcall(require, "util.crand");
if ok then return crand; end

local urandom, urandom_err = io.open("/dev/urandom", "r");

local function bytes(n)
	local data, err = urandom:read(n);
	if not data then
		error("Unable to retrieve data from secure random number generator (/dev/urandom): "..tostring(err));
	end
	return data;
end

if not urandom then
	function bytes()
		error("Unable to obtain a secure random number generator, please see https://prosody.im/doc/random ("..urandom_err..")");
	end
end

return {
	bytes = bytes;
	_source = "/dev/urandom";
};
