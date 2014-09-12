--[[
  OpenResty apps : Serving static contents from Zip file

  Depends on luarocks, luazip, penlight

  Inputs:
    zip_file => path to zip file
    zip_cachedir => directory of extracted files
    zip_path => path of file inside zip archive
    zip_redirect => set to 'on' if you want to serve existing extracted file without passing to lua; useful for content-range

  Example usage:
    - Without redirect:

	location ~ /assets/(?<zip_path>.*)$ {
		root /tmp/cache;
		set $zip_cachedir /tmp/cache;
		set $zip_file /tmp/assets.zip;
		content_by_lua_file "apps/zip.lua";
	}

    - With redirect:

	location @zip_server {
		content_by_lua_file "apps/zip.lua";
	}

	location ~ /assets/(?<zip_path>.*)$ {
		root /tmp/cache;
		set $zip_cachedir /tmp/cache;
		set $zip_file /tmp/assets.zip;
		set $zip_redirect on;
		try_files $uri @zip_server;
	}
--]]

local zip = require('zip')
local path = require('pl.path')
local dir = require('pl.dir')
local zip_file, zip_cachedir, zip_path = ngx.var.zip_file, ngx.var.zip_cachedir, ngx.var.zip_path
local redirect = ngx.var.zip_redirect == 'on'

local _, _, uri2dir = string.find(ngx.var.uri, '/(.+)/' .. zip_path)
local dest_dir = path.join(zip_cachedir, uri2dir, path.dirname(zip_path))
local dest_file = path.join(dest_dir, path.basename(zip_path))

local fx
local data
-- check existing file on cache
if path.isfile(dest_file) then
  fx = io.open(dest_file,"r")
  repeat
    data = fx:read(4096)
    if data then
      ngx.print(data)
      ngx.flush(true)
    end
  until data == nil
  ngx.exit(ngx.HTTP_OK)
end

-- no file on cache, read from zip
local zfile, err = zip.open(zip_file)
if err then
  ngx.exit(ngx.HTTP_NOT_FOUND)
end

local fi, err = zfile:open(zip_path)
if err then
  zfile:close()
  ngx.exit(ngx.HTTP_NOT_FOUND)
end

if not path.exists(dest_dir) then
  dir.makepath(dest_dir)
end

fx = io.open(dest_file,'w')

repeat
  data = fi:read(4096)
  if data then 
    fx:write(data)
    if not redirect then
      ngx.print(data)
      ngx.flush(true)
    end
  end
until data == nil

fi:close()
zfile:close()
fx:close()

if redirect then
  ngx.exec(ngx.var.request_uri)
end
