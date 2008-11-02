
-- The code in this file should be self-explanatory, though the logic is horrible
-- for more info on that, see doc/stanza_routing.txt, which attempts to condense
-- the rules from the RFCs (mainly 3921)

require "core.servermanager"

local log = require "util.logger".init("stanzarouter")

local st = require "util.stanza";
local send_s2s = require "core.s2smanager".send_to_host;
local user_exists = require "core.usermanager".user_exists;

local rostermanager = require "core.rostermanager";
local sessionmanager = require "core.sessionmanager";

local s2s_verify_dialback = require "core.s2smanager".verify_dialback;
local s2s_make_authenticated = require "core.s2smanager".make_authenticated;

local modules_handle_stanza = require "core.modulemanager".handle_stanza;

local format = string.format;
local tostring = tostring;
local t_concat = table.concat;
local t_insert = table.insert;
local tonumber = tonumber;
local s_find = string.find;

local jid_split = require "util.jid".split;
local print = print;

function core_process_stanza(origin, stanza)
	log("debug", "Received["..origin.type.."]: "..tostring(stanza))
	-- TODO verify validity of stanza (as well as JID validity)
	if stanza.name == "iq" and not(#stanza.tags == 1 and stanza.tags[1].attr.xmlns) then
		if stanza.attr.type == "set" or stanza.attr.type == "get" then
			error("Invalid IQ");
		elseif #stanza.tags > 1 and not(stanza.attr.type == "error" or stanza.attr.type == "result") then
			error("Invalid IQ");
		end
	end

	if origin.type == "c2s" and not origin.full_jid
		and not(stanza.name == "iq" and stanza.tags[1].name == "bind"
				and stanza.tags[1].attr.xmlns == "urn:ietf:params:xml:ns:xmpp-bind") then
		error("Client MUST bind resource after auth");
	end

	local to = stanza.attr.to;
	-- TODO also, stazas should be returned to their original state before the function ends
	if origin.type == "c2s" then
		stanza.attr.from = origin.full_jid; -- quick fix to prevent impersonation (FIXME this would be incorrect when the origin is not c2s)
	end
	
	if not to then
		core_handle_stanza(origin, stanza);
	elseif origin.type == "c2s" and stanza.name == "presence" and stanza.attr.type ~= nil and stanza.attr.type ~= "unavailable" then
		local node, host = jid_split(stanza.attr.to);
		local to_bare = node and (node.."@"..host) or host; -- bare JID
		local from_node, from_host = jid_split(stanza.attr.from);
		local from_bare = from_node and (from_node.."@"..from_host) or from_host; -- bare JID
		handle_outbound_presence_subscriptions_and_probes(origin, stanza, from_bare, to_bare);
	elseif hosts[to] and hosts[to].type == "local" then
		core_handle_stanza(origin, stanza);
	elseif stanza.name == "iq" and not select(3, jid_split(to)) then
		core_handle_stanza(origin, stanza);
	elseif stanza.attr.xmlns and stanza.attr.xmlns ~= "jabber:client" and stanza.attr.xmlns ~= "jabber:server" then
		modules_handle_stanza(origin, stanza);
	elseif origin.type == "c2s" or origin.type == "s2sin" then
		core_route_stanza(origin, stanza);
	end
end

-- This function handles stanzas which are not routed any further,
-- that is, they are handled by this server
function core_handle_stanza(origin, stanza)
	-- Handlers
	if modules_handle_stanza(origin, stanza) then return; end
	if origin.type == "c2s" or origin.type == "c2s_unauthed" then
		local session = origin;
		
		if stanza.name == "presence" and origin.roster then
			if stanza.attr.type == nil or stanza.attr.type == "unavailable" then
				for jid in pairs(origin.roster) do -- broadcast to all interested contacts
					local subscription = origin.roster[jid].subscription;
					if subscription == "both" or subscription == "from" then
						stanza.attr.to = jid;
						core_route_stanza(origin, stanza);
					end
				end
				local node, host = jid_split(stanza.attr.from);
				for _, res in pairs(hosts[host].sessions[node].sessions) do -- broadcast to all resources
					if res ~= origin and res.full_jid then -- to resource. FIXME is res.full_jid the correct check? Maybe it should be res.presence
						stanza.attr.to = res.full_jid;
						core_route_stanza(origin, stanza);
					end
				end
				if stanza.attr.type == nil and not origin.presence then -- initial presence
					local probe = st.presence({from = origin.full_jid, type = "probe"});
					for jid in pairs(origin.roster) do -- probe all contacts we are subscribed to
						local subscription = origin.roster[jid].subscription;
						if subscription == "both" or subscription == "to" then
							probe.attr.to = jid;
							core_route_stanza(origin, probe);
						end
					end
					for _, res in pairs(hosts[host].sessions[node].sessions) do -- broadcast from all available resources
						if res ~= origin and res.presence then
							res.presence.attr.to = origin.full_jid;
							core_route_stanza(res, res.presence);
							res.presence.attr.to = nil;
						end
					end
					if origin.roster.pending then -- resend incoming subscription requests
						for jid in pairs(origin.roster.pending) do
							origin.send(st.presence({type="subscribe", from=jid})); -- TODO add to attribute? Use original?
						end
					end
					local request = st.presence({type="subscribe", from=origin.username.."@"..origin.host});
					for jid, item in pairs(origin.roster) do -- resend outgoing subscription requests
						if item.ask then
							request.attr.to = jid;
							core_route_stanza(origin, request);
						end
					end
				end
				origin.priority = 0;
				if stanza.attr.type == "unavailable" then
					origin.presence = nil;
				else
					origin.presence = stanza;
					local priority = stanza:child_with_name("priority");
					if priority and #priority > 0 then
						priority = t_concat(priority);
						if s_find(priority, "^[+-]?[0-9]+$") then
							priority = tonumber(priority);
							if priority < -128 then priority = -128 end
							if priority > 127 then priority = 127 end
							origin.priority = priority;
						end
					end
				end
				stanza.attr.to = nil; -- reset it
			else
				-- TODO error, bad type
			end
		end
	else
		log("warn", "Unhandled origin: %s", origin.type);
	end
end

function send_presence_of_available_resources(user, host, jid, recipient_session)
	local h = hosts[host];
	local count = 0;
	if h and h.type == "local" then
		local u = h.sessions[user];
		if u then
			for k, session in pairs(u.sessions) do
				local pres = session.presence;
				if pres then
					pres.attr.to = jid;
					pres.attr.from = session.full_jid;
					recipient_session.send(pres);
					pres.attr.to = nil;
					pres.attr.from = nil;
					count = count + 1;
				end
			end
		end
	end
	return count;
end

function handle_outbound_presence_subscriptions_and_probes(origin, stanza, from_bare, to_bare)
	local node, host = jid_split(from_bare);
	local st_from, st_to = stanza.attr.from, stanza.attr.to;
	stanza.attr.from, stanza.attr.to = from_bare, to_bare;
	if stanza.attr.type == "subscribe" then
		log("debug", "outbound subscribe from "..from_bare.." for "..to_bare);
		-- 1. route stanza
		-- 2. roster push (subscription = none, ask = subscribe)
		if rostermanager.set_contact_pending_out(node, host, to_bare) then
			rostermanager.roster_push(node, host, to_bare);
		end -- else file error
		core_route_stanza(origin, stanza);
	elseif stanza.attr.type == "unsubscribe" then
		log("debug", "outbound unsubscribe from "..from_bare.." for "..to_bare);
		-- 1. route stanza
		-- 2. roster push (subscription = none or from)
		if rostermanager.unsubscribe(node, host, to_bare) then
			rostermanager.roster_push(node, host, to_bare); -- FIXME do roster push when roster has in fact not changed?
		end -- else file error
		core_route_stanza(origin, stanza);
	elseif stanza.attr.type == "subscribed" then
		log("debug", "outbound subscribed from "..from_bare.." for "..to_bare);
		-- 1. route stanza
		-- 2. roster_push ()
		-- 3. send_presence_of_available_resources
		if rostermanager.subscribed(node, host, to_bare) then
			rostermanager.roster_push(node, host, to_bare);
			core_route_stanza(origin, stanza);
			send_presence_of_available_resources(node, host, to_bare, origin);
		end
	elseif stanza.attr.type == "unsubscribed" then
		log("debug", "outbound unsubscribed from "..from_bare.." for "..to_bare);
		-- 1. route stanza
		-- 2. roster push (subscription = none or to)
		if rostermanager.unsubscribed(node, host, to_bare) then
			rostermanager.roster_push(node, host, to_bare);
			core_route_stanza(origin, stanza);
		end
	end
	stanza.attr.from, stanza.attr.to = st_from, st_to;
end

function handle_inbound_presence_subscriptions_and_probes(origin, stanza, from_bare, to_bare)
	local node, host = jid_split(to_bare);
	local st_from, st_to = stanza.attr.from, stanza.attr.to;
	stanza.attr.from, stanza.attr.to = from_bare, to_bare;
	if stanza.attr.type == "probe" then
		log("debug", "inbound probe from "..from_bare.." for "..to_bare);
		if rostermanager.is_contact_subscribed(node, host, from_bare) then
			if 0 == send_presence_of_available_resources(node, host, from_bare, origin) then
				-- TODO send last recieved unavailable presence (or we MAY do nothing, which is fine too)
			end
		else
			core_route_stanza(origin, st.presence({from=to_bare, to=from_bare, type="unsubscribed"}));
		end
	elseif stanza.attr.type == "subscribe" then
		log("debug", "inbound subscribe from "..from_bare.." for "..to_bare);
		if rostermanager.is_contact_subscribed(node, host, from_bare) then
			core_route_stanza(origin, st.presence({from=to_bare, to=from_bare, type="subscribed"})); -- already subscribed
		else
			if not rostermanager.is_contact_pending_in(node, host, from_bare) then
				if rostermanager.set_contact_pending_in(node, host, from_bare) then
					sessionmanager.send_to_available_resources(node, host, stanza);
				end -- TODO else return error, unable to save
			end
		end
	elseif stanza.attr.type == "unsubscribe" then
		log("debug", "inbound unsubscribe from "..from_bare.." for "..to_bare);
		if rostermanager.process_inbound_unsubscribe(node, host, from_bare) then
			rostermanager.roster_push(node, host, from_bare);
		end
	elseif stanza.attr.type == "subscribed" then
		log("debug", "inbound subscribed from "..from_bare.." for "..to_bare);
		if rostermanager.process_inbound_subscription_approval(node, host, from_bare) then
			rostermanager.roster_push(node, host, from_bare);
		end
	elseif stanza.attr.type == "unsubscribed" then
		log("debug", "inbound unsubscribed from "..from_bare.." for "..to_bare);
		if rostermanager.process_inbound_subscription_approval(node, host, from_bare) then
			rostermanager.roster_push(node, host, from_bare);
		end
	end -- discard any other type
	stanza.attr.from, stanza.attr.to = st_from, st_to;
end

function core_route_stanza(origin, stanza)
	-- Hooks
	--- ...later
	
	-- Deliver
	local to = stanza.attr.to;
	local node, host, resource = jid_split(to);
	local to_bare = node and (node.."@"..host) or host; -- bare JID
	local from = stanza.attr.from;
	local from_node, from_host, from_resource = jid_split(from);
	local from_bare = from_node and (from_node.."@"..from_host) or from_host; -- bare JID

	if stanza.name == "presence" and (stanza.attr.type ~= nil and stanza.attr.type ~= "unavailable") then resource = nil; end

	local host_session = hosts[host]
	if host_session and host_session.type == "local" then
		-- Local host
		local user = host_session.sessions[node];
		if user then
			local res = user.sessions[resource];
			if not res then
				-- if we get here, resource was not specified or was unavailable
				if stanza.name == "presence" then
					if stanza.attr.type ~= nil and stanza.attr.type ~= "unavailable" then
						handle_inbound_presence_subscriptions_and_probes(origin, stanza, from_bare, to_bare);
					else -- sender is available or unavailable
						for _, session in pairs(user.sessions) do -- presence broadcast to all user resources.
							if session.full_jid then -- FIXME should this be just for available resources? Do we need to check subscription?
								stanza.attr.to = session.full_jid; -- reset at the end of function
								session.send(stanza);
							end
						end
					end
				elseif stanza.name == "message" then -- select a resource to recieve message
					local priority = 0;
					local recipients = {};
					for _, session in pairs(user.sessions) do -- find resource with greatest priority
						local p = session.priority;
						if p > priority then
							priority = p;
							recipients = {session};
						elseif p == priority then
							t_insert(recipients, session);
						end
					end
					for _, session in pairs(recipient) do
						session.send(stanza);
					end
				else
					-- TODO send IQ error
				end
			else
				-- User + resource is online...
				stanza.attr.to = res.full_jid; -- reset at the end of function
				res.send(stanza); -- Yay \o/
			end
		else
			-- user not online
			if user_exists(node, host) then
				if stanza.name == "presence" then
					if stanza.attr.type ~= nil and stanza.attr.type ~= "unavailable" then
						handle_inbound_presence_subscriptions_and_probes(origin, stanza, from_bare, to_bare);
					else
						-- TODO send unavailable presence or unsubscribed
					end
				elseif stanza.name == "message" then
					-- TODO send message error, or store offline messages
				elseif stanza.name == "iq" then
					-- TODO send IQ error
				end
			else -- user does not exist
				-- TODO we would get here for nodeless JIDs too. Do something fun maybe? Echo service? Let plugins use xmpp:server/resource addresses?
				if stanza.name == "presence" then
					if stanza.attr.type == "probe" then
						origin.send(st.presence({from = to_bare, to = from_bare, type = "unsubscribed"}));
					end
					-- else ignore
				else
					origin.send(st.error_reply(stanza, "cancel", "service-unavailable"));
				end
			end
		end
	elseif origin.type == "c2s" then
		-- Remote host
		local xmlns = stanza.attr.xmlns;
		--stanza.attr.xmlns = "jabber:server";
		stanza.attr.xmlns = nil;
		log("debug", "sending s2s stanza: %s", tostring(stanza));
		send_s2s(origin.host, host, stanza); -- TODO handle remote routing errors
		stanza.attr.xmlns = xmlns; -- reset
	else
		log("warn", "received stanza from unhandled connection type: %s", origin.type);
	end
	stanza.attr.to = to; -- reset
end

function handle_stanza_toremote(stanza)
	log("error", "Stanza bound for remote host, but s2s is not implemented");
end
