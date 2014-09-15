--[[
  OpenResty apps : Serving static contents from Zip file

  Depends on luarocks, lua-zip, penlight

  Inputs:
    zip_file => path to zip file
    zip_cachedir => directory of extracted files
    zip_path => path of file inside zip archive
    zip_redirect => set to 'on' if you want to serve existing extracted file without passing to lua

  Example usage:
    - Without redirect:

	location ~ /assets/(?<zip_path>.*)$ {
		root /tmp/cache;
		set $zip_cachedir /tmp/cache;
		set $zip_file /tmp/assets.zip;
		content_by_lua_file "apps/servezip.lua";
	}

    - With redirect:

	location @zip_server {
		content_by_lua_file "apps/servezip.lua";
	}

	location ~ /assets/(?<zip_path>.*)$ {
		root /tmp/cache;
		set $zip_cachedir /tmp/cache;
		set $zip_file /tmp/assets.zip;
		set $zip_redirect on;
		try_files $uri @zip_server;
	}
--]]
local zip = require('brimworks.zip')
local lfs = require('lfs')
local path = require('pl.path')
local dir = require('pl.dir')
local stringx = require('pl.stringx')
local restylock = require('resty.lock')

local BUFLEN = 4096
function getrange(rangehdr, filesize)
  if not rangehdr then
    ngx.header['Accept-Ranges']='bytes'
    return 0, filesize-1, false
  end

  local val = stringx.split(stringx.split(rangehdr,'=')[2],'-')
  local ofStart, ofEnd = tonumber(val[1]),tonumber(val[2])

  if not ofStart then
    -- ex:bytes=-10
    ofStart = filesize - ofEnd
    ofEnd = filesize - 1
  elseif not ofEnd then
    -- ex:bytes=39-
    ofEnd = filesize - 1
  end

  if ofEnd >= filesize then
    ofEnd = filesize - 1
  end

  if ofStart > ofEnd then
    ngx.header['Content-Range'] = 'bytes */'..filesize
    ngx.exit(416)
  end 

  ngx.header['Content-Range'] = 'bytes '.. ofStart ..'-'.. ofEnd ..'/'..filesize
  return ofStart, ofEnd, true 
end

local zip_file, zip_cachedir, zip_path = ngx.var.zip_file, ngx.var.zip_cachedir, ngx.var.zip_path
local redirect = ngx.var.zip_redirect == 'on'

local uri2dir = string.sub(stringx.replace(ngx.var.uri, zip_path, ''), 2)
local dest_dir = path.join(zip_cachedir, uri2dir, path.dirname(zip_path))
local dest_file = path.join(dest_dir, path.basename(zip_path))

local fx, data, ofStart, ofEnd, useRange

local lock = restylock:new('servezip.lock', {exptime=60, timeout=20})

-- check existing file on cache; with redirect on, this should never executed
if path.isfile(dest_file) then
  
  local ok, _ = lock:lock(dest_file)
  ofStart, ofEnd, useRange = getrange(ngx.req.get_headers()['Range'], path.getsize(dest_file))

  local attr = lfs.attributes(dest_file)
  ngx.header['Content-Length'] = ofEnd - ofStart + 1
  ngx.header['Last-Modified'] = ngx.http_time(attr.modification)
  if useRange then
    ngx.status = 206 -- Partial content
  end

  fx = io.open(dest_file,"r")
  fx:seek('set', ofStart)

  local szRead
  repeat
    szRead = BUFLEN
    if ofStart + BUFLEN - 1 > ofEnd then
      szRead = ofEnd - ofStart + 1
    end
    data = fx:read(szRead)
    if data then
      ngx.print(data)
      ngx.flush(true)
    end
    ofStart = ofStart + szRead
  until ofStart >= ofEnd
  fx:close()
  ok, _ = lock:unlock()
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

local stat = zfile:stat(zip_path)

-- prepare file cache
if not path.exists(dest_dir) then
  dir.makepath(dest_dir)
end

local ok, _ = lock:lock(dest_file)
fx = io.open(dest_file,'w')

-- redirect don't need any output from lua
if not redirect then
  ofStart, ofEnd, useRange = getrange(ngx.req.get_headers()['Range'], stat.size)
  ngx.header['Last-Modified'] = ngx.http_time(stat.mtime)
  ngx.header['Content-Length'] = ofEnd - ofStart + 1
  if useRange then
    ngx.status = 206 -- Partial content
  end
end

local ofCurr = 0
local beginOut, endOut = false, false
local szRead, pStart, pEnd
repeat
  szRead = BUFLEN
  if ofCurr + BUFLEN - 1 > stat.size then
    szRead = stat.size - ofCurr + 1
  end
  --ngx.log(ngx.ERR, string.format("fileSize, ofStart, ofCurr, ofEnd, szRead : %d, %d, %d, %d, %d", stat.size, ofStart, ofCurr, ofEnd, szRead))
  data = fi:read(szRead)
  if data then 
    fx:write(data)

    -- return portion of data for range request, while writing data to file cache
    if not redirect and not endOut then
      pStart = 0
      if not beginOut and ofCurr + szRead > ofStart then
        beginOut = true
        pStart = ofStart - ofCurr 
      end
      if beginOut then
        if ofCurr + szRead - 1 > ofEnd then
	  pEnd = ofEnd - ofCurr
          endOut = true
        else
          pEnd = szRead - 1
        end
        ngx.print(string.sub(data, pStart+1, pEnd+1))
        ngx.flush(true)
      end
    end

  end
  ofCurr = ofCurr + szRead
until ofCurr >= stat.size
fi:close()
zfile:close()

fx:close()
lfs.touch(dest_file, stat.mtime, stat.mtime)
local ok, _ = lock:unlock()

if redirect then
  ngx.exec(ngx.var.request_uri)
end
--ngx.log(ngx.ERR, "DONE")
