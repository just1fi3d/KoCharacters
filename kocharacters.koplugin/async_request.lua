-- async_request.lua
-- Background HTTPS POST worker for KoCharacters async page extraction.
--
-- Must be invoked from /mnt/us/koreader/ so that setupkoenv.lua's relative
-- package paths resolve correctly.  The shell command in _processNextInQueue
-- does: cd /mnt/us/koreader && ./luajit <this_file> req_file url resp_file
--
-- arg[1] = path to request body JSON file
-- arg[2] = full Gemini API URL (including ?key=...)
-- arg[3] = path to write raw HTTP response body

local req_file  = arg[1]
local url       = arg[2]
local resp_file = arg[3]

if not req_file or not url or not resp_file then os.exit(1) end

local function write_error(path, msg)
    local f = io.open(path, "w")
    if f then
        local escaped = tostring(msg):gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n')
        f:write('{"error":{"code":0,"message":"Network error: ' .. escaped .. '"}}')
        f:close()
    end
end

-- Inherit KOReader's module environment (package.path, package.cpath, ffi overrides).
-- setupkoenv.lua uses relative paths, so the caller must cd to /mnt/us/koreader/ first.
local ok_env = pcall(dofile, "setupkoenv.lua")
if not ok_env then
    write_error(resp_file, "failed to load setupkoenv")
    os.exit(1)
end

local ok_https, https = pcall(require, "ssl.https")
local ok_ltn12, ltn12 = pcall(require, "ltn12")
if not ok_https or not ok_ltn12 then
    write_error(resp_file, "could not load ssl.https or ltn12")
    os.exit(1)
end

-- Read request body
local rf = io.open(req_file, "r")
if not rf then os.exit(1) end
local request_body = rf:read("*a")
rf:close()

-- Perform the blocking HTTPS POST (blocking is fine; we are a subprocess)
local response_body = {}
local ok, status = https.request({
    url    = url,
    method = "POST",
    headers = {
        ["Content-Type"]   = "application/json",
        ["Content-Length"] = tostring(#request_body),
    },
    source = ltn12.source.string(request_body),
    sink   = ltn12.sink.table(response_body),
})

local wf = io.open(resp_file, "w")
if not wf then os.exit(1) end

if not ok then
    write_error(resp_file, tostring(status))
else
    wf:write(table.concat(response_body))
end
wf:close()
