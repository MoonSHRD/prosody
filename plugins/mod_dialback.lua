-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local format = string.format;

local hosts = _G.hosts;
local s2s_make_authenticated = require "core.s2smanager".make_authenticated;

local log = module._log;

local st = require "util.stanza";
local sha256_hash = require "util.hashes".sha256;

local xmlns_stream = "http://etherx.jabber.org/streams";
local xmlns_dialback = "jabber:server:dialback";

local dialback_requests = setmetatable({}, { __mode = 'v' });

function generate_dialback(id, to, from)
	return sha256_hash(id..to..from..hosts[from].dialback_secret, true);
end

function initiate_dialback(session)
	-- generate dialback key
	session.dialback_key = generate_dialback(session.streamid, session.to_host, session.from_host);
	session.sends2s(format("<db:result from='%s' to='%s'>%s</db:result>", session.from_host, session.to_host, session.dialback_key));
	session.log("info", "sent dialback key on outgoing s2s stream");
end

function verify_dialback(id, to, from, key)
	return key == generate_dialback(id, to, from);
end

module:hook("stanza/jabber:server:dialback:verify", function(event)
	local origin, stanza = event.origin, event.stanza;
	
	if origin.type == "s2sin_unauthed" or origin.type == "s2sin" then
		-- We are being asked to verify the key, to ensure it was generated by us
		origin.log("debug", "verifying that dialback key is ours...");
		local attr = stanza.attr;
		-- COMPAT: Grr, ejabberd breaks this one too?? it is black and white in XEP-220 example 34
		--if attr.from ~= origin.to_host then error("invalid-from"); end
		local type;
		if verify_dialback(attr.id, attr.from, attr.to, stanza[1]) then
			type = "valid"
		else
			type = "invalid"
			origin.log("warn", "Asked to verify a dialback key that was incorrect. An imposter is claiming to be %s?", attr.to);
		end
		origin.log("debug", "verified dialback key... it is %s", type);
		origin.sends2s(st.stanza("db:verify", { from = attr.to, to = attr.from, id = attr.id, type = type }):text(stanza[1]));
		return true;
	end
end);

module:hook("stanza/jabber:server:dialback:result", function(event)
	local origin, stanza = event.origin, event.stanza;
	
	if origin.type == "s2sin_unauthed" or origin.type == "s2sin" then
		-- he wants to be identified through dialback
		-- We need to check the key with the Authoritative server
		local attr = stanza.attr;
		origin.hosts[attr.from] = { dialback_key = stanza[1] };
		
		if not hosts[attr.to] then
			-- Not a host that we serve
			origin.log("info", "%s tried to connect to %s, which we don't serve", attr.from, attr.to);
			origin:close("host-unknown");
			return true;
		end
		
		dialback_requests[attr.from.."/"..origin.streamid] = origin;
		
		if not origin.from_host then
			-- Just used for friendlier logging
			origin.from_host = attr.from;
		end
		if not origin.to_host then
			-- Just used for friendlier logging
			origin.to_host = attr.to;
		end
		
		origin.log("debug", "asking %s if key %s belongs to them", attr.from, stanza[1]);
		origin.send(st.stanza("db:verify", { from = attr.to, to = attr.from, id = origin.streamid }):text(stanza[1]));
		return true;
	end
end);

module:hook("stanza/jabber:server:dialback:verify", function(event)
	local origin, stanza = event.origin, event.stanza;
	
	if origin.type == "s2sout_unauthed" or origin.type == "s2sout" then
		local attr = stanza.attr;
		local dialback_verifying = dialback_requests[attr.from.."/"..(attr.id or "")];
		module:log("debug", tostring(dialback_verifying).." "..attr.from.." "..origin.to_host);
		if dialback_verifying and attr.from == origin.to_host then
			local valid;
			if attr.type == "valid" then
				s2s_make_authenticated(dialback_verifying, attr.from);
				valid = "valid";
			else
				-- Warn the original connection that is was not verified successfully
				log("warn", "authoritative server for "..(attr.from or "(unknown)").." denied the key");
				valid = "invalid";
			end
			if not dialback_verifying.sends2s then
				log("warn", "Incoming s2s session %s was closed in the meantime, so we can't notify it of the db result", tostring(dialback_verifying):match("%w+$"));
			else
				dialback_verifying.sends2s(
						st.stanza("db:result", { from = attr.to, to = attr.from, id = attr.id, type = valid })
								:text(dialback_verifying.hosts[attr.from].dialback_key));
			end
			dialback_requests[attr.from.."/"..(attr.id or "")] = nil;
		end
		return true;
	end
end);

module:hook("stanza/jabber:server:dialback:result", function(event)
	local origin, stanza = event.origin, event.stanza;
	
	if origin.type == "s2sout_unauthed" or origin.type == "s2sout" then
		-- Remote server is telling us whether we passed dialback
		
		local attr = stanza.attr;
		if not hosts[attr.to] then
			origin:close("host-unknown");
			return true;
		elseif hosts[attr.to].s2sout[attr.from] ~= origin then
			-- This isn't right
			origin:close("invalid-id");
			return true;
		end
		if stanza.attr.type == "valid" then
			s2s_make_authenticated(origin, attr.from);
		else
			origin:close("not-authorized", "dialback authentication failed");
		end
		return true;
	end
end);

module:hook_stanza("urn:ietf:params:xml:ns:xmpp-sasl", "failure", function (origin, stanza)
	if origin.external_auth == "failed" then
		module:log("debug", "SASL EXTERNAL failed, falling back to dialback");
		initiate_dialback(origin);
		return true;
	end
end, 100);

module:hook_stanza(xmlns_stream, "features", function (origin, stanza)
	if not origin.external_auth or origin.external_auth == "failed" then
		initiate_dialback(origin);
		return true;
	end
end, 100);

-- Offer dialback to incoming hosts
module:hook("s2s-stream-features", function (data)
	data.features:tag("dialback", { xmlns='urn:xmpp:features:dialback' }):up();
end);
