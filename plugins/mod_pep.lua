local pubsub = require "util.pubsub";
local jid_bare = require "util.jid".bare;
local jid_split = require "util.jid".split;
local jid_join = require "util.jid".join;
local set_new = require "util.set".new;
local st = require "util.stanza";
local calculate_hash = require "util.caps".calculate_hash;
local is_contact_subscribed = require "core.rostermanager".is_contact_subscribed;
local cache = require "util.cache";
local set = require "util.set";

local xmlns_pubsub = "http://jabber.org/protocol/pubsub";
local xmlns_pubsub_event = "http://jabber.org/protocol/pubsub#event";
local xmlns_pubsub_owner = "http://jabber.org/protocol/pubsub#owner";

local lib_pubsub = module:require "pubsub";

local empty_set = set_new();

-- username -> util.pubsub service object
local services = {};

-- username -> recipient -> set of nodes
local recipients = {};

-- caps hash -> set of nodes
local hash_map = {};

local host = module.host;

local node_config = module:open_store("pep", "map");
local known_nodes = module:open_store("pep");

local max_max_items = module:get_option_number("pep_max_items", 256);

function module.save()
	return {
		services = services;
		recipients = recipients;
	};
end

function module.restore(data)
	services = data.services;
	recipients = data.recipients;
end

function is_item_stanza(item)
	return st.is_stanza(item) and item.attr.xmlns == xmlns_pubsub and item.name == "item";
end

function check_node_config(node, actor, new_config) -- luacheck: ignore 212/node 212/actor
	if (new_config["max_items"] or 1) > max_max_items then
		return false;
	end
	if new_config["access_model"] ~= "presence"
	and new_config["access_model"] ~= "whitelist"
	and new_config["access_model"] ~= "open" then
		return false;
	end
	return true;
end

local function subscription_presence(username, recipient)
	local user_bare = jid_join(username, host);
	local recipient_bare = jid_bare(recipient);
	if (recipient_bare == user_bare) then return true; end
	return is_contact_subscribed(username, host, recipient_bare);
end

local function nodestore(username)
	-- luacheck: ignore 212/self
	local store = {};
	function store:get(node)
		local data, err = node_config:get(username, node)
		if data == true then
			-- COMPAT Previously stored only a boolean representing 'persist_items'
			data = {
				name = node;
				config = {};
				subscribers = {};
				affiliations = {};
			};
		end
		return data, err;
	end
	function store:set(node, data)
		if data then
			-- Save the data without subscriptions
			local subscribers = {};
			for jid, sub in pairs(data.subscribers) do
				if type(sub) ~= "table" or not sub.presence then
					subscribers[jid] = sub;
				end
			end
			data = {
				name = data.name;
				config = data.config;
				affiliations = data.affiliations;
				subscribers = subscribers;
			};
		end
		return node_config:set(username, node, data);
	end
	function store:users()
		return pairs(known_nodes:get(username) or {});
	end
	return store;
end

local function simple_itemstore(username)
	return function (config, node)
		if config["persist_items"] then
			module:log("debug", "Creating new persistent item store for user %s, node %q", username, node);
			local archive = module:open_store("pep_"..node, "archive");
			return lib_pubsub.archive_itemstore(archive, config, username, node, false);
		else
			module:log("debug", "Creating new ephemeral item store for user %s, node %q", username, node);
			return cache.new(tonumber(config["max_items"]));
		end
	end
end

local function get_broadcaster(username)
	local user_bare = jid_join(username, host);
	local function simple_broadcast(kind, node, jids, item, _, node_obj)
		if node_obj then
			if node_obj.config["notify_"..kind] == false then
				return;
			end
		end
		if kind == "retract" then
			kind = "items"; -- XEP-0060 signals retraction in an <items> container
		end
		local message = st.message({ from = user_bare, type = "headline" })
			:tag("event", { xmlns = xmlns_pubsub_event })
				:tag(kind, { node = node });
		if item then
			item = st.clone(item);
			item.attr.xmlns = nil; -- Clear the pubsub namespace
			if kind == "items" then
				if node_obj and node_obj.config.include_payload == false then
					item:maptags(function () return nil; end);
				end
			end
			message:add_child(item);
		end
		for jid in pairs(jids) do
			module:log("debug", "Sending notification to %s from %s: %s", jid, user_bare, tostring(item));
			message.attr.to = jid;
			module:send(message);
		end
	end
	return simple_broadcast;
end

