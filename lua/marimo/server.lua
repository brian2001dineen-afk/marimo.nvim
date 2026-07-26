--- server.lua
--- Locates a running marimo server and retrieves its auth token.
--- Also provides start()/stop() to manage a marimo process launched by the plugin.
---
--- Detection strategy (in order):
---   1. Use config.opts.port if explicitly set.
---   2. Scan /proc/<pid>/cmdline for processes running `marimo edit` and
---      extract the --port argument (Linux).
---   3. Fall back to scanning listener tables via `ss`/`lsof`.
---   4. Try the default marimo port (2718).

local M = {}

local config = require("marimo.config")
local util = require("marimo.util")

local DEFAULT_PORT = 2718
local PID_FILE = vim.fn.stdpath("state") .. "/marimo.nvim.pid"

--- Handle for the marimo process started by M.start(), nil when not running.
--- @type uv_process_t|nil
local _proc = nil

--- PID for the marimo process started by M.start(), if known.
--- @type integer|nil
local _proc_pid = nil

--- Persist the managed marimo pid so :MarimoStop still works after restarting
--- Neovim.
--- @param pid integer
local function write_pid_file(pid)
	vim.fn.mkdir(vim.fn.stdpath("state"), "p")
	vim.fn.writefile({ tostring(pid) }, PID_FILE)
end

--- Read the last managed marimo pid, if any.
--- @return integer|nil
local function read_pid_file()
	if vim.fn.filereadable(PID_FILE) == 0 then
		return nil
	end
	local lines = vim.fn.readfile(PID_FILE)
	local pid = tonumber(lines[1])
	return pid
end

--- Remove the managed marimo pid file.
local function clear_pid_file()
	if vim.fn.filereadable(PID_FILE) == 1 then
		vim.fn.delete(PID_FILE)
	end
end

--- Return true if a pid currently exists.
--- @param pid integer
--- @return boolean
local function pid_is_alive(pid)
	return pcall(vim.uv.kill, pid, 0)
end

--- Best-effort process tree walk (Linux /proc).
--- Returns all descendants (children, grandchildren, ...) of root pid.
--- @param root_pid integer
--- @return integer[]
local function collect_descendants(root_pid)
	if vim.fn.isdirectory("/proc") == 0 then
		return {}
	end

	local children_by_parent = {}
	local status_files = vim.fn.glob("/proc/*/status", false, true)
	for _, path in ipairs(status_files) do
		local f = io.open(path, "r")
		if f then
			local text = f:read("*a") or ""
			f:close()
			local pid = tonumber(text:match("\nPid:%s*(%d+)")) or tonumber(text:match("^Pid:%s*(%d+)"))
			local ppid = tonumber(text:match("\nPPid:%s*(%d+)")) or tonumber(text:match("^PPid:%s*(%d+)"))
			if pid and ppid then
				children_by_parent[ppid] = children_by_parent[ppid] or {}
				table.insert(children_by_parent[ppid], pid)
			end
		end
	end

	local out = {}
	local queue = { root_pid }
	local head = 1
	while head <= #queue do
		local parent = queue[head]
		head = head + 1
		local kids = children_by_parent[parent] or {}
		for _, child in ipairs(kids) do
			table.insert(out, child)
			table.insert(queue, child)
		end
	end

	return out
end

--- Best-effort cmdline lookup for a pid.
--- @param pid integer
--- @return string|nil
local function get_cmdline(pid)
	if vim.fn.filereadable(string.format("/proc/%d/cmdline", pid)) == 0 then
		if vim.system then
			local out = vim.system({ "ps", "-p", tostring(pid), "-o", "command=" }, { text = true }):wait()
			if out.code ~= 0 then
				return nil
			end
			return vim.trim(out.stdout or "")
		end
		return nil
	end

	local f = io.open(string.format("/proc/%d/cmdline", pid), "rb")
	if not f then
		return nil
	end

	local raw = f:read("*a") or ""
	f:close()
	return raw:gsub("%z", " ")
end

--- Best-effort validation that a pid still looks like a marimo edit process.
--- @param pid integer
--- @return boolean
local function is_marimo_pid(pid)
	local cmdline = get_cmdline(pid)
	if not cmdline or cmdline == "" then
		return true
	end
	return cmdline:match("marimo") ~= nil and cmdline:match("edit") ~= nil
end

