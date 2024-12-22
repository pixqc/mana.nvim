local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local conf = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local Job = require("plenary.job")
local M = {}

---@alias Mana2.Model "gemini" | "sonnet" | "gemini_thinking"
---@alias Mana2.Endpoint "aistudio" | "openrouter"
---@alias Mana2.EndpointConfig_ {url: string, api_key: string}
---@alias Mana2.EndpointConfig table<Mana2.Endpoint, Mana2.EndpointConfig_>
---@alias Mana2.ModelConfig_ {endpoint: Mana2.Endpoint, name:string, system_prompt: string, temperature: number, top_p: number}
---@alias Mana2.ModelConfig table<Mana2.Model, Mana2.ModelConfig_>
---@alias Mana2.BufferState {winid: integer|nil, bufnr: integer}

---@alias Mana2.Role "user" | "assistant" | "system"
---@alias Mana2.Messages { role: Mana2.Role, content:  { type: "text", text: string }[] }[]
---@alias Mana2.Prefetcher fun(model: string, endpoint_cfg: Mana2.EndpointConfig_): fun(messages: Mana2.Messages)
---@alias Mana2.Fetcher fun(messages: Mana2.Messages)

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
			return buf -- existing bufnr
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
---@return Mana2.Messages
local function buffer_parse(bufnr)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local messages = {}
	local current_role = nil
	local current_text = {}

	local function add_message()
		if current_role and #current_text > 0 then
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
		if line == "<user>" then
			add_message()
			current_role = "user"
			current_text = {}
		elseif line == "<assistant>" then
			add_message()
			current_role = "assistant"
			current_text = {}
		elseif current_role and vim.trim(line) ~= "" then
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
	vim.api.nvim_win_set_width(winid, math.floor(vim.o.columns * 0.35))
	vim.api.nvim_set_option_value("number", true, { win = winid })
	vim.api.nvim_set_option_value("relativenumber", true, { win = winid })
	vim.api.nvim_set_option_value("winfixwidth", true, { win = winid })
	vim.api.nvim_set_option_value("wrap", true, { win = winid })
	vim.api.nvim_set_option_value("linebreak", true, { win = winid })

	-- keep window size static
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

---@param bufnr integer
---@param fetcher fun(messages: Mana2.Messages)
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

---@param model_cfgs Mana2.ModelConfig
---@param endpoint_cfgs Mana2.EndpointConfig
---@param bufnr integer
---@param prefetcher Mana2.Prefetcher
local function telescope_model_switch(model_cfgs, endpoint_cfgs, bufnr, prefetcher)
	local models = {}
	for name, cfg in pairs(model_cfgs) do
		table.insert(models, {
			name = name,
			display = string.format("%s@%s", cfg.endpoint, cfg.name),
		})
	end

	pickers
		.new({}, {
			prompt_title = "Mana switch model",
			finder = finders.new_table({
				results = models,
				entry_maker = function(entry)
					return {
						value = entry,
						display = entry.display,
						ordinal = entry.display,
					}
				end,
			}),
			sorter = conf.generic_sorter({}),
			attach_mappings = function(prompt_bufnr, _)
				actions.select_default:replace(function()
					actions.close(prompt_bufnr)
					local selection = action_state.get_selected_entry()
					---@type Mana2.Model
					local model = selection.value.name
					local model_cfg = model_cfgs[model]
					local endpoint_cfg = endpoint_cfgs[model_cfg.endpoint]
					local fetcher = prefetcher(model_cfg.name, endpoint_cfg)
					keymap_set_chat(bufnr, fetcher)
					vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, {
						string.format("model: %s@%s", model_cfg.endpoint, model_cfg.name),
					})
				end)
				return true
			end,
		})
		:find()
end

---mk_prefetcher(callbacks)(configs)(messages)
---callbacks are same no matter the model
---pass mk_prefetcher(callbacks) to "model switcher" (it's a "prefetcher")
---pass messages to mk_prefetcher(callbacks)(configs) to chat with model
---@param stdout_callback function
---@param stderr_callback function
---@return Mana2.Prefetcher
local function mk_prefetcher(stdout_callback, stderr_callback)
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
				on_stderr = stderr_callback,
			}):start()
		end
	end
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
---@param model_cfgs Mana2.ModelConfig
---@param endpoint_cfgs Mana2.EndpointConfig
---@param prefetcher Mana2.Prefetcher
local function command_set(bufnr, winid, model_cfgs, endpoint_cfgs, prefetcher)
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
		elseif cmd == "clear" then
			buffer_clear(bufnr)
		elseif cmd == "switch" then
			telescope_model_switch(model_cfgs, endpoint_cfgs, bufnr, prefetcher)
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
			return { "open", "close", "toggle", "switch", "paste" }
		end,
	})
end

-- // OPTS PARSERS --

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
---@return Mana2.ModelConfig_|nil, string?
local function parse_opts_default_model(raw, model_cfgs)
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
	---@type Mana2.ModelConfig|nil, string?
	local model_cfgs, m_err = parse_opts_models(opts.models)
	if not model_cfgs then
		vim.notify("Mana.nvim error: " .. m_err, vim.log.levels.ERROR)
		return
	end

	---@type Mana2.EndpointConfig|nil, string?
	local endpoint_cfgs, e_err = parse_opts_endpoints(opts.endpoints)
	if not endpoint_cfgs then
		vim.notify("Mana.nvim error: " .. e_err, vim.log.levels.ERROR)
		return
	end

	---@type Mana2.ModelConfig_|nil, string?
	local default, dm_err = parse_opts_default_model(opts.default_model, model_cfgs)
	if not default then
		vim.notify("Mana.nvim error: " .. dm_err, vim.log.levels.ERROR)
		return
	end

	local buffer_state = {
		bufnr = buffer_get(),
		winid = nil,
	}

	local function stdout_callback(_, data)
		local chunk = stream_parse(data)
		vim.schedule(function()
			buffer_append(buffer_state.bufnr, chunk)
		end)

		if data:match("data: %[DONE%]") then
			vim.schedule(function()
				buffer_append(buffer_state.bufnr, "\n<user>\n")
			end)
		end
	end

	local function stderr_callback(_, data)
		vim.schedule(function()
			buffer_append(buffer_state.bufnr, data)
		end)
	end

	local prefetcher = mk_prefetcher(stdout_callback, stderr_callback)
	local fetcher = prefetcher(default.name, endpoint_cfgs[default.endpoint])

	local prepend_ = string.format("model: %s@%s", default.endpoint, default.name)
	local prepend = string.format("%s\n\n<user>\n\n", prepend_)
	vim.api.nvim_buf_set_lines(buffer_state.bufnr, 0, -1, false, vim.split(prepend, "\n"))

	keymap_set_ui(buffer_state.bufnr)
	keymap_set_chat(buffer_state.bufnr, fetcher)
	command_set(buffer_state.bufnr, buffer_state.winid, model_cfgs, endpoint_cfgs, prefetcher)
end

return M
