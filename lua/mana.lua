local Job = require("plenary.job")
local M = {}

---@class Mana.EndpointConfig
---@field url string
---@field api_key string

---@class Mana.EndpointConfigs
---@field [string] Mana.EndpointConfig

---@class Mana.ModelConfig
---@field endpoint string
---@field name string
---@field system_prompt string
---@field temperature number
---@field top_p number
---@field fetcher Mana.Fetcher

---@alias Mana.Prefetcher fun(
--- model_name: string,
--- endpoint_cfg: Mana.EndpointConfig): Mana.Fetcher
---@alias Mana.Fetcher fun(messages: Mana.Messages)

---@class Mana.ModelConfigs
---@field [string] Mana.ModelConfig

---@class Mana.ContentItem
---@field type "text"
---@field text string

---@class Mana.Message
---@field role "user" | "assistant" | "system"
---@field content Mana.ContentItem[]

---@alias Mana.Messages Mana.Message[]

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
---@return integer -- bufnr
local function buffer_get()
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_get_name(buf):match("mana$") then
			vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
			return buf -- existing bufnr
		end
	end

	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(bufnr, "mana")
	vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
	vim.api.nvim_set_option_value("tabstop", 2, { buf = bufnr })
	vim.api.nvim_set_option_value("shiftwidth", 2, { buf = bufnr })
	vim.api.nvim_set_option_value("expandtab", true, { buf = bufnr })
	vim.lsp.stop_client(vim.lsp.get_clients({ bufnr = bufnr }))
	return bufnr -- create new buffer, return bufnr
end

---@param chunk string
---@param bufnr integer
---@return nil
local function buffer_append(chunk, bufnr)
	local last_line = vim.api.nvim_buf_get_lines(bufnr, -2, -1, false)[1] or ""
	local lines = vim.split(last_line .. chunk, "\n", { plain = true })
	vim.api.nvim_buf_set_lines(bufnr, -2, -1, false, lines)
end

---@param bufnr integer
---@return Mana.Messages
local function buffer_parse(bufnr)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local messages = {}
	local current_role = "user"
	local current_text = {}

	local function add_message()
		if #current_text > 0 then
			local combined_text = table.concat(current_text, "\n")
			table.insert(messages, {
				role = current_role,
				content = {
					{ type = "text", text = combined_text },
				},
			})
		end
	end

	for _, line in ipairs(lines) do
		if line == "<assistant>" then
			add_message()
			current_role = "assistant"
			current_text = {}
		elseif line == "</assistant>" then
			add_message()
			current_role = "user"
			current_text = {}
		elseif vim.trim(line) ~= "" then
			table.insert(current_text, vim.trim(line))
		end
	end
	add_message() -- add the last message
	return messages
end

---@param bufnr integer
---@return integer winid
local function window_create(bufnr)
	vim.cmd("botright vsplit")
	local winid = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(winid, bufnr)
	vim.api.nvim_win_set_width(winid, 65) -- should be editable by opts
	vim.api.nvim_set_option_value("number", true, { win = winid })
	vim.api.nvim_set_option_value("relativenumber", true, { win = winid })
	vim.api.nvim_set_option_value("winfixwidth", true, { win = winid })
	vim.api.nvim_set_option_value("wrap", true, { win = winid })
	vim.api.nvim_set_option_value("linebreak", true, { win = winid })
	vim.api.nvim_set_option_value("colorcolumn", "", { win = winid })

	-- keep window size static
	vim.api.nvim_create_autocmd("WinResized", {
		callback = function()
			if vim.api.nvim_win_is_valid(winid) then
				vim.api.nvim_win_set_width(winid, 65)
			end
		end,
	})

	return winid
end

-- // CHAT STUFFS --

---@param model_cfg Mana.ModelConfig
---@param bufnr integer
---@return nil
local function keymap_set_chat(model_cfg, bufnr)
	vim.api.nvim_buf_set_keymap(bufnr, "n", "<CR>", "", {
		callback = function()
			local messages = buffer_parse(bufnr)
			if #messages == 1 and messages[1].content == "" then
				print("emtpy input")
				return -- no user input, do nothing
			end
			if messages then
				if model_cfg.system_prompt and model_cfg.system_prompt ~= "" then
					table.insert(messages, 1, {
						role = "system",
						content = { { type = "text", text = model_cfg.system_prompt } },
					})
				end
				buffer_append("\n\n<assistant>\n\n", bufnr)
				model_cfg.fetcher(messages)
			end
		end,
		noremap = true,
		silent = true,
	})
