local Job = require("plenary.job")
local M = {}

---@class Mana.ModelConfig
---@field url string
---@field name string
---@field system_prompt string
---@field temperature number
---@field top_p number
---@field api_key string @ nil api_key is invalid ModelConfig

---@class Mana.BufferState
---@field winid integer|nil @ nvim window ID
---@field bufnr integer|nil @ nvim buffer number

---@alias Mana.Role "user" | "assistant" | "system"
---@class Mana.Messages
---@field messages { role: Mana.Role, content: string }[] @ must NonEmpty

-- // WINDOW+BUFFER stuffs --

---@param bufnr integer
---@return nil
local function buffer_cursor_down(bufnr)
	local line = vim.api.nvim_buf_line_count(bufnr)
	vim.api.nvim_win_set_cursor(0, { line, 0 })
	vim.api.nvim_command("startinsert")
end

---@param prepend string
---@return integer @ bufnr
local function buffer_get(prepend)
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
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(prepend, "\n"))
	return bufnr -- create new buffer, return bufnr
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
	vim.api.nvim_buf_set_name(bufnr, "mana")

	vim.api.nvim_set_option_value("syntax", "markdown", { buf = bufnr })
	vim.lsp.stop_client(vim.lsp.get_clients({ bufnr = bufnr }))
	buffer_cursor_down(bufnr)

	return winid
end
--
-- ---@param bufnr integer
-- ---@return Mana.Messages
-- local function buffer_parse(bufnr)
-- 	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
-- 	local messages = {}
-- 	local current_role = nil
-- 	local current_content = {}
--
-- 	local function append_message()
-- 		if current_role then
-- 			local message = { role = current_role, content = vim.trim(table.concat(current_content, "\n")) }
-- 			table.insert(messages, message)
-- 			current_content = {}
-- 		end
-- 	end
--
-- 	for _, line in ipairs(lines) do
-- 		if line:match("^<user>%s*$") then
-- 			append_message()
-- 			current_role = "user"
-- 		elseif line:match("^<assistant>%s*$") then
-- 			append_message()
-- 			current_role = "assistant"
-- 		elseif current_role then
-- 			table.insert(current_content, line)
-- 		end
-- 	end
-- 	append_message()
-- 	return messages
-- end

---@param bufnr integer
---@return Mana.Messages
local function buffer_parse(bufnr)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

	local function get_role(line)
		if line:match("^<user>%s*$") then
			return "user"
		end
		if line:match("^<assistant>%s*$") then
			return "assistant"
		end
		return nil
	end

	local function create_message(role, content_lines)
		return {
			role = role,
			content = vim.trim(table.concat(content_lines, "\n")),
		}
	end

	local messages = {}
	local current = {
		role = nil,
		content = {},
	}

	for _, line in ipairs(lines) do
		local role = get_role(line)

		if role then
			if current.role then
				table.insert(messages, create_message(current.role, current.content))
			end
			current.role = role
			current.content = {}
		elseif current.role then
			table.insert(current.content, line)
		end
	end

	if current.role then
		table.insert(messages, create_message(current.role, current.content))
	end

	return messages
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
---@param winid integer|nil @ winid can be deleted here
---@return nil
local function command_set(bufnr, winid)
	vim.api.nvim_create_user_command("Mana", function(opts)
		if opts.args == "open" then
			if not (winid and vim.api.nvim_win_is_valid(winid)) then
				winid = window_create(bufnr)
			end
		elseif opts.args == "close" then
			if winid and vim.api.nvim_win_is_valid(winid) then
				vim.api.nvim_win_close(winid, true)
				winid = nil
			end
		elseif opts.args == "toggle" then
			if winid and vim.api.nvim_win_is_valid(winid) then
				vim.api.nvim_win_close(winid, true)
				winid = nil
			else
				winid = window_create(bufnr)
			end
		end
	end, {
		nargs = 1,
		complete = function()
			return { "open", "close", "toggle" }
		end,
	})
end

---@param bufnr integer
---@param chunk string
---@return nil
local function buffer_append(bufnr, chunk)
	vim.schedule(function()
		local last_line = vim.api.nvim_buf_get_lines(bufnr, -2, -1, false)[1] or ""
		local lines = vim.split(last_line .. chunk, "\n", { plain = true })
		vim.api.nvim_buf_set_lines(bufnr, -2, -1, false, lines)
	end)
end

---@param data string
---@return string
local function parse_stream(data)
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

---@param cfg Mana.ModelConfig
---@param messages Mana.Messages
---@return nil
local function chat(cfg, messages, bufnr)
	buffer_append(bufnr, "\n\n<assistant>\n\n")
	local request_body = {
		model = cfg.name,
		messages = messages,
		stream = true,
	}

	---@diagnostic disable: missing-fields
	Job:new({
		command = "curl",
		args = {
			"-s",
			cfg.url,
			"-H",
			"Content-Type: application/json",
			"-H",
			"Authorization: Bearer " .. cfg.api_key,
			"--no-buffer",
			"-d",
			vim.json.encode(request_body),
		},
		on_stdout = function(_, data)
			local chunk = parse_stream(data)
			if chunk ~= "" and bufnr then
				buffer_append(bufnr, chunk)
			end

			if data:match("data: %[DONE%]") then
				vim.schedule(function()
					buffer_append(bufnr, "\n<user>\n")
				end)
			end
		end,
		on_stderr = function(_, data)
			buffer_append(bufnr, data)
		end,
	}):start()
end

---@param cfg Mana.ModelConfig
---@param bufnr integer
---@return nil
local function keymap_set(cfg, bufnr)
	-- send chat
	vim.api.nvim_buf_set_keymap(bufnr, "n", "<CR>", "", {
		callback = function()
			local messages = buffer_parse(bufnr)
			if messages then
				chat(cfg, messages, bufnr)
			end
		end,
		noremap = true,
		silent = true,
	})

	-- clear chat
	vim.api.nvim_buf_set_keymap(bufnr, "n", "<C-n>", "", {
		callback = function()
			buffer_clear(bufnr)
		end,
		noremap = true,
		silent = true,
	})
end

function M.setup()
	local models_ = {
		{
			url = "https://generativelanguage.googleapis.com/v1beta/chat/completions",
			name = "gemini-2.0-flash-exp",
			system_prompt = "be brief, get to the point",
			temperature = 0.7,
			top_p = 0.9,
			api_key = os.getenv("GOOGLE_AISTUDIO_API_KEY"),
		},
		{
			url = "https://openrouter.ai/api/v1/chat/completions",
			name = "anthropic/claude-3.5-sonnet:beta",
			system_prompt = "",
			temperature = 0.7,
			top_p = 0.9,
			api_key = os.getenv("OPENROUTER_API_KEY"),
		},
	}

	---@type Mana.ModelConfig[]
	local models = vim.tbl_filter(function(cfg)
		return cfg.api_key ~= nil
	end, models_)

	if #models == 0 then
		vim.notify("No models available. Please set up API keys.", vim.log.levels.ERROR)
		return
	end

	local default_model = models[1]
	local prepend = string.format("model: %s\n\n<user>\n\n", default_model.name)

	---@type Mana.BufferState
	local buffer_state = {
		bufnr = buffer_get(prepend),
		winid = nil,
	}

	command_set(buffer_state.bufnr, buffer_state.winid)
	keymap_set(default_model, buffer_state.bufnr)
end

return M