--- Send termination signals to a managed marimo process.
--- Attempts to terminate the process group first (for kernels/workers), then
--- falls back to the main pid.
--- @param pid integer
--- @return boolean
local function stop_pid(pid)
	if not pid or not pid_is_alive(pid) then
		clear_pid_file()
		return false
	end
	if not is_marimo_pid(pid) then
		return false
	end

	local descendants = collect_descendants(pid)

	for _, child_pid in ipairs(descendants) do
		pcall(vim.uv.kill, child_pid, "sigterm")
	end

	-- If marimo was started as a detached process group leader, signaling -pid
	-- reaches kernel/worker descendants too.
	pcall(vim.uv.kill, -pid, "sigterm")
	pcall(vim.uv.kill, pid, "sigterm")
	vim.defer_fn(function()
		for _, child_pid in ipairs(descendants) do
			if pid_is_alive(child_pid) then
				pcall(vim.uv.kill, child_pid, "sigkill")
			end
		end
		if pid_is_alive(pid) then
			pcall(vim.uv.kill, -pid, "sigkill")
			pcall(vim.uv.kill, pid, "sigkill")
		end
		if not pid_is_alive(pid) then
			clear_pid_file()
		end
	end, 1500)
	return true
end

--- Generate a random token string suitable for use as --token-password.
--- @return string
local function generate_token()
	local seed = tostring(os.time()) .. tostring(math.random(1e9))
	return vim.fn.sha256(seed):sub(1, 32)
end

--- Resolve the command used to launch marimo.
--- @return string|nil executable
--- @return string[] prefix_args
local function resolve_marimo_command()
	if type(config.opts.marimo_bin) == "string" and config.opts.marimo_bin ~= "" then
		return config.opts.marimo_bin, {}
	end

	if type(config.opts.marimo_project) == "string" and config.opts.marimo_project ~= "" then
		return "/usr/bin/uv", {
			"run",
			"--project",
			config.opts.marimo_project,
			"marimo",
		}
	end

	local marimo_bin = vim.fn.exepath("marimo")
	if marimo_bin ~= "" then
		return marimo_bin, {}
	end

	return nil, {}
end

--- Use a browser-friendly host for local URLs.
--- @param host string
--- @return string
local function browser_host(host)
	if host == "0.0.0.0" or host == "::" then
		return "127.0.0.1"
	end
	return host
end

--- Attempt to contact the marimo server to confirm it is alive.
--- Uses GET /api/version with an optional `access_token` for auth
--- @param host string
--- @param port integer
--- @param access_token string|nil
--- @return boolean ok
--- @return string|nil err
local function ping(host, port, access_token)
	local url
	if access_token ~= nil and access_token ~= "" then
		access_token = util.uri_encode(access_token)
		url = string.format("http://%s:%d/api/version?access_token=%s", host, port, access_token)
	else
		url = string.format("http://%s:%d/api/version", host, port)
	end
	local ok
	if vim.system then
		local out = vim.system({ "curl", "-sf", "--max-time", "2", url }):wait()
		ok = out.code == 0
	else
		local handle = io.popen(string.format("curl -sf --max-time 2 '%s'", url))
		if handle then
			local result = handle:read("*a")
			handle:close()
			ok = result ~= nil and result ~= ""
		end
	end

	if not ok then
		return false, string.format("marimo server not reachable at %s:%d", host, port)
	end

	return true, nil
end

--- Scan /proc for a running `marimo edit` process and return its --port value.
--- Returns nil if not found or /proc is unavailable.
--- @return integer|nil
local function detect_port_from_proc()
	if vim.fn.isdirectory("/proc") == 0 then
		return nil
	end

	local pids = vim.fn.glob("/proc/*/cmdline", false, true)
	for _, path in ipairs(pids) do
		local f = io.open(path, "rb")
		if f then
			local raw = f:read("*a")
			f:close()
			local cmdline = raw:gsub("%z", " ")
			if cmdline:match("marimo") and cmdline:match("edit") then
				local port = cmdline:match("%-%-port[= ](%d+)")
				if port then
					return tonumber(port)
				end
			end
		end
	end

	return nil
end

--- Scan `ss -ltnp` for a running marimo process and return its listening port.
--- @return integer|nil
local function detect_port_from_ss()
	if vim.fn.executable("ss") ~= 1 or not vim.system then
		return nil
	end

	local out = vim.system({ "ss", "-ltnp" }, { text = true }):wait()
	if out.code ~= 0 then
		return nil
	end

	for line in (out.stdout or ""):gmatch("[^\r\n]+") do
		if line:match("marimo") then
			local pid = line:match("pid=(%d+)")
			local port = line:match(":(%d+)")
			if pid and port and is_marimo_pid(tonumber(pid)) then
				return tonumber(port)
			end
		end
	end

	return nil
end

