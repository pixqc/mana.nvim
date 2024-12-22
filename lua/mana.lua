local Job = require("plenary.job")
local M = {}

---@alias Mana2.Model "gemini" | "sonnet" | "gemini_thinking"
---@alias Mana2.Endpoint "aistudio" | "openrouter"
---@alias Mana2.EndpointConfig_ {url: string, api_key: string}
---@alias Mana2.EndpointConfig table<Mana2.Endpoint, Mana2.EndpointConfig_>
---@alias Mana2.ModelConfig_ {endpoint: Mana2.Endpoint, name:string, system_prompt: string, temperature: number, top_p: number}
---@alias Mana2.ModelConfig table<Mana2.Model, Mana2.ModelConfig_>
---@alias Mana2.BufferState {winid: integer|nil, bufnr: integer}

-- // WINDOW+BUFFER STUFFS --

---move cursor down to "textbox"
---@param bufnr integer
---@return nil
local function buffer_cursor_down(bufnr)
	local line = vim.api.nvim_buf_line_count(bufnr)
	vim.api.nvim_win_set_cursor(0, { line, 0 })
	vim.api.nvim_command("startinsert")
end

---gets existing buffer, if not exist create new one
---@return integer @ bufnr
local function buffer_get()
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_get_name(buf):match("mana$") then
			vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
			return buf -- existing buffer
		end
	end

	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
	local name = string.format("%s/mana", vim.fn.getcwd())
	vim.api.nvim_buf_set_name(bufnr, name)
	vim.api.nvim_buf_set_name(bufnr, "mana")
	vim.api.nvim_set_option_value("syntax", "markdown", { buf = bufnr })
	vim.lsp.stop_client(vim.lsp.get_clients({ bufnr = bufnr }))
	return bufnr -- create new buffer, return bufnr
end

---@param bufnr integer
---@return nil
local function buffer_clear(bufnr)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local new_lines = {}
	for i = 1, math.min(3, #lines) do
		table.insert(new_lines, lines[i])
	end
	table.insert(new_lines, "")
	table.insert(new_lines, "") -- append \n\n
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
	buffer_cursor_down(bufnr)
end

---@param bufnr integer
---@param chunk string
---@return nil
local function buffer_append(bufnr, chunk)
	local last_line = vim.api.nvim_buf_get_lines(bufnr, -2, -1, false)[1] or ""
	local lines = vim.split(last_line .. chunk, "\n", { plain = true })
	vim.api.nvim_buf_set_lines(bufnr, -2, -1, false, lines)
end

---@param bufnr integer
---@return nil -- should return message with img-enabled
local function buffer_parse(bufnr) end

---@param bufnr integer
---@return integer winid
local function window_create(bufnr)
	vim.cmd("botright vsplit")
	local winid = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(winid, bufnr)
	vim.api.nvim_win_set_width(winid, math.floor(vim.o.columns * 0.35))
	vim.api.nvim_set_option_value("number", true, { win = winid })
	vim.api.nvim_set_option_value("relativenumber", true, { win = winid })
	vim.api.nvim_set_option_value("winfixwidth", true, { win = winid })
	vim.api.nvim_set_option_value("wrap", true, { win = winid })
	vim.api.nvim_set_option_value("linebreak", true, { win = winid })

	vim.api.nvim_create_autocmd("WinResized", {
		callback = function()
			if vim.api.nvim_win_is_valid(winid) then
				local width = math.floor(vim.o.columns * 0.35)
				vim.api.nvim_win_set_width(winid, width)
			end
		end,
	})

	return winid
end

-- // CHAT STUFFS --

---@param data string
---@return string
local function stream_parse(data)
	for line in data:gmatch("[^\r\n]+") do
		if line:match("^data: ") then
			local json_str = line:sub(7)
			local ok, decoded = pcall(vim.json.decode, json_str)
			if ok and decoded and decoded.choices then
				for _, choice in ipairs(decoded.choices) do
					if choice.delta and choice.delta.content then
						return choice.delta.content
					end
				end
			end
		end
	end
	return ""
end

local function fetch(model_cfg, endpoint_cfg, bufnr)
	return function(messages)
		local request_body = {
			model = model_cfg.name,
			messages = messages,
			stream = true,
		}

		---@diagnostic disable: missing-fields
		Job:new({
			command = "curl",
			args = {
				"-s",
				endpoint_cfg.url,
				"-H",
				"Content-Type: application/json",
				"-H",
				"Authorization: Bearer " .. endpoint_cfg.api_key,
				"--no-buffer",
				"-d",
				vim.json.encode(request_body),
			},
			on_stdout = function(_, data)
				local chunk = stream_parse(data)
				vim.schedule(function()
					buffer_append(bufnr, chunk)
				end)

				if data:match("data: %[DONE%]") then
					vim.schedule(function()
						buffer_append(bufnr, "\n<user>\n")
					end)
				end
			end,
			on_stderr = function(_, data)
				vim.schedule(function()
					buffer_append(bufnr, data)
				end)
			end,
		}):start()
	end
end

---@param bufnr integer
---@param fetcher function
---@return nil
local function keymap_set_chat(bufnr, fetcher)
	vim.api.nvim_buf_set_keymap(bufnr, "n", "<CR>", "", {
		callback = function()
			local messages = buffer_parse(bufnr)
			if #messages == 1 and messages[1].content == "" then
				print("emtpy input")
				return -- no user input, do nothing
			end
			if messages then
				buffer_append(bufnr, "\n\n<assistant>\n\n")
				fetcher(messages)
			end
		end,
		noremap = true,
		silent = true,
	})
end

---@param bufnr integer
---@param model_cfgs Mana2.ModelConfig
---@param fetchers function[]
---@return nil
local function command_set_chat(bufnr, model_cfgs, fetchers)
	vim.api.nvim_create_user_command("Mana", function(opts)
		local args = vim.split(opts.args, "%s+")
		local cmd = args[1]
		if cmd == "switch" then
			local model = args[2]
			if not model then
				vim.notify("Please specify a model name", vim.log.levels.ERROR)
				return
			end
			local cfg = model_cfgs[model]
			if not cfg then
				vim.notify("Invalid model name: " .. model, vim.log.levels.ERROR)
				return
			end
			keymap_set_chat(fetchers[model], bufnr)
			vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, {
				string.format("model: %s", cfg.name),
			})
		end
	end, {
		nargs = 1,
		range = true,
		complete = function()
			return { "switch" }
		end,
	})
