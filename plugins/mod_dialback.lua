
local format = string.format;
local send_s2s = require "core.s2smanager".send_to_host;
local s2s_make_authenticated = require "core.s2smanager".make_authenticated;
local s2s_verify_dialback = require "core.s2smanager".verify_dialback;

local log = require "util.logger".init("mod_dialback");

local xmlns_dialback = "jabber:server:dialback";

add_handler({"s2sin_unauthed", "s2sin"}, "verify", xmlns_dialback,
	function (origin, stanza)
		-- We are being asked to verify the key, to ensure it was generated by us
		log("debug", "verifying dialback key...");
		local attr = stanza.attr;
		-- FIXME: Grr, ejabberd breaks this one too?? it is black and white in XEP-220 example 34
		--if attr.from ~= origin.to_host then error("invalid-from"); end
		local type;
		if s2s_verify_dialback(attr.id, attr.from, attr.to, stanza[1]) then
			type = "valid"
		else
			type = "invalid"
			log("warn", "Asked to verify a dialback key that was incorrect. An imposter is claiming to be %s?", attr.to);
		end
		log("debug", "verifyied dialback key... it is %s", type);
		origin.sends2s(format("<db:verify from='%s' to='%s' id='%s' type='%s'>%s</db:verify>", attr.to, attr.from, attr.id, type, stanza[1]));
	end);

add_handler("s2sin_unauthed", "result", xmlns_dialback,
	function (origin, stanza)
		-- he wants to be identified through dialback
		-- We need to check the key with the Authoritative server
		local attr = stanza.attr;
		local attr = stanza.attr;
		origin.from_host = attr.from;
		origin.to_host = attr.to;
		origin.dialback_key = stanza[1];
		log("debug", "asking %s if key %s belongs to them", origin.from_host, origin.dialback_key);
		send_s2s(origin.to_host, origin.from_host,
			format("<db:verify from='%s' to='%s' id='%s'>%s</db:verify>", origin.to_host, origin.from_host,
				origin.streamid, origin.dialback_key));
		hosts[origin.from_host].dialback_verifying = origin;
	end);

add_handler({ "s2sout_unauthed", "s2sout" }, "verify", xmlns_dialback,
	function (origin, stanza)
		if origin.dialback_verifying then
			local valid;
			local attr = stanza.attr;
			if attr.type == "valid" then
				s2s_make_authenticated(origin.dialback_verifying);
				valid = "valid";
			else
				-- Warn the original connection that is was not verified successfully
				log("warn", "dialback for "..(origin.dialback_verifying.from_host or "(unknown)").." failed");
				valid = "invalid";
			end
			origin.dialback_verifying.sends2s(format("<db:result from='%s' to='%s' id='%s' type='%s'>%s</db:result>",
				attr.from, attr.to, attr.id, valid, origin.dialback_verifying.dialback_key));
		end
	end);

add_handler({ "s2sout_unauthed", "s2sout" }, "result", xmlns_dialback,
	function (origin, stanza)
		if stanza.attr.type == "valid" then
			s2s_make_authenticated(origin);
		else
			-- FIXME
			error("dialback failed!");
		end
	end);