--- Scan `lsof` listeners for a running marimo process and return its port.
--- @return integer|nil
local function detect_port_from_lsof()
	if vim.fn.executable("lsof") ~= 1 or not vim.system then
		return nil
	end

	local out = vim.system({ "lsof", "-nP", "-iTCP", "-sTCP:LISTEN" }, { text = true }):wait()
	if out.code ~= 0 then
		return nil
	end

	for line in (out.stdout or ""):gmatch("[^\r\n]+") do
		if line:match("marimo") then
			local pid = line:match("^%S+%s+(%d+)%s")
			local port = line:match(":(%d+)%s*%(")
			if pid and port and is_marimo_pid(tonumber(pid)) then
				return tonumber(port)
			end
		end
	end

	return nil
end

--- Find the port of a running marimo server.
--- @return integer port
local function resolve_port()
	if config.opts.port then
		return config.opts.port
	end

	local proc_port = detect_port_from_proc()
	if proc_port then
		return proc_port
	end

	local ss_port = detect_port_from_ss()
	if ss_port then
		return ss_port
	end

	local lsof_port = detect_port_from_lsof()
	if lsof_port then
		return lsof_port
	end

	return DEFAULT_PORT
end

--- Fetch the skew-protection token embedded in the marimo HTML page.
--- The server embeds it as `data-token="<value>"` in the root HTML.
--- Returns empty string if the fetch fails (e.g. `--no-token` server with
--- no skew protection, though marimo still requires the header).
--- @param host string
--- @param port integer
--- @param file_path string|nil  Optional: include ?file= for the notebook page
--- @param access_token string|nil  Optional: include ?access_token= for auth-protected servers
--- @return string server_token (may be empty string)
local function fetch_server_token(host, port, file_path, access_token)
	local url = string.format("http://%s:%d/", host, port)
	local params = {}
	if file_path then
		table.insert(params, "file=" .. util.uri_encode(file_path))
	end
	if access_token and access_token ~= "" then
		table.insert(params, "access_token=" .. util.uri_encode(access_token))
	end
	if #params > 0 then
		url = url .. "?" .. table.concat(params, "&")
	end
	local html = ""
	if vim.system then
		-- -sL: silent, follow redirects
		-- -c/-b: cookie jar so the 303 redirect (which strips ?access_token
		-- for security) carries the session cookie to the target page.
		local cookie_file = vim.fn.tempname()
		vim.fn.writefile({}, cookie_file)
		local out = vim.system({
			"curl", "-sL", "--max-time", "5",
			"-c", cookie_file,
			"-b", cookie_file,
			url,
		}):wait()
		pcall(vim.fn.delete, cookie_file)
		if out.code ~= 0 then
			return ""
		end
		html = out.stdout or ""
	else
		local handle = io.popen(string.format("curl -sL --max-time 5 '%s'", url))
		if not handle then
			return ""
		end
		html = handle:read("*a") or ""
		handle:close()
	end
	local server_token = html:match('data%-token="([^"]+)"')
	return server_token or ""
end

--- Connect to an already-running marimo server and return a connection descriptor.
--- @param notebook_path string|nil  Optional: absolute path to the notebook, used to fetch the server token
--- @return {host: string, port: integer, token: string, server_token: string}|nil
--- @return string|nil  error message
function M.connect(notebook_path)
	local host = config.opts.host or "127.0.0.1"
	local port = resolve_port()
	local access_token = config.opts.access_token
	local server_token = config.opts.server_token or ""
	local ok, err = ping(host, port, access_token)
	if not ok then
		return nil, err
	end
	if server_token == "" then
		server_token = fetch_server_token(host, port, notebook_path, access_token)
	end
	return { host = host, port = port, token = access_token or "", server_token = server_token }, nil
end

--- Build the browser URL for a notebook in kiosk mode.
--- @param conn {host: string, port: integer, token: string}
--- @param file_path string
--- @return string
function M.browser_url(conn, file_path)
	local params = {
		"file=" .. util.uri_encode(file_path),
		"kiosk=true",
	}
	if conn.token and conn.token ~= "" then
		table.insert(params, "access_token=" .. util.uri_encode(conn.token))
	end

	return string.format("http://%s:%d/?%s", browser_host(conn.host), conn.port, table.concat(params, "&"))
end

--- Open a notebook URL in the user's browser.
--- @param conn {host: string, port: integer, token: string}
--- @param file_path string
--- @return string url
--- @return string|nil err
function M.open_browser(conn, file_path)
	local url = M.browser_url(conn, file_path)

	if vim.ui and vim.ui.open then
		local ok, open_err = vim.ui.open(url)
		if ok then
			return url, nil
		end
		return url, tostring(open_err)
	end

	local opener
	if vim.fn.executable("xdg-open") == 1 then
		opener = { "xdg-open", url }
	elseif vim.fn.has("mac") == 1 and vim.fn.executable("open") == 1 then
		opener = { "open", url }
	elseif vim.fn.has("win32") == 1 then
		opener = { "cmd", "/c", "start", "", url }
	end

	if not opener then
		return url, "could not find a browser opener; open the URL manually"
	end

	vim.fn.jobstart(opener, { detach = true })
	return url, nil