end

-- // UI STUFFS --

---@param bufnr integer
---@return nil
local function keymap_set_ui(bufnr)
	-- clear chat
	vim.api.nvim_buf_set_keymap(bufnr, "n", "<C-n>", "", {
		callback = function()
			buffer_clear(bufnr)
		end,
		noremap = true,
		silent = true,
	})

	-- clear chat (insert mode)
	vim.api.nvim_buf_set_keymap(bufnr, "i", "<C-n>", "", {
		callback = function()
			buffer_clear(bufnr)
		end,
		noremap = true,
		silent = true,
	})
end

---@param bufnr integer
---@param winid integer|nil
---@return nil
local function command_set_ui(bufnr, winid)
	vim.api.nvim_create_user_command("Mana", function(opts)
		local args = vim.split(opts.args, "%s+")
		local cmd = args[1]

		if cmd == "open" then
			if not (winid and vim.api.nvim_win_is_valid(winid)) then
				winid = window_create(bufnr)
				buffer_cursor_down(bufnr)
			end
		elseif cmd == "close" then
			if winid and vim.api.nvim_win_is_valid(winid) then
				vim.api.nvim_win_close(winid, true)
				winid = nil
			end
		elseif cmd == "toggle" then
			if winid and vim.api.nvim_win_is_valid(winid) then
				vim.api.nvim_win_close(winid, true)
				winid = nil
			else
				winid = window_create(bufnr)
				buffer_cursor_down(bufnr)
			end
		elseif cmd == "paste" then
			local start_pos = vim.fn.getpos("'<")
			local end_pos = vim.fn.getpos("'>")
			local start_line = start_pos[2]
			local end_line = end_pos[2]

			local current_buf = vim.api.nvim_get_current_buf()
			local lines = vim.api.nvim_buf_get_lines(current_buf, start_line - 1, end_line, false)
			local text = table.concat(lines, "\n")
			buffer_append(bufnr, "\n" .. text .. "\n\n")
		end
	end, {
		nargs = 1,
		range = true,
		complete = function()
			return { "open", "close", "toggle", "paste" }
		end,
	})
end