end

---@param model_cfgs Mana.ModelConfigs
---@return fun(winid:integer, bufnr:integer)
local function model_switch(model_cfgs)
	return function(winid, bufnr)
		local display_to_cfg = {}
		local displays = {}

		for _, cfg in pairs(model_cfgs) do
			local display = string.format("%s@%s", cfg.endpoint, cfg.name)
			display_to_cfg[display] = cfg
			table.insert(displays, display)
		end

		vim.ui.select(displays, {
			prompt = "Mana switch model",
		}, function(selected)
			if not selected then
				return
			end -- user cancelled

			local cfg = display_to_cfg[selected]
			local winbar = string.format("%%=%s@%s", cfg.endpoint, cfg.name)
			keymap_set_chat(cfg, bufnr)
			vim.api.nvim_set_option_value("winbar", winbar, { win = winid })
		end)
	end
end

---mk_prefetcher(callback)(configs)(messages)
---prefetcher = mk_prefetcher(callback)
---fetcher = prefetcher(configs)
---call fetcher(messages) to chat with llm
---@param stdout_callback function
---@return Mana.Prefetcher
local function mk_prefetcher(stdout_callback)
	return function(model_name, endpoint_cfg)
		return function(messages)
			local request_body = {
				model = model_name,
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
				on_stdout = stdout_callback,
			}):start()
		end
	end
end

---@param bufnr integer
---@return fun(_, data) -- callback, to be passed to curl
local function mk_stdout_callback(bufnr)
	return function(_, data)
		for line in data:gmatch("[^\r\n]+") do
			if line:match("^data: ") then
				if line:match("data: %[DONE%]") then -- llm done talking
					vim.schedule(function()
						buffer_append("\n</assistant>\n", bufnr)
					end)
				else
					local json_str = line:sub(7)
					local ok, decoded = pcall(vim.json.decode, json_str)
					if ok and decoded and decoded.choices then
						for _, choice in ipairs(decoded.choices) do
							if choice.delta and choice.delta.content then
								vim.schedule(function()
									buffer_append(choice.delta.content, bufnr) -- llm talking
								end)
							end
						end
					end
				end
			else
				if data ~= ": OPENROUTER PROCESSING" then
					vim.schedule(function()
						buffer_append(data, bufnr) -- may contain error msgs
					end)
				end
			end
		end
	end
end

-- // UI STUFFS --

---model_switch_ is return of model_switch(model_cfg)
---@param model_switch_ fun(winid:integer, bufnr:integer)
---@param winbar string
---@param winid integer|nil
---@param bufnr integer
local function command_set(model_switch_, winbar, winid, bufnr)
	vim.api.nvim_create_user_command("Mana", function(opts)
		local args = vim.split(opts.args, "%s+")
		local cmd = args[1]

		if cmd == "open" then
			if not (winid and vim.api.nvim_win_is_valid(winid)) then
				winid = window_create(bufnr)
				buffer_cursor_down(bufnr)
				vim.api.nvim_set_option_value("winbar", winbar, { win = winid })
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
				vim.api.nvim_set_option_value("winbar", winbar, { win = winid })
			end
		elseif cmd == "clear" then
			vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
			if winid and vim.api.nvim_win_is_valid(winid) and vim.api.nvim_get_current_win() == winid then
				buffer_cursor_down(bufnr)
			end
		elseif cmd == "paste" then
			local start = vim.fn.getpos("'<")[2]
			local end_ = vim.fn.getpos("'>")[2]
			local buf = vim.api.nvim_get_current_buf()
			local lines = vim.api.nvim_buf_get_lines(buf, start - 1, end_, false)
			local text = table.concat(lines, "\n")
			buffer_append("\n" .. text .. "\n\n", bufnr)

			if not winid or not vim.api.nvim_win_is_valid(winid) then
				winid = window_create(bufnr)
				buffer_cursor_down(bufnr)
				vim.api.nvim_set_option_value("winbar", winbar, { win = winid })
			end
		elseif cmd == "switch" then
			if winid and vim.api.nvim_win_is_valid(winid) then
				model_switch_(winid, bufnr)
			else
				winid = window_create(bufnr)
				model_switch_(winid, bufnr)
			end
		end
	end, {
		nargs = 1,
		range = true,
		complete = function()
			return { "open", "close", "toggle", "clear", "paste", "switch" }
		end,
	})
