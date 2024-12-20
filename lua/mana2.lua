local Job = require("plenary.job")
local M = {}

---@alias Mana2.Model "gemini" | "sonnet" | "gemini_thinking"
---@alias Mana2.Endpoint "aistudio" | "openrouter"
---@alias Mana2.EndpointConfig_ {url: string, api_key: string}
---@alias Mana2.EndpointConfig table<Mana2.Endpoint, Mana2.EndpointConfig_>
---@alias Mana2.ModelConfig_ {endpoint: Mana2.Endpoint, system_prompt: string, temperature: number, top_p: number}
---@alias Mana2.ModelConfig table<Mana2.Model, Mana2.ModelConfig_>
---@alias Mana2.BufferState {winid: integer|nil, bufnr: integer}

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

---@param bufnr integer
---@param chunk string
---@return nil
local function buffer_append(bufnr, chunk)
	local last_line = vim.api.nvim_buf_get_lines(bufnr, -2, -1, false)[1] or ""
	local lines = vim.split(last_line .. chunk, "\n", { plain = true })
	vim.api.nvim_buf_set_lines(bufnr, -2, -1, false, lines)
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
				local chunk = parse_stream(data)
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

M.setup = function()
	---@type Mana2.ModelConfig
	local model_cfgs = {
		gemini = {
			endpoint = "aistudio",
			name = "gemini-2.0-flash-exp",
			system_prompt = "be brief, get to the point",
			temperature = 0.7,
			top_p = 0.9,
		},
		sonnet = {
			endpoint = "openrouter",
			name = "anthropic/claude-3.5-sonnet:beta",
			system_prompt = "",
			temperature = 0.7,
			top_p = 0.9,
		},
		gemini_thinking = {
			endpoint = "aistudio",
			name = "gemini-2.0-flash-thinking-exp",
			system_prompt = "",
			temperature = 0.7,
			top_p = 0.9,
		},
	}

	local endpoint_cfgs_ = {
		aistudio = {
			url = "https://generativelanguage.googleapis.com/v1beta/chat/completions",
			env = "GOOGLE_AISTUDIO_API_KEY",
		},
		openrouter = {
			url = "https://openrouter.ai/api/v1/chat/completions",
			env = "OPENROUTER_API_KEY",
		},
	}

	local endpoint_cfgs = mk_endpoint_cfgs(endpoint_cfgs_)
	local fetcher = {}
	for model, model_cfg in pairs(model_cfgs) do
		local endpoint = model_cfg.endpoint
		local endpoint_cfg = endpoint_cfgs[endpoint]
		if endpoint_cfg then
			fetcher[model] = fetch(model_cfg, endpoint_cfg, 1)
		end
	end
end

return M