-- // INPUT PARSERS --

---@param raw any
---@return Mana2.ModelConfig|nil, string?
local function parse_opts_models(raw)
	if type(raw) ~= "table" then
		return nil, "models must be a table"
	end

	local parsed = {}
	for model_name, config in pairs(raw) do
		if type(config.endpoint) ~= "string" then
			return nil, string.format("model %s: endpoint must be a string", model_name)
		end
		if type(config.name) ~= "string" then
			return nil, string.format("model %s: name must be a string", model_name)
		end
		if type(config.system_prompt) ~= "string" then
			return nil, string.format("model %s: system_prompt must be a string", model_name)
		end
		if type(config.temperature) ~= "number" then
			return nil, string.format("model %s: temperature must be a number", model_name)
		end
		if type(config.top_p) ~= "number" then
			return nil, string.format("model %s: top_p must be a number", model_name)
		end

		parsed[model_name] = {
			endpoint = config.endpoint,
			name = config.name,
			system_prompt = config.system_prompt,
			temperature = config.temperature,
			top_p = config.top_p,
		}
	end

	return parsed
end

---@param raw any
---@return Mana2.EndpointConfig|nil, string?
local function parse_opts_endpoints(raw)
	if type(raw) ~= "table" then
		return nil, "endpoints must be a table"
	end

	local parsed = {}
	for endpoint, config in pairs(raw) do
		if type(config.url) ~= "string" then
			return nil, string.format("endpoint %s: url must be a string", endpoint)
		end
		if type(config.env) ~= "string" then
			return nil, string.format("endpoint %s: env must be a string", endpoint)
		end

		local api_key = os.getenv(config.env)
		if not api_key then
			local tmp = "endpoint %s: API key not found in environment variable %s"
			return nil, string.format(tmp, endpoint, config.env)
		end

		parsed[endpoint] = {
			url = config.url,
			api_key = api_key,
		}
	end

	return parsed
end

---@param raw any
---@param model_cfgs Mana2.ModelConfig
---@return Mana2.ModelConfig|nil, string?
local function parse_opts_default_model(raw, model_cfgs)
	if type(raw) ~= "string" then
		return nil, "default_model must be a string"
	end

	if not model_cfgs[raw] then
		local tmp = "default model '%s' not found in keys of models table"
		return nil, string.format(tmp, raw)
	end

	return { [raw] = model_cfgs[raw] }
end

M.setup = function(opts)
	local model_cfgs, m_err = parse_opts_models(opts.models)
	if not model_cfgs then
		vim.notify("Mana.nvim error: " .. m_err, vim.log.levels.ERROR)
		return
	end

	local endpoint_cfgs, e_err = parse_opts_endpoints(opts.endpoints)
	if not endpoint_cfgs then
		vim.notify("Mana.nvim error: " .. e_err, vim.log.levels.ERROR)
		return
	end

	local default_model_cfg, dm_err = parse_opts_default_model(opts.default_model, model_cfgs)
	if not default_model_cfg then
		vim.notify("Mana.nvim error: " .. dm_err, vim.log.levels.ERROR)
		return
	end

	vim.notify(vim.inspect(model_cfgs))
	vim.notify(vim.inspect(endpoint_cfgs))
	vim.notify(vim.inspect(default_model_cfg))

	-- ---@type table<Mana2.Model, function>
	-- local fetchers = {}
	-- for model, model_cfg in pairs(model_cfgs) do
	-- 	local endpoint_cfg = endpoint_cfgs[model_cfg.endpoint]
	-- 	fetchers[model] = fetch(model_cfg, endpoint_cfg, 1)
	-- end
	--
	-- local buffer_state = {
	-- 	bufnr = buffer_get(),
	-- 	winid = nil,
	-- }
	--
	-- local prepend = string.format("model: %s\n\n<user>\n\n", default_model_cfg.name)
	-- vim.api.nvim_buf_set_lines(buffer_state.bufnr, 0, -1, false, vim.split(prepend, "\n"))
	--
	-- keymap_set_ui(buffer_state.bufnr)
	-- command_set_ui(buffer_state.bufnr, buffer_state.winid)
	-- keymap_set_chat(buffer_state.bufnr, fetchers[default_model_cfg.name])
	-- command_set_chat(buffer_state.bufnr, model_cfgs, fetchers)
end

return M
