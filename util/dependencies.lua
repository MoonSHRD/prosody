-- Prosody IM
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

module("dependencies", package.seeall)

function softreq(...) local ok, lib =  pcall(require, ...); if ok then return lib; else return nil, lib; end end

function missingdep(name, sources, msg)
	print("");
	print("**************************");
	print("Prosody was unable to find "..tostring(name));
	print("This package can be obtained in the following ways:");
	print("");
	local longest_platform = 0;
	for platform in pairs(sources) do
		longest_platform = math.max(longest_platform, #platform);
	end
	for platform, source in pairs(sources) do
		print("", platform..":"..(" "):rep(4+longest_platform-#platform)..source);
	end
	print("");
	print(msg or (name.." is required for Prosody to run, so we will now exit."));
	print("More help can be found on our website, at http://prosody.im/doc/depends");
	print("**************************");
	print("");
end

function check_dependencies()
	local fatal;
	
	local lxp = softreq "lxp"
	
	if not lxp then
		missingdep("luaexpat", {
				["Debian/Ubuntu"] = "sudo apt-get install liblua5.1-expat0";
				["luarocks"] = "luarocks install luaexpat";
				["Source"] = "http://www.keplerproject.org/luaexpat/";
			});
		fatal = true;
	end
	
	local socket = softreq "socket"
	
	if not socket then
		missingdep("luasocket", {
				["Debian/Ubuntu"] = "sudo apt-get install liblua5.1-socket2";
				["luarocks"] = "luarocks install luasocket";
				["Source"] = "http://www.tecgraf.puc-rio.br/~diego/professional/luasocket/";
			});
		fatal = true;
	end
	
	local lfs, err = softreq "lfs"
	if not lfs then
		missingdep("luafilesystem", {
				["luarocks"] = "luarocks install luafilesystem";
		 		["Debian/Ubuntu"] = "sudo apt-get install liblua5.1-filesystem0";
		 		["Source"] = "http://www.keplerproject.org/luafilesystem/";
		 	});
		fatal = true;
	end
	
	local ssl = softreq "ssl"
	
	if not ssl then
		if config.get("*", "core", "run_without_ssl") then
			log("warn", "Running without SSL support because run_without_ssl is defined in the config");
		else
			missingdep("LuaSec", {
					["Debian/Ubuntu"] = "http://prosody.im/download/start#debian_and_ubuntu";
					["luarocks"] = "luarocks install luasec";
					["Source"] = "http://www.inf.puc-rio.br/~brunoos/luasec/";
				}, "SSL/TLS support will not be available");
		end
	else
		local major, minor, veryminor, patched = ssl._VERSION:match("(%d+)%.(%d+)%.?(%d*)(M?)");
		if not major or ((tonumber(major) == 0 and (tonumber(minor) or 0) <= 3 and (tonumber(veryminor) or 0) <= 2) and patched ~= "M") then
			log("error", "This version of LuaSec contains a known bug that causes disconnects, see http://prosody.im/doc/depends");
		end
	end
	
	local encodings, err = softreq "util.encodings"
	if not encodings then
		if err:match("not found") then
			missingdep("util.encodings", { ["Windows"] = "Make sure you have encodings.dll from the Prosody distribution in util/";
		 				["GNU/Linux"] = "Run './configure' and 'make' in the Prosody source directory to build util/encodings.so";
		 			});
		else
			print "***********************************"
			print("util/encodings couldn't be loaded. Check that you have a recent version of libidn");
			print ""
			print("The full error was:");
			print(err)
			print "***********************************"
		end
		fatal = true;
	end

	local hashes, err = softreq "util.hashes"
	if not hashes then
		if err:match("not found") then
			missingdep("util.hashes", { ["Windows"] = "Make sure you have hashes.dll from the Prosody distribution in util/";
		 				["GNU/Linux"] = "Run './configure' and 'make' in the Prosody source directory to build util/hashes.so";
		 			});
	 	else
			print "***********************************"
			print("util/hashes couldn't be loaded. Check that you have a recent version of OpenSSL (libcrypto in particular)");
			print ""
			print("The full error was:");
			print(err)
			print "***********************************"
		end
		fatal = true;
	end
	return not fatal;
end


return _M;
