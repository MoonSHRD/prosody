-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--



local st = require "util.stanza";
local sm_bind_resource = require "core.sessionmanager".bind_resource;
local sm_make_authenticated = require "core.sessionmanager".make_authenticated;
local base64 = require "util.encodings".base64;

local nodeprep = require "util.encodings".stringprep.nodeprep;
local datamanager_load = require "util.datamanager".load;
local usermanager_validate_credentials = require "core.usermanager".validate_credentials;
local usermanager_get_supported_methods = require "core.usermanager".get_supported_methods;
local usermanager_user_exists = require "core.usermanager".user_exists;
local usermanager_get_password = require "core.usermanager".get_password;
local t_concat, t_insert = table.concat, table.insert;
local tostring = tostring;
local jid_split = require "util.jid".split;
local md5 = require "util.hashes".md5;
local config = require "core.configmanager";

local secure_auth_only = module:get_option("c2s_require_encryption") or module:get_option("require_encryption");
local sasl_backend = module:get_option("sasl_backend") or "builtin";

-- Cyrus config options
local require_provisioning = module:get_option("cyrus_require_provisioning") or false;
local cyrus_service_realm = module:get_option("cyrus_service_realm");
local cyrus_service_name = module:get_option("cyrus_service_name");
local cyrus_application_name = module:get_option("cyrus_application_name");

local log = module._log;

local xmlns_sasl ='urn:ietf:params:xml:ns:xmpp-sasl';
local xmlns_bind ='urn:ietf:params:xml:ns:xmpp-bind';
local xmlns_stanzas ='urn:ietf:params:xml:ns:xmpp-stanzas';

local new_sasl;
if sasl_backend == "builtin" then
	new_sasl = require "util.sasl".new;
elseif sasl_backend == "cyrus" then
	prosody.unlock_globals(); --FIXME: Figure out why this is needed and
	                          -- why cyrussasl isn't caught by the sandbox
	local ok, cyrus = pcall(require, "util.sasl_cyrus");
	prosody.lock_globals();
	if ok then
		local cyrus_new = cyrus.new;
		new_sasl = function(realm)
			return cyrus_new(
				cyrus_service_realm or realm,
				cyrus_service_name or "xmpp",
				cyrus_application_name or "prosody"
			);
		end
	else
		module:log("error", "Failed to load Cyrus SASL because: %s", cyrus);
		error("Failed to load Cyrus SASL");
	end
else
	module:log("error", "Unknown SASL backend: %s", sasl_backend);
	error("Unknown SASL backend");
end

local default_authentication_profile = {
	plain = function(username, realm)
		local prepped_username = nodeprep(username);
		if not prepped_username then
			log("debug", "NODEprep failed on username: %s", username);
			return "", nil;
		end
		local password = usermanager_get_password(prepped_username, realm);
		if not password then
			return "", nil;
		end
		return password, true;
	end
};

local anonymous_authentication_profile = {
	anonymous = function(username, realm)
		return true; -- for normal usage you should always return true here
	end
};

local function build_reply(status, ret, err_msg)
	local reply = st.stanza(status, {xmlns = xmlns_sasl});
	if status == "challenge" then
		--log("debug", "CHALLENGE: %s", ret or "");
		reply:text(base64.encode(ret or ""));
	elseif status == "failure" then
		reply:tag(ret):up();
		if err_msg then reply:tag("text"):text(err_msg); end
	elseif status == "success" then
		--log("debug", "SUCCESS: %s", ret or "");
		reply:text(base64.encode(ret or ""));
	else
		module:log("error", "Unknown sasl status: %s", status);
	end
	return reply;
end

local function handle_status(session, status, ret, err_msg)
	if status == "failure" then
		session.sasl_handler = session.sasl_handler:clean_clone();
	elseif status == "success" then
		local username = nodeprep(session.sasl_handler.username);

		if not(require_provisioning) or usermanager_user_exists(username, session.host) then
			local aret, err = sm_make_authenticated(session, session.sasl_handler.username);
			if aret then
				session.sasl_handler = nil;
				session:reset_stream();
			else
				module:log("warn", "SASL succeeded but username was invalid");
				session.sasl_handler = session.sasl_handler:clean_clone();
				return "failure", "not-authorized", "User authenticated successfully, but username was invalid";
			end
		else
			module:log("warn", "SASL succeeded but we don't have an account provisioned for %s", username);
			session.sasl_handler = session.sasl_handler:clean_clone();
			return "failure", "not-authorized", "User authenticated successfully, but not provisioned for XMPP";
		end
	end
	return status, ret, err_msg;