function get_pep_service(username)
	module:log("debug", "get_pep_service(%q)", username);
	local user_bare = jid_join(username, host);
	local service = services[username];
	if service then
		return service;
	end
	service = pubsub.new({
		node_defaults = {
			["max_items"] = 1;
			["persist_items"] = true;
			["access_model"] = "presence";
		};

		autocreate_on_publish = true;
		autocreate_on_subscribe = true;

		nodestore = nodestore(username);
		itemstore = simple_itemstore(username);
		broadcaster = get_broadcaster(username);
		itemcheck = is_item_stanza;
		get_affiliation = function (jid)
			if jid_bare(jid) == user_bare then
				return "owner";
			end
		end;

		access_models = {
			presence = function (jid)
				if subscription_presence(username, jid) then
					return "member";
				end
				return "outcast";
			end;
		};

		normalize_jid = jid_bare;

		check_node_config = check_node_config;
	});
	local nodes, err = known_nodes:get(username);
	if nodes then
		module:log("debug", "Restoring nodes for user %s", username);
		for node in pairs(nodes) do
			module:log("debug", "Restoring node %q", node);
			service:create(node, true);
		end
	elseif err then
		module:log("error", "Could not restore nodes for %s: %s", username, err);
	else
		module:log("debug", "No known nodes");
	end
	services[username] = service;
	module:add_item("pep-service", { service = service, jid = user_bare });
	return service;
end

function handle_pubsub_iq(event)
	local origin, stanza = event.origin, event.stanza;
	local service_name = origin.username;
	if stanza.attr.to ~= nil then
		service_name = jid_split(stanza.attr.to);
	end
	local service = get_pep_service(service_name);

	return lib_pubsub.handle_pubsub_iq(event, service)
end

module:hook("iq/bare/"..xmlns_pubsub..":pubsub", handle_pubsub_iq);
module:hook("iq/bare/"..xmlns_pubsub_owner..":pubsub", handle_pubsub_iq);

module:add_identity("pubsub", "pep", module:get_option_string("name", "Prosody"));
module:add_feature("http://jabber.org/protocol/pubsub#publish");

local function get_caps_hash_from_presence(stanza, current)
	local t = stanza.attr.type;
	if not t then
		local child = stanza:get_child("c", "http://jabber.org/protocol/caps");
		if child then
			local attr = child.attr;
			if attr.hash then -- new caps
				if attr.hash == 'sha-1' and attr.node and attr.ver then
					return attr.ver, attr.node.."#"..attr.ver;
				end
			else -- legacy caps
				if attr.node and attr.ver then
					return attr.node.."#"..attr.ver.."#"..(attr.ext or ""), attr.node.."#"..attr.ver;
				end
			end
		end
		return; -- no or bad caps
	elseif t == "unavailable" or t == "error" then
		return;
	end
	return current; -- no caps, could mean caps optimization, so return current
end

local function resend_last_item(jid, node, service)
	local ok, id, item = service:get_last_item(node, jid);
	if not ok then return; end
	if not id then return; end
	service.config.broadcaster("items", node, { [jid] = true }, item);
end

local function update_subscriptions(recipient, service_name, nodes)
	nodes = nodes or empty_set;

	local service_recipients = recipients[service_name];
	if not service_recipients then
		service_recipients = {};
		recipients[service_name] = service_recipients;
	end

	local current = service_recipients[recipient];
	if not current or type(current) ~= "table" then
		current = empty_set;
	end

	if (current == empty_set or current:empty()) and (nodes == empty_set or nodes:empty()) then
		return;
	end

	local service = get_pep_service(service_name);
	for node in current - nodes do
		service:remove_subscription(node, recipient, recipient);
	end

	for node in nodes - current do
		if service:add_subscription(node, recipient, recipient, { presence = true }) then
			resend_last_item(recipient, node, service);
		end
	end

	if nodes == empty_set or nodes:empty() then
		nodes = nil;
	end

	service_recipients[recipient] = nodes;
end

