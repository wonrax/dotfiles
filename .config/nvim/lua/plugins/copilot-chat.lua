-- Yanked and improved from
-- https://github.com/jellydn/lazy-nvim-ide/blob/a4e259de5e466367683a7e89fa943366fb0e8af5/lua/plugins/extras/copilot-chat-v2.lua
-- TODO: not all copilot chat prompts are available in which-key

local floating_window_opts = {
  layout = 'float',
  relative = 'cursor',
  width = 125,
  height = 0.4,
  col = 1,
}

return {
  {
    'CopilotC-Nvim/CopilotChat.nvim',
    branch = 'main',
    dependencies = {
      {
        'zbirenbaum/copilot.lua',
        lazy = false,
        opts = {
          suggestion = {
            auto_trigger = true,
            keymap = {
              accept = '<C-l>',
              accept_word = false,
              accept_line = false,
              next = '<M-]>',
              prev = '<M-[',
              dismiss = '<M-0>',
            },
          },
          filetypes = {
            -- NOTE: we need to explicitly enable these filetypes because if
            -- not the default config will be used
            yaml = true,
            markdown = true,
            gitcommit = true,
            gitrebase = true,
          },
        },
        config = function(_, opts)
          require('copilot').setup(opts)
        end,
      },
      { 'nvim-lua/plenary.nvim' }, -- for curl, log wrapper
      { 'nvim-telescope/telescope.nvim' },
    },
    opts = {
      model = 'claude-opus-4.5',
      show_help = true,
      auto_follow_cursor = false,
      clear_chat_on_new_prompt = false,
      chat_autocomplete = true,
      mappings = {
        -- Close the chat
        close = {
          normal = 'q',
          insert = '<C-c>',
        },
        -- Reset the chat buffer
        reset = {
          normal = '<C-x>',
          insert = nil,
        },
        -- Submit the prompt to Copilot
        submit_prompt = {
          normal = '<CR>',
          insert = '<C-CR>',
        },
        -- Accept the diff
        accept_diff = {
          normal = '<C-y>',
          insert = '<C-y>',
        },
        -- Yank the diff in the response to register
        yank_diff = {
          normal = 'gmy',
        },
        -- Show the diff
        show_diff = {
          normal = 'gmd',
        },
        show_info = {
          normal = 'gi',
        },
        show_context = {
          normal = 'gc',
        },
      },
    },
    event = 'VeryLazy',
    keys = {
      -- Show prompts actions with telescope
      {
        '<leader>cp',
        function()
          require('CopilotChat').select_prompt {
            selection = require('CopilotChat.select').visual or require('CopilotChat.select').line,
          }
        end,
        mode = { 'v', 'x', 'n' },
        desc = 'Prompt actions',
      },
      -- Chat with Copilot in visual mode
      {
        '<leader>cv',
        function()
          local chat = require 'CopilotChat'

          chat.toggle {
            selection = require('CopilotChat.select').visual or require('CopilotChat.select').line,
          }
        end,
        mode = { 'v', 'x', 'n' },
        desc = 'Copilot Chat with selected text',
      },
      {
        '<leader>ci',
        function()
          local chat = require 'CopilotChat'

          chat.toggle {
            selection = require('CopilotChat.select').visual or require('CopilotChat.select').line,
            window = floating_window_opts,
          }
        end,
        mode = { 'v', 'x', 'n' },
        desc = 'Inline chat with selected text',
      },
    },
    config = function(_, opts)
      local chat = require 'CopilotChat'

      chat.setup(vim.tbl_deep_extend('force', opts, {
        prompts = {
          -- Text related prompts
          Wording = {
            prompt = '#buffer\nImprove the grammar and wording of the selected text.',
            description = 'Improve grammar and wording',
          },
          Concise = {
            prompt = '#buffer\nRewrite the selected text to make it more concise.',
            description = 'Make the text more concise',
          },
          Grammar = {
            prompt = '#buffer\nCheck the selected text for grammar errors and suggest corrections.',
            description = 'Check grammar',
          },
        },
        functions = {
          jjlog = {
            description = 'Sample jj log lines for commit style context',
            uri = 'jjlog://{n}',
            schema = {
              type = 'object',
              required = { 'n' },
              properties = {
                n = {
                  type = 'integer',
                  minimum = 1,
                  description = 'Number of commit lines to include',
                },
              },
            },
            resolve = function(input)
              local n = tonumber(input and input.n) or 20
              local M = 10 * n -- Fetch 10x more commits than needed for sampling pool
              local cmd = {
                'jj',
                'log',
                '-n',
                tostring(M),
                '-r',
                '::@',
                '--color=never',
                '-T',
                'builtin_log_oneline',
                '--no-pager',
              }

              local out = require('CopilotChat.utils').system(cmd)

              -- Split jj output into individual commit lines
              local lines = {}
              for line in out.stdout:gmatch '[^\r\n]+' do
                table.insert(lines, line)
              end

              -- Prepare commits with weighted probabilities (recent = higher weight)
              local commits = {}
              for i, line in ipairs(lines) do
                table.insert(commits, {
                  text = line,
                  weight = #lines - (i - 1), -- Linear weight decay (most recent first)
                })
              end

              -- Weighted random selection without replacement
              local selected = {}
              for _ = 1, n do
                if #commits == 0 then
                  break
                end

                -- Calculate total weight of remaining commits
                local total_weight = 0
                for _, c in ipairs(commits) do
                  total_weight = total_weight + c.weight
                end
                if total_weight == 0 then
                  break
                end

                -- Select a random commit based on weights
                local r = math.random() * total_weight
                local accum = 0
                for idx = 1, #commits do
                  accum = accum + commits[idx].weight
                  if accum >= r then
                    table.insert(selected, commits[idx].text)
                    table.remove(commits, idx)
                    break
                  end
                end
              end

              -- Combine selected commits into final output
              local content = table.concat(selected, '\n')

              return {
                {
                  uri = 'jjlog://' .. tostring(n),
                  mimetype = 'text/plain',
                  data = content,
                },
              }
            end,
          },
          jj = {
            description = 'Run jj commands and return output',
            uri = 'jj://{cmd}',
            schema = {
              type = 'object',
              required = { 'cmd' },
              properties = {
                cmd = {
                  type = 'string',
                  enum = { 'diff' },
                  description = 'jj subcommand to run',
                },
              },
            },
            resolve = function(input)
              local cmd_key = (input and input.cmd) or 'diff'
              local cmd

              if cmd_key == 'diff' then
                cmd = {
                  'jj',
                  'diff',
                  '--no-pager',
                  '--config',
                  'ui.diff.tool=["git", "--no-pager", "diff", "--no-color", "$left", "$right"]',
                }
              else
                cmd = { 'jj', cmd_key }
              end

              local out = require('CopilotChat.utils').system(cmd)

              return {
                {
                  uri = 'jj://' .. cmd_key,
                  mimetype = 'text/plain',
                  data = out.stdout,
                },
              }
            end,
          },
        },
      }))

      -- NOTE: plugin author's recommendation for neovim below 0.11. We can
      -- remove this once we're on neovim 0.11
      -- vim.opt.completeopt:append 'noinsert'
      -- vim.opt.completeopt:append 'popup'

      -- Configuring neovim built-in completion here because only this plugin
      -- uses it
      -- Accept completion with Ctrl-y
      -- vim.keymap.set('i', '<C-y>', '<C-y>', { noremap = true })
      -- Navigate completion menu with Ctrl-j and Ctrl-k
      vim.keymap.set('i', '<C-j>', function()
        if vim.fn.pumvisible() == 1 then
          return '<C-n>'
        end
        return '<C-j>'
      end, { expr = true, noremap = true })
      vim.keymap.set('i', '<C-k>', function()
        if vim.fn.pumvisible() == 1 then
          return '<C-p>'
        end
        return '<C-k>'
      end, { expr = true, noremap = true })

      -- Custom buffer for CopilotChat
      vim.api.nvim_create_autocmd('BufEnter', {
        pattern = 'copilot-*',
        callback = function()
          -- vim.opt_local.relativenumber = true
          -- vim.opt_local.number = true

          -- Get current filetype and set it to markdown if the current filetype is copilot-chat
          local ft = vim.bo.filetype
          if ft == 'copilot-chat' then
            vim.bo.filetype = 'markdown'
          end
        end,
      })

      require('which-key').add {
        {
          'gm',
          desc = '+Copilot Chat',
        },
        { 'gmd', desc = 'Show diff' },
        { 'gmp', desc = 'System prompt' },
        { 'gms', desc = 'Show selection' },
        { 'gmy', desc = 'Yank diff' },
      }
    end,
  },
}