end

--- Return true if a marimo server is already reachable on the resolved port.
--- @return boolean
function M.is_running()
	local host = config.opts.host or "127.0.0.1"
	local port = resolve_port()
	local ok, _ = ping(host, port, nil)
	return ok
end

--- Start a marimo server for the given file and call back with the connection.
---
--- Generates a token, passes it to marimo via --token-password so auth is
--- known up front — no stdout parsing required.  Polls /api/version every
--- 500 ms for up to 20 s, then calls back with the connection or an error.
---
--- @param file_path string   Absolute path to the notebook .py file.
--- @param callback  fun(conn: table|nil, err: string|nil)
function M.start(file_path, callback)
	if _proc then
		callback(nil, "a marimo process is already managed by the plugin (call MarimoStop first)")
		return
	end

	local marimo_bin, prefix_args = resolve_marimo_command()
	if not marimo_bin then
		callback(nil, "could not find marimo; set `marimo_project`, set `marimo_bin`, or install `marimo` on PATH")
		return
	end

	local host = config.opts.host or "127.0.0.1"
	local port = config.opts.port or DEFAULT_PORT
	local token = generate_token()
	local exited = false
	local exit_code = 0
	local stderr_chunks = {}
	local done = false

	local function finish(conn, err)
		if done then
			return
		end
		done = true
		callback(conn, err)
	end

	local args = vim.list_extend(prefix_args, {
		"edit",
		"--host",
		host,
		"--port",
		tostring(port),
		"--token-password",
		token,
		"--no-skew-protection",
		"--watch", -- reload kernel when the file changes on disk (BufWritePost)
		"--headless",
	})
	table.insert(args, file_path)

	local handle
	local stderr_pipe = assert(vim.uv.new_pipe())
	handle = vim.uv.spawn(marimo_bin, {
		args = args,
		detached = true,
		stdio = { nil, nil, stderr_pipe },
	}, function(code, _signal)
		exited = true
		exit_code = code
		if stderr_pipe and not stderr_pipe:is_closing() then
			stderr_pipe:read_stop()
			stderr_pipe:close()
		end
		if handle and not handle:is_closing() then
			handle:close()
		end
		if _proc == handle then
			_proc = nil
		end
		if _proc_pid == handle:get_pid() then
			_proc_pid = nil
			clear_pid_file()
		end
		if code ~= 0 then
			vim.schedule(function()
				local stderr_text = vim.trim(table.concat(stderr_chunks, ""))
				if stderr_text ~= "" then
					finish(nil, string.format("server process exited with code %d: %s", code, stderr_text))
				else
					finish(nil, "server process exited with code " .. code)
				end
			end)
		end
	end)

	if not handle then
		stderr_pipe:close()
		callback(nil, "failed to spawn marimo process")
		return
	end

	stderr_pipe:read_start(function(_, data)
		if not data then
			return
		end
		table.insert(stderr_chunks, data)
		if #stderr_chunks > 20 then
			table.remove(stderr_chunks, 1)
		end
	end)

	_proc = handle
	_proc_pid = handle:get_pid()
	write_pid_file(_proc_pid)

	vim.api.nvim_create_autocmd("VimLeavePre", {
		once = true,
		callback = function()
			M.stop()
		end,
	})

	local tries = 0
	local max_tries = 40 -- 40 × 500 ms = 20 s

	local function poll()
		if done then
			return
		end
		tries = tries + 1
		if exited then
			local stderr_text = vim.trim(table.concat(stderr_chunks, ""))
			if stderr_text ~= "" then
				finish(nil, string.format("server process exited with code %d: %s", exit_code, stderr_text))
			else
				finish(nil, "server process exited with code " .. exit_code)
			end
			return
		end
		local ok, _ = ping(host, port, token)
		if ok then
			local server_token = fetch_server_token(host, port, file_path, token)
			finish({ host = host, port = port, token = token, server_token = server_token }, nil)
			return
		end
		if tries >= max_tries then
			M.stop()
			finish(
				nil,
				string.format("marimo server did not become ready after %d s on port %d", max_tries * 0.5, port)
			)
			return
		end
		vim.defer_fn(poll, 500)
	end

	vim.defer_fn(poll, 500)
end

--- Kill the marimo process started by M.start(), if any.
--- @return boolean stopped
function M.stop()
	local pid = _proc_pid or read_pid_file()
	local stopped = false

	if pid then
		stopped = stop_pid(pid)
	else
		clear_pid_file()
	end

	if _proc and not _proc:is_closing() then
		pcall(_proc.kill, _proc, "sigterm")
		_proc:close()
	end
	_proc = nil
	_proc_pid = nil

	return stopped
end

return M
