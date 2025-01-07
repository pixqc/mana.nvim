LLM chat in neovim. Supports any model from Openrouter and Google AIStudio.

Demo (todo: link)

Provided APIs:
- `:Mana open` to open the window
- `:Mana close` to close the window
- `:Mana toggle` to toggle the window
- `:Mana paste` to paste content from visual block into chat buffer
- `:Mana switch` to switch model
- `:Mana clear` to clear the buffer (new chat)

Set up the keymap however you like, here's my Mana-related keymaps:

```lua
vim.keymap.set('n', '\\', ':Mana toggle<CR>')
vim.keymap.set('n', '<leader>ms', ':Mana switch<CR>')
vim.keymap.set('v', '<leader>mq', ':Mana paste<CR>')
vim.keymap.set('n', '<leader>mc', ':Mana clear<CR>')
```

On the chat window, press enter on normal mode to send chat.

Example config (lazy.nvim)

```lua
{
  'pixqc/mana.nvim',
  main = 'mana',
  opts = {
    default_model = 'deepseekv3',
    models = {
      sonnet = {
        endpoint = 'openrouter',
        name = 'anthropic/claude-3.5-sonnet:beta',
        system_prompt = '',
        temperature = 0.7,
        top_p = 0.9,
      },
      deepseekv3 = {
        endpoint = 'openrouter',
        name = 'deepseek/deepseek-chat',
        system_prompt = '',
        temperature = 0.7,
        top_p = 0.9,
      },
      gemini_flash_thinking = {
        endpoint = 'aistudio',
        name = 'gemini-2.0-flash-thinking-exp',
        system_prompt = '',
        temperature = 0.7,
        top_p = 0.9,
      },
    },
    envs = {
      aistudio = 'GOOGLE_AISTUDIO_API_KEY',
      openrouter = 'OPENROUTER_API_KEY',
    },
  },
},
```
