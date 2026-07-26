--- session.lua
--- Manages the connection to a running marimo server for a single notebook file.
---
--- Responsibilities:
---   1. Spawn websocat as a stdio subprocess to bridge the WebSocket connection (Neovim has no built-in WebSocket client).
---   2. Connect to ws://<host>:<port>/ws?session_id=<uuid>&file=<path>
---   3. Parse the kernel-ready message to build an ordered cell_id list.
---   4. Expose focus_cell(index) which POSTs to /api/kernel/focus_cell.
---   5. Expose refresh() to re-request kernel-ready after a file save.
---
--- One Session object is created per attached buffer.

local M = {}
M.__index = M

local config = require("marimo.config")
local util = require("marimo.util")

-- Helpers

--- Generate a marimo-compatible session_id.
--- The frontend validates against /^s_[\da-z]{6}$/ and only reuses the id
--- from the URL if it passes — so we must match that exact format.
--- @return string
local function new_session_id()
	local chars = "0123456789abcdefghijklmnopqrstuvwxyz"
	local result = "s_"
	for _ = 1, 6 do
		local i = math.random(1, #chars)
		result = result .. chars:sub(i, i)
	end
	return result
end

--- Find websocat binary: config override -> PATH.
--- @return string|nil
local function find_websocat()
	if config.opts.websocat_bin then
		return config.opts.websocat_bin
	end
	-- vim.fn.exepath returns '' when not found.
	local found = vim.fn.exepath("websocat")
	if found ~= "" then
		return found
	end
	return nil
end

--- Build the URL for a kernel HTTP endpoint.
--- @param path string
--- @return string
local function kernel_url(self, path)
	local url = string.format("http://%s:%d%s", self.conn.host, self.conn.port, path)
	if self.conn.token and self.conn.token ~= "" then
		url = url .. "?access_token=" .. self.conn.token
	end
	return url
end

--- POST a JSON payload to a kernel endpoint and report curl + HTTP status.
--- @param path string
--- @param payload table
--- @param on_done fun(out: table, status: integer|nil, body: string)
local function post_kernel_json(self, path, payload, on_done)
	vim.system({
		"curl",
		"-sS",
		"-X",
		"POST",
		"-H",
		"Content-Type: application/json",
		"-H",
		"Marimo-Session-Id: " .. self.session_id,
		"-H",
		"Marimo-Server-Token: " .. (self.conn.server_token or ""),
		"-d",
		vim.json.encode(payload),
		"-w",
		"\n%{http_code}",
		kernel_url(self, path),
	}, { text = true }, function(out)
		local stdout = out.stdout or ""
		local body, status = stdout:match("^(.*)\n(%d%d%d)%s*$")
		status = tonumber(status)
		if not body then
			body = stdout
		end
		on_done(out, status, body)
	end)
end

--- Create a new Session for the given connection descriptor and notebook path.
---
--- @param conn {host: string, port: integer, token: string}
--- @param notebook_path string  absolute path to the .py notebook file
--- @return table  Session object
function M.new(conn, notebook_path)
	local self = setmetatable({}, M)
	self.conn = conn
	self.notebook_path = notebook_path
	self.session_id = new_session_id()
	self.cell_ids = {} -- ordered list: cell_ids[i] = marimo CellId (1-based)
	self.ready = false -- true once kernel-ready has been parsed
	self.closed = false

	-- websocat subprocess handles
	self._ws_handle = nil
	self._stdin_pipe = nil
	self._stdout_pipe = nil
	self._stderr_pipe = nil
	self._read_buffer = ""

	-- Callbacks registered by events.lua
	self._on_ready = nil -- called when cell_ids is populated / refreshed
	self._retry_count = 0 -- reconnect attempts since last successful connect
	self._kiosk = false -- switched to true if browser is already connected
	self._connect_gen = 0 -- incremented each connect(); EOF ignores stale generations
	self._focus_cell_supported = nil -- nil=unknown, false=endpoint missing

	return self
end

-- Internal: WebSocket I/O

--- Write a newline-terminated JSON message to websocat stdin (→ WebSocket).
--- @param msg table
function M:_send(msg)
	if self.closed or not self._stdin_pipe then
		return
	end
	local line = vim.json.encode(msg) .. "\n"
	self._stdin_pipe:write(line)
end

--- Dispatch a fully-assembled JSON message received from the server.
--- @param msg table
function M:_handle_message(msg)
	if msg.op == "kernel-ready" then
		local data = msg.data or {}
		self.cell_ids = data.cell_ids or {}
		self._retry_count = 0 -- reset on successful connection
		self.ready = true
		vim.defer_fn(function()
			if self._on_ready then
				self._on_ready(self.cell_ids)
			end
		end, 0)
	end
	-- Future: handle 'update-cell-ids' (cell reordering) here.
end

--- Process raw data arriving from websocat stdout.
--- Messages are newline-delimited JSON; reads may be fragmented.
--- @param data string
function M:_on_data(data)
	self._read_buffer = self._read_buffer .. data
	local s = self._read_buffer:find("\n")
	while s do
		local line = self._read_buffer:sub(1, s - 1)
		self._read_buffer = self._read_buffer:sub(s + 1)
		s = self._read_buffer:find("\n")

		if line ~= "" then
			local ok, msg = pcall(vim.json.decode, line)
			if ok and type(msg) == "table" then
				self:_handle_message(msg)
			end
		end
	end
end

-- Public: connect / close

--- Start the websocat subprocess and connect to the marimo WebSocket.
--- Calls on_ready(cell_ids) once kernel-ready is received.
---
--- @param on_ready fun(cell_ids: string[])|nil
--- @return string|nil  error message (nil = success)
function M:connect(on_ready)
	local websocat = find_websocat()
	if not websocat then
		return "websocat not found. Install it (cargo install websocat) and ensure it is on PATH, "
			.. 'or set vim.g.marimo_websocat_bin / require("marimo").setup({ websocat_bin = "..." }).'
	end

	self._on_ready = on_ready

	-- Bump the generation counter so any in-flight EOF handlers from the
	-- previous connect() call know they are stale and must not trigger a retry.
	self._connect_gen = self._connect_gen + 1
	local my_gen = self._connect_gen

	-- First attempt: connect as a regular session so marimo creates one if
	-- none exists yet.  If a browser is already connected, marimo closes the
	-- socket with MARIMO_ALREADY_CONNECTED; the stderr handler flips
	-- self._kiosk to true so the next retry uses kiosk mode instead.
	local kiosk_suffix = self._kiosk and "&kiosk=true" or ""
	local ws_url = string.format(
		"ws://%s:%d/ws?session_id=%s&file=%s&access_token=%s%s",
		self.conn.host,
		self.conn.port,
		self.session_id,
		util.uri_encode(self.notebook_path),
		self.conn.token,
		kiosk_suffix
	)

	local stdin_pipe = assert(vim.uv.new_pipe())
	local stdout_pipe = assert(vim.uv.new_pipe())
	local stderr_pipe = assert(vim.uv.new_pipe())

	local args = {
		"-B",
		"10485760", -- 10 MiB max message size
		"--origin",
		string.format("http://%s:%d", self.conn.host, self.conn.port),
		ws_url,
	}

	local handle
	handle = vim.uv.spawn(websocat, {
		args = args,
		stdio = { stdin_pipe, stdout_pipe, stderr_pipe },
	}, function(_code, _signal)
		if handle and not handle:is_closing() then
			handle:close()
		end
	end)

	if not handle then
		stdin_pipe:close()
		stdout_pipe:close()
		stderr_pipe:close()
		return "failed to spawn websocat"
	end

	self._ws_handle = handle
	self._stdin_pipe = stdin_pipe
	self._stdout_pipe = stdout_pipe
	self._stderr_pipe = stderr_pipe

	if self._kiosk then
		-- Kiosk mode: keep stdin open so websocat stays alive and the consumer
		-- remains registered. The server streams live updates over this connection.
	else
		-- Non-kiosk (main) connection: keep stdin open too, so the consumer
		-- stays registered with EDITOR capabilities (required for HTTP API
		-- calls like run_cell). The server closes the connection only if a
		-- browser already holds the main slot (MARIMO_ALREADY_CONNECTED).
	end

	local received_data = false -- did we get any data before EOF this attempt?

	-- Read stdout → parse messages
	stdout_pipe:read_start(function(err, data)
		if err then
			vim.schedule(function()
				if not self.closed then
					vim.notify("[marimo] WebSocket read error: " .. tostring(err), vim.log.levels.WARN)
				end
			end)
		elseif data then
			received_data = true
			vim.schedule(function()
				self:_on_data(data)
			end)
		else
			-- EOF: server closed the connection.
			vim.schedule(function()
				-- Ignore EOF from a superseded connect() call.
				if self.closed or my_gen ~= self._connect_gen then
					return
				end

				if self._kiosk then
					-- Unexpected kiosk disconnect (server restart, etc).
					-- Reconnect without resetting ready so focus_cell keeps working.
					self:_teardown_kiosk()
					self._read_buffer = ""
					vim.defer_fn(function()
						if not self.closed then
							self:connect(self._on_ready)
						end
					end, 1000)
					return
				end

				-- Non-kiosk (main) disconnect.
				if not received_data then
					-- Rejected immediately: a browser already holds the main slot.
					-- Switch to kiosk mode for the retry.
					self._kiosk = true
					self:_teardown()
				else
					-- Unexpected disconnect after connection was established.
					-- Reconnect as main; keep ready=true so focus_cell keeps working.
					self:_teardown_kiosk()
				end
				self._retry_count = self._retry_count + 1
				if self._retry_count > 10 then
					vim.notify("[marimo] gave up reconnecting after 10 attempts", vim.log.levels.WARN)
					return
				end
				self._read_buffer = ""
				vim.defer_fn(function()
					if not self.closed then
						self:connect(self._on_ready)
					end
				end, 500)
			end)
		end
	end)

	stderr_pipe:read_start(function(_, data)
		if data then
		end
	end)

	return nil -- success
end

--- Tear down the websocat subprocess and pipes without marking the session
--- as permanently closed.  Used internally by both close() and refresh().
function M:_teardown()
	-- Bump the generation so any pending EOF callbacks from the dying
	-- connection know they are stale and must not trigger a retry.
	self._connect_gen = self._connect_gen + 1
	self.ready = false
	if self._stdin_pipe and not self._stdin_pipe:is_closing() then
		self._stdin_pipe:close()
	end
	if self._stdout_pipe and not self._stdout_pipe:is_closing() then
		self._stdout_pipe:read_stop()
		self._stdout_pipe:close()
	end
	if self._stderr_pipe and not self._stderr_pipe:is_closing() then
		self._stderr_pipe:read_stop()
		self._stderr_pipe:close()
	end
	if self._ws_handle and not self._ws_handle:is_closing() then
		self._ws_handle:kill()
		self._ws_handle:close()
	end
	self._stdin_pipe = nil
	self._stdout_pipe = nil
	self._stderr_pipe = nil
	self._ws_handle = nil
end

--- Lightweight teardown for routine kiosk reconnects.
--- Cleans up the current websocat process/pipes but preserves ready + cell_ids
--- so focus_cell() keeps working between kiosk reconnect cycles.
function M:_teardown_kiosk()
	self._connect_gen = self._connect_gen + 1
	-- deliberately do NOT set self.ready = false here
	if self._stdin_pipe and not self._stdin_pipe:is_closing() then
		self._stdin_pipe:close()
	end
	if self._stdout_pipe and not self._stdout_pipe:is_closing() then
		self._stdout_pipe:read_stop()
		self._stdout_pipe:close()
	end
	if self._stderr_pipe and not self._stderr_pipe:is_closing() then
		self._stderr_pipe:read_stop()
		self._stderr_pipe:close()
	end
	if self._ws_handle and not self._ws_handle:is_closing() then
		self._ws_handle:kill()
		self._ws_handle:close()
	end
	self._stdin_pipe = nil
	self._stdout_pipe = nil
	self._stderr_pipe = nil
	self._ws_handle = nil
end

--- Close the WebSocket connection and kill websocat.
function M:close()
	if self.closed then
		return
	end
	self.closed = true
	self:_teardown()
end

-- Public: focus a cell

--- Tell the browser to scroll to the cell at the given 0-based index.
--- POSTs to /api/kernel/focus_cell (marimo >= 0.22).
---
--- @param cell_index integer  0-based cell index matching kernel-ready order
function M:focus_cell(cell_index)
	if not self.ready then
		return
	end
	if self._focus_cell_supported == false then
		return
	end

	-- cell_ids is 1-based in Lua; cell_index is 0-based from the parser.
	local cell_id = self.cell_ids[cell_index + 1]
	if not cell_id then
		return
	end

	local function post_focus(payload, payload_name, on_done)
		post_kernel_json(self, "/api/kernel/focus_cell", payload, function(out, status, body)
			on_done(out, status, body, payload_name)
		end)
	end

	local function notify_focus_failure(out, status, body, payload_name)
		vim.schedule(function()
			if status == 404 then
				self._focus_cell_supported = false
				vim.notify(
					"[marimo] focus_cell endpoint not found (HTTP 404). "
						.. "This server likely does not expose /api/kernel/focus_cell "
						.. "(older marimo build or a different marimo process/port).",
					vim.log.levels.WARN
				)
				return
			end

			local parts = { string.format("curl=%d", out.code) }
			if status then
				table.insert(parts, string.format("http=%d", status))
			end
			if payload_name then
				table.insert(parts, string.format("payload=%s", payload_name))
			end
			local stderr = vim.trim(out.stderr or "")
			if stderr ~= "" then
				table.insert(parts, stderr)
			end
			local response_body = vim.trim(body or "")
			if response_body ~= "" then
				table.insert(parts, response_body)
			end
			local details = table.concat(parts, " ")
			vim.notify("[marimo] focus_cell failed: " .. details, vim.log.levels.WARN)
		end)
	end

	post_focus({ cellId = cell_id }, "cellId", function(out, status, body, payload_name)
		if out.code == 0 and status and status < 400 then
			return
		end

		-- Backward-compat fallback for servers that still expect snake_case.
		if status == 400 or status == 422 then
			post_focus({ cell_id = cell_id }, "cell_id", function(out2, status2, body2, payload_name2)
				if out2.code == 0 and status2 and status2 < 400 then
					return
				end
				notify_focus_failure(out2, status2, body2, payload_name2)
			end)
			return
		end

		notify_focus_failure(out, status, body, payload_name)
	end)
end

--- Execute the cell at the given 0-based index with the provided code body.
--- POSTs to /api/kernel/run.
---
--- @param cell_index integer
--- @param code string
function M:run_cell(cell_index, code)
	if not self.ready then
		return
	end

	local cell_id = self.cell_ids[cell_index + 1]
	if not cell_id then
		return
	end

	post_kernel_json(self, "/api/kernel/run", {
		cellIds = { cell_id },
		codes = { code },
	}, function(out, status, body)
		if out.code == 0 and status and status < 400 then
			return
		end

		vim.schedule(function()
			local parts = { string.format("curl=%d", out.code) }
			if status then
				table.insert(parts, string.format("http=%d", status))
			end
			local stderr = vim.trim(out.stderr or "")
			if stderr ~= "" then
				table.insert(parts, stderr)
			end
			local response_body = vim.trim(body or "")
			if response_body ~= "" then
				table.insert(parts, response_body)
			end
			vim.notify("[marimo] run_cell failed: " .. table.concat(parts, " "), vim.log.levels.WARN)
		end)
	end)
end

--- Request a fresh kernel-ready by closing and reopening the WebSocket.
--- Call this after `:w` when cells may have been reordered in the file.
--- The session_id is preserved so marimo recognises the reconnect as the
--- same client rather than creating a new kernel session.
function M:refresh()
	if self.closed then
		return
	end
	local on_ready = self._on_ready
	self:_teardown()
	self._read_buffer = ""
	-- Do NOT rotate session_id — marimo binds the kernel to the original id.
	self:connect(on_ready)
end

return M