module:hook("presence/bare", function(event)
	-- inbound presence to bare JID received
	local origin, stanza = event.origin, event.stanza;
	local t = stanza.attr.type;
	local is_self = not stanza.attr.to;
	local username = jid_split(stanza.attr.to);
	local user_bare = jid_bare(stanza.attr.to);
	if is_self then
		username = origin.username;
		user_bare = jid_join(username, host);
	end

	if not t then -- available presence
		if is_self or subscription_presence(username, stanza.attr.from) then
			local recipient = stanza.attr.from;
			local current = recipients[username] and recipients[username][recipient];
			local hash, query_node = get_caps_hash_from_presence(stanza, current);
			if current == hash or (current and current == hash_map[hash]) then return; end
			if not hash then
				update_subscriptions(recipient, username);
			else
				recipients[username] = recipients[username] or {};
				if hash_map[hash] then
					update_subscriptions(recipient, username, hash_map[hash]);
				else
					recipients[username][recipient] = hash;
					local from_bare = origin.type == "c2s" and origin.username.."@"..origin.host;
					if is_self or origin.type ~= "c2s" or (recipients[from_bare] and recipients[from_bare][origin.full_jid]) ~= hash then
						-- COMPAT from ~= stanza.attr.to because OneTeam can't deal with missing from attribute
						origin.send(
							st.stanza("iq", {from=user_bare, to=stanza.attr.from, id="disco", type="get"})
								:tag("query", {xmlns = "http://jabber.org/protocol/disco#info", node = query_node})
						);
					end
				end
			end
		end
	elseif t == "unavailable" then
		update_subscriptions(stanza.attr.from, username);
	elseif not is_self and t == "unsubscribe" then
		local from = jid_bare(stanza.attr.from);
		local subscriptions = recipients[username];
		if subscriptions then
			for subscriber in pairs(subscriptions) do
				if jid_bare(subscriber) == from then
					update_subscriptions(subscriber, username);
				end
			end
		end
	end
end, 10);

module:hook("iq-result/bare/disco", function(event)
	local origin, stanza = event.origin, event.stanza;
	local disco = stanza:get_child("query", "http://jabber.org/protocol/disco#info");
	if not disco then
		return;
	end

	-- Process disco response
	local is_self = stanza.attr.to == nil;
	local user_bare = jid_bare(stanza.attr.to);
	local username = jid_split(stanza.attr.to);
	if is_self then
		username = origin.username;
		user_bare = jid_join(username, host);
	end
	local contact = stanza.attr.from;
	local current = recipients[username] and recipients[username][contact];
	if type(current) ~= "string" then return; end -- check if waiting for recipient's response
	local ver = current;
	if not string.find(current, "#") then
		ver = calculate_hash(disco.tags); -- calculate hash
	end
	local notify = set_new();
	for _, feature in pairs(disco.tags) do
		if feature.name == "feature" and feature.attr.var then
			local nfeature = feature.attr.var:match("^(.*)%+notify$");
			if nfeature then notify:add(nfeature); end
		end
	end
	hash_map[ver] = notify; -- update hash map
	if is_self then
		-- Optimization: Fiddle with other local users
		for jid, item in pairs(origin.roster) do -- for all interested contacts
			if jid then
				local contact_node, contact_host = jid_split(jid);
				if contact_host == host and (item.subscription == "both" or item.subscription == "from") then
					update_subscriptions(user_bare, contact_node, notify);
				end
			end
		end
	end
	update_subscriptions(contact, username, notify);
end);

module:hook("account-disco-info-node", function(event)
	local stanza, origin = event.stanza, event.origin;
	local service_name = origin.username;
	if stanza.attr.to ~= nil then
		service_name = jid_split(stanza.attr.to);
	end
	local service = get_pep_service(service_name);
	return lib_pubsub.handle_disco_info_node(event, service);
end);

module:hook("account-disco-info", function(event)
	local origin, reply = event.origin, event.reply;

	reply:tag('identity', {category='pubsub', type='pep'}):up();

	local username = jid_split(reply.attr.from) or origin.username;
	local service = get_pep_service(username);

	local supported_features = lib_pubsub.get_feature_set(service) + set.new{
		-- Features not covered by the above
		"access-presence",
		"auto-subscribe",
		"filtered-notifications",
		"last-published",
		"persistent-items",
		"presence-notifications",
		"presence-subscribe",
	};

	for feature in supported_features do
		reply:tag('feature', {var=xmlns_pubsub.."#"..feature}):up();
	end
end);

module:hook("account-disco-items-node", function(event)
	local stanza, origin = event.stanza, event.origin;
	local is_self = stanza.attr.to == nil;
	local username = jid_split(stanza.attr.to);
	if is_self then
		username = origin.username;
	end
	local service = get_pep_service(username);
	return lib_pubsub.handle_disco_items_node(event, service);
end);

module:hook("account-disco-items", function(event)
	local reply, stanza, origin = event.reply, event.stanza, event.origin;

	local is_self = stanza.attr.to == nil;
	local user_bare = jid_bare(stanza.attr.to);
	local username = jid_split(stanza.attr.to);
	if is_self then
		username = origin.username;
		user_bare = jid_join(username, host);
	end
	local service = get_pep_service(username);

	local ok, ret = service:get_nodes(jid_bare(stanza.attr.from));
	if not ok then return; end

	for node, node_obj in pairs(ret) do
		reply:tag("item", { jid = user_bare, node = node, name = node_obj.config.name }):up();
	end
end);
