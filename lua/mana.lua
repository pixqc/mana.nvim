local Job = require("plenary.job")
local M = {}

---@alias Mana2.Model "gemini" | "sonnet" | "gemini_thinking"
---@alias Mana2.Endpoint "aistudio" | "openrouter"
---@alias Mana2.EndpointConfig_ {url: string, api_key: string}
---@alias Mana2.EndpointConfig table<Mana2.Endpoint, Mana2.EndpointConfig_>
---@alias Mana2.ModelConfig_ {endpoint: Mana2.Endpoint, name:string, system_prompt: string, temperature: number, top_p: number}
---@alias Mana2.ModelConfig table<Mana2.Model, Mana2.ModelConfig_>
---@alias Mana2.BufferState {winid: integer|nil, bufnr: integer}

-- // WINDOW+BUFFER stuffs --

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

---@param cfgs table<Mana2.Endpoint, {url: string, env: string}>
---@return Mana2.EndpointConfig
local function mk_endpoint_cfgs(cfgs)
	local cfgs_ = {}
	for endpoint, config in pairs(cfgs) do
		local api_key = os.getenv(config.env)
		if api_key then
			cfgs_[endpoint] = {
				url = config.url,
				api_key = api_key,
			}
		end
	end
	return cfgs_
end

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

-- ---@param bufnr integer
-- ---@param model_cfgs Mana2.ModelConfig
-- ---@param fetchers function[]
-- ---@return nil
-- local function command_set_chat(bufnr, model_cfgs, fetchers)
-- 	vim.api.nvim_create_user_command("Mana", function(opts)
-- 		local args = vim.split(opts.args, "%s+")
-- 		local cmd = args[1]
-- 		if cmd == "switch" then
-- 			local model = args[2]
-- 			if not model then
-- 				vim.notify("Please specify a model name", vim.log.levels.ERROR)
-- 				return
-- 			end
-- 			local cfg = model_cfgs[model]
-- 			if not cfg then
-- 				vim.notify("Invalid model name: " .. model, vim.log.levels.ERROR)
-- 				return
-- 			end
-- 			keymap_set_chat(fetchers[model], bufnr)
-- 			vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, {
-- 				string.format("model: %s", cfg.name),
-- 			})
-- 		end
-- 	end, {
-- 		nargs = 1,
-- 		range = true,
-- 		complete = function()
-- 			return { "switch" }
-- 		end,
-- 	})
-- end

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
---@return table<Mana2.Endpoint, {url: string, env: string}>|nil, string?
local function parse_opts_endpoints(raw)
	if type(raw) ~= "table" then
		return nil, "endpoints must be a table"
	end

	local parsed = {}
	for endpoint_name, config in pairs(raw) do
		if type(config.url) ~= "string" then
			return nil, string.format("endpoint %s: url must be a string", endpoint_name)
		end
		if type(config.env) ~= "string" then
			return nil, string.format("endpoint %s: env must be a string", endpoint_name)
		end

		parsed[endpoint_name] = {
			url = config.url,
			env = config.env,
		}
	end

	return parsed
end

M.setup = function(opts)
	local parsed_opts_models, models_err = parse_opts_models(opts.models)
	if not parsed_opts_models then
		vim.notify("Mana Error: " .. models_err, vim.log.levels.ERROR)
		return
	end

	local parsed_opts_endpoints, endpoints_err = parse_opts_endpoints(opts.endpoints)
	if not parsed_opts_endpoints then
		vim.notify("Mana Error: " .. endpoints_err, vim.log.levels.ERROR)
		return
	end

	---@type Mana2.EndpointConfig
	local endpoint_cfgs = mk_endpoint_cfgs(parsed_opts_endpoints)
	if vim.tbl_count(endpoint_cfgs) == 0 then
		vim.notify("Mana Error: no API key found.", vim.log.levels.ERROR)
		return
	end

	---@type Mana2.ModelConfig
	local model_cfgs = {} -- models without api keys wont be included
	for model_name, model_config in pairs(parsed_opts_models) do
		if endpoint_cfgs[model_config.endpoint] then
			model_cfgs[model_name] = model_config
		end
	end

	---@type Mana2.ModelConfig_
	local default_model_cfg
	if model_cfgs[opts.default_model] then
		default_model_cfg = model_cfgs[opts.default_model]
	else
		for _, model_cfg in pairs(model_cfgs) do
			default_model_cfg = model_cfg
			break
		end
	end

	vim.notify(vim.inspect(endpoint_cfgs))
	vim.notify(vim.inspect(model_cfgs))
	vim.notify(vim.inspect(default_model_cfg))

	-- local fetchers = {}
	-- for model, model_cfg in pairs(model_cfgs) do
	-- 	local endpoint_cfg = endpoint_cfgs[model_cfg.endpoint]
	-- 	fetchers[model] = fetch(model_cfg, endpoint_cfg, 1)
	-- end
	--
	local buffer_state = {
		bufnr = buffer_get(),
		winid = nil,
	}

	local prepend = string.format("model: %s\n\n<user>\n\n", default_model_cfg.name)
	vim.api.nvim_buf_set_lines(buffer_state.bufnr, 0, -1, false, vim.split(prepend, "\n"))

	keymap_set_ui(buffer_state.bufnr)
	command_set_ui(buffer_state.bufnr, buffer_state.winid)

	-- keymap_set_chat(buffer_state.bufnr, fetchers[default_model])
	-- command_set_chat(buffer_state.bufnr, model_cfgs, fetchers)
end

return M