end

-- // OPTS PARSERS --

---@param endpoint_cfgs Mana.EndpointConfigs
---@param prefetcher Mana.Prefetcher
---@param raw any
---@return Mana.ModelConfigs|nil, string?
local function parse_opts_models(endpoint_cfgs, prefetcher, raw)
	if type(raw) ~= "table" then
		return nil, "models must be a table"
	end
	local parsed = {}
	for model_name, model_cfg in pairs(raw) do
		if type(model_cfg.endpoint) ~= "string" then
			return nil, string.format("model %s: endpoint must be a string", model_name)
		end
		if type(model_cfg.name) ~= "string" then
			return nil, string.format("model %s: name must be a string", model_name)
		end
		if type(model_cfg.system_prompt) ~= "string" then
			return nil, string.format("model %s: system_prompt must be a string", model_name)
		end
		if type(model_cfg.temperature) ~= "number" then
			return nil, string.format("model %s: temperature must be a number", model_name)
		end
		if type(model_cfg.top_p) ~= "number" then
			return nil, string.format("model %s: top_p must be a number", model_name)
		end
		local endpoint_cfg = endpoint_cfgs[model_cfg.endpoint]
		parsed[model_name] = {
			endpoint = model_cfg.endpoint,
			name = model_cfg.name,
			system_prompt = model_cfg.system_prompt,
			temperature = model_cfg.temperature,
			top_p = model_cfg.top_p,
			fetcher = prefetcher(model_cfg.name, endpoint_cfg),
		}
	end
	return parsed
end

---@param raw any
---@return Mana.EndpointConfigs|nil, string?
local function parse_opts_envs(raw)
	if type(raw) ~= "table" then
		return nil, "envs must be a table"
	end

	local urls = {
		aistudio = "https://generativelanguage.googleapis.com/v1beta/chat/completions",
		openrouter = "https://openrouter.ai/api/v1/chat/completions",
	}

	local parsed = {}
	for endpoint, env in pairs(raw) do
		if not urls[endpoint] then
			return nil, string.format("endpoint %s: invalid endpoint", endpoint)
		end

		if type(env) ~= "string" then
			return nil, string.format("endpoint %s: env must be a string", endpoint)
		end

		local api_key = os.getenv(env)
		if not api_key then
			local tmp = "endpoint %s: API key not found in environment variable %s"
			return nil, string.format(tmp, endpoint, env)
		end

		parsed[endpoint] = {
			url = urls[endpoint],
			api_key = api_key,
		}
	end

	return parsed
end

---@param model_cfgs Mana.ModelConfigs
---@param raw any
---@return Mana.ModelConfig|nil, string?
local function parse_opts_default_model(model_cfgs, raw)
	if type(raw) ~= "string" then
		return nil, "default_model must be a string"
	end

	if not model_cfgs[raw] then
		local tmp = "default model '%s' not found in keys of models table"
		return nil, string.format(tmp, raw)
	end

	return model_cfgs[raw]
end

-- // SETUP --

M.setup = function(opts)
	local bufnr = buffer_get()
	local winid = nil

	local stdout_callback = mk_stdout_callback(bufnr)
	local prefetcher = mk_prefetcher(stdout_callback)

	---@type Mana.EndpointConfigs|nil, string?
	local endpoint_cfgs, e_err = parse_opts_envs(opts.envs)
	if not endpoint_cfgs then
		vim.notify("Mana.nvim error: " .. e_err, vim.log.levels.ERROR)
		return
	end

	---@type Mana.ModelConfigs|nil, string?
	local model_cfgs, m_err = parse_opts_models(endpoint_cfgs, prefetcher, opts.models)
	if not model_cfgs then
		vim.notify("Mana.nvim error: " .. m_err, vim.log.levels.ERROR)
		return
	end

	---@type Mana.ModelConfig|nil, string?
	local default, dm_err = parse_opts_default_model(model_cfgs, opts.default_model)
	if not default then
		vim.notify("Mana.nvim error: " .. dm_err, vim.log.levels.ERROR)
		return
	end

	local model_switch_ = model_switch(model_cfgs)
	local winbar = "%=" .. default.endpoint .. "@" .. default.name
	keymap_set_chat(default, bufnr)
	command_set(model_switch_, winbar, winid, bufnr)
end

return M