end

local function sasl_handler(session, stanza)
	if stanza.name == "auth" then
		-- FIXME ignoring duplicates because ejabberd does
		if config.get(session.host or "*", "core", "anonymous_login") then
			if stanza.attr.mechanism ~= "ANONYMOUS" then
				return session.send(build_reply("failure", "invalid-mechanism"));
			end
		elseif stanza.attr.mechanism == "ANONYMOUS" then
			return session.send(build_reply("failure", "mechanism-too-weak"));
		end
		local valid_mechanism = session.sasl_handler:select(stanza.attr.mechanism);
		if not valid_mechanism then
			return session.send(build_reply("failure", "invalid-mechanism"));
		end
		if secure_auth_only and not session.secure then
			return session.send(build_reply("failure", "encryption-required"));
		end
	elseif not session.sasl_handler then
		return; -- FIXME ignoring out of order stanzas because ejabberd does
	end
	local text = stanza[1];
	if text then
		text = base64.decode(text);
		--log("debug", "AUTH: %s", text:gsub("[%z\001-\008\011\012\014-\031]", " "));
		if not text then
			session.sasl_handler = nil;
			session.send(build_reply("failure", "incorrect-encoding"));
			return;
		end
	end
	local status, ret, err_msg = session.sasl_handler:process(text);
	status, ret, err_msg = handle_status(session, status, ret, err_msg);
	local s = build_reply(status, ret, err_msg);
	log("debug", "sasl reply: %s", tostring(s));
	session.send(s);
end

module:add_handler("c2s_unauthed", "auth", xmlns_sasl, sasl_handler);
module:add_handler("c2s_unauthed", "abort", xmlns_sasl, sasl_handler);
module:add_handler("c2s_unauthed", "response", xmlns_sasl, sasl_handler);

local mechanisms_attr = { xmlns='urn:ietf:params:xml:ns:xmpp-sasl' };
local bind_attr = { xmlns='urn:ietf:params:xml:ns:xmpp-bind' };
local xmpp_session_attr = { xmlns='urn:ietf:params:xml:ns:xmpp-session' };
module:hook("stream-features", function(event)
	local origin, features = event.origin, event.features;
	if not origin.username then
		if secure_auth_only and not origin.secure then
			return;
		end
		local realm = module:get_option("sasl_realm") or origin.host;
		if module:get_option("anonymous_login") then
			origin.sasl_handler = new_sasl(realm, anonymous_authentication_profile);
		else
			origin.sasl_handler = new_sasl(realm, default_authentication_profile);
			if not (module:get_option("allow_unencrypted_plain_auth")) and not origin.secure then
				origin.sasl_handler:forbidden({"PLAIN"});
			end
		end
		features:tag("mechanisms", mechanisms_attr);
		for k, v in pairs(origin.sasl_handler:mechanisms()) do
			features:tag("mechanism"):text(v):up();
		end
		features:up();
	else
		features:tag("bind", bind_attr):tag("required"):up():up();
		features:tag("session", xmpp_session_attr):tag("optional"):up():up();
	end
end);

module:add_iq_handler("c2s", "urn:ietf:params:xml:ns:xmpp-bind", function(session, stanza)
	log("debug", "Client requesting a resource bind");
	local resource;
	if stanza.attr.type == "set" then
		local bind = stanza.tags[1];
		if bind and bind.attr.xmlns == xmlns_bind then
			resource = bind:child_with_name("resource");
			if resource then
				resource = resource[1];
			end
		end
	end
	local success, err_type, err, err_msg = sm_bind_resource(session, resource);
	if not success then
		session.send(st.error_reply(stanza, err_type, err, err_msg));
	else
		session.send(st.reply(stanza)
			:tag("bind", { xmlns = xmlns_bind})
			:tag("jid"):text(session.full_jid));
	end
end);

module:add_iq_handler("c2s", "urn:ietf:params:xml:ns:xmpp-session", function(session, stanza)
	log("debug", "Client requesting a session");
	session.send(st.reply(stanza));
end);
