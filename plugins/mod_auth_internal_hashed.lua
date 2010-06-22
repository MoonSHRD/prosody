-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- Copyright (C) 2010 Jeff Mitchell
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local datamanager = require "util.datamanager";
local log = require "util.logger".init("auth_internal_hashed");
local type = type;
local error = error;
local ipairs = ipairs;
local hashes = require "util.hashes";
local jid_bare = require "util.jid".bare;
local getAuthenticationDatabaseSHA1 = require "util.sasl.scram".getAuthenticationDatabaseSHA1;
local config = require "core.configmanager";
local usermanager = require "core.usermanager";
local generate_uuid = require "util.uuid".generate;
local new_sasl = require "util.sasl".new;
local nodeprep = require "util.encodings".stringprep.nodeprep;
local hosts = hosts;

-- TODO: remove these two lines in near future
local hmac_sha1 = require "util.hmac".sha1;
local sha1 = require "util.hashes".sha1;

local prosody = _G.prosody;

-- Default; can be set per-user
local iteration_count = 4096;

function new_hashpass_provider(host)
	local provider = { name = "internal_hashed" };
	log("debug", "initializing hashpass authentication provider for host '%s'", host);

	function provider.test_password(username, password)
		local credentials = datamanager.load(username, host, "accounts") or {};
	
		if credentials.password ~= nil and string.len(credentials.password) ~= 0 then
			if credentials.password ~= password then
				return nil, "Auth failed. Provided password is incorrect.";
			end

			if provider.set_password(username, credentials.password) == nil then
				return nil, "Auth failed. Could not set hashed password from plaintext.";
			else
				return true;
			end
		end

		if credentials.iteration_count == nil or credentials.salt == nil or string.len(credentials.salt) == 0 then
			return nil, "Auth failed. Stored salt and iteration count information is not complete.";
		end
		
		-- convert hexpass to stored_key and server_key
		-- TODO: remove this in near future
		if credentials.hashpass then
			local salted_password = credentials.hashpass:gsub("..", function(x) return string.char(tonumber(x, 16)); end);
			credentials.stored_key = sha1(hmac_sha1(salted_password, "Client Key")):gsub(".", function (c) return ("%02x"):format(c:byte()); end);
			credentials.server_key = hmac_sha1(salted_password, "Server Key"):gsub(".", function (c) return ("%02x"):format(c:byte()); end);
			credentials.hashpass = nil
			datamanager.store(username, host, "accounts", credentials);
		end
		
		local valid, stored_key, server_key = getAuthenticationDatabaseSHA1(password, credentials.salt, credentials.iteration_count);
		
		local stored_key_hex = stored_key:gsub(".", function (c) return ("%02x"):format(c:byte()); end);
		local server_key_hex = server_key:gsub(".", function (c) return ("%02x"):format(c:byte()); end);
		
		if valid and stored_key_hex == credentials.stored_key and server_key_hex == credentials.server_key then
			return true;
		else
			return nil, "Auth failed. Invalid username, password, or password hash information.";
		end
	end

	function provider.set_password(username, password)
		local account = datamanager.load(username, host, "accounts");
		if account then
			account.salt = account.salt or generate_uuid();
			account.iteration_count = account.iteration_count or iteration_count;
			local valid, stored_key, server_key = getAuthenticationDatabaseSHA1(password, account.salt, account.iteration_count);
			local stored_key_hex = stored_key:gsub(".", function (c) return ("%02x"):format(c:byte()); end);
			local server_key_hex = server_key:gsub(".", function (c) return ("%02x"):format(c:byte()); end);
			
			account.stored_key = stored_key_hex
			account.server_key = server_key_hex

			account.password = nil;
			return datamanager.store(username, host, "accounts", account);
		end
		return nil, "Account not available.";
	end

	function provider.user_exists(username)
		local account = datamanager.load(username, host, "accounts");
		if not account then
			log("debug", "account not found for username '%s' at host '%s'", username, module.host);
			return nil, "Auth failed. Invalid username";
		end
		--[[if (account.hashpass == nil or string.len(account.hashpass) == 0) and (account.password == nil or string.len(account.password) == 0) then
			log("debug", "account password not set or zero-length for username '%s' at host '%s'", username, module.host);
			return nil, "Auth failed. Password invalid.";
		end]]
		return true;
	end

	function provider.create_user(username, password)
		local salt = generate_uuid();
		local valid, stored_key, server_key = getAuthenticationDatabaseSHA1(password, salt, iteration_count);
		local stored_key_hex = stored_key:gsub(".", function (c) return ("%02x"):format(c:byte()); end);
		local server_key_hex = server_key:gsub(".", function (c) return ("%02x"):format(c:byte()); end);
		return datamanager.store(username, host, "accounts", {stored_key = stored_key_hex, server_key = server_key_hex, salt = salt, iteration_count = iteration_count});
	end

	function provider.get_sasl_handler()
		local realm = module:get_option("sasl_realm") or module.host;
		local testpass_authentication_profile = {
			plain_test = function(username, password, realm)
				local prepped_username = nodeprep(username);
				if not prepped_username then
					log("debug", "NODEprep failed on username: %s", username);
					return "", nil;
				end
				return usermanager.test_password(prepped_username, password, realm), true;
			end,
			scram_sha_1 = function(username, realm)
				local credentials = datamanager.load(username, host, "accounts") or {};
				if credentials.password then
					usermanager.set_password(username, credentials.password, host);
					credentials = datamanager.load(username, host, "accounts") or {};
				end
				
				-- convert hexpass to stored_key and server_key
				-- TODO: remove this in near future
				if credentials.hashpass then
					local salted_password = credentials.hashpass:gsub("..", function(x) return string.char(tonumber(x, 16)); end);
					credentials.stored_key = sha1(hmac_sha1(salted_password, "Client Key")):gsub(".", function (c) return ("%02x"):format(c:byte()); end);
					credentials.server_key = hmac_sha1(salted_password, "Server Key"):gsub(".", function (c) return ("%02x"):format(c:byte()); end);
					credentials.hashpass = nil
					datamanager.store(username, host, "accounts", credentials);
				end
				
				local stored_key, server_key, iteration_count, salt = credentials.stored_key, credentials.server_key, credentials.iteration_count, credentials.salt;
				stored_key = stored_key and stored_key:gsub("..", function(x) return string.char(tonumber(x, 16)); end);
				server_key = server_key and server_key:gsub("..", function(x) return string.char(tonumber(x, 16)); end);
				return stored_key, server_key, iteration_count, salt, true;
			end
		};
		return new_sasl(realm, testpass_authentication_profile);
	end
	
	return provider;
end

module:add_item("auth-provider", new_hashpass_provider(module.host));

