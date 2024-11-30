-- Yanked and improved from
-- https://github.com/jellydn/lazy-nvim-ide/blob/a4e259de5e466367683a7e89fa943366fb0e8af5/lua/plugins/extras/copilot-chat-v2.lua
-- TODO: not all copilot chat prompts are available in which-key

return {
  {
    'CopilotC-Nvim/CopilotChat.nvim',
    branch = 'canary',
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
        },
        config = function(_, opts)
          require('copilot').setup(opts)
        end,
      },
      { 'nvim-lua/plenary.nvim' }, -- for curl, log wrapper
      { 'nvim-telescope/telescope.nvim' },
    },
    opts = {
      show_help = true,
      auto_follow_cursor = false,
      clear_chat_on_new_prompt = false,
      chat_autocomplete = true,
      mappings = {
        -- Disable to use nvim-cmp
        complete = {
          insert = '',
        },
        -- Close the chat
        close = {
          normal = 'q',
          insert = '<C-c>',
        },
        -- Reset the chat buffer
        reset = {
          normal = '<C-x>',
          insert = '<C-x>',
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
      -- Show help actions with telescope
      -- TODO: currently not working, or I'm using it wrong
      {
        '<leader>ch',
        function()
          local actions = require 'CopilotChat.actions'
          require('CopilotChat.integrations.telescope').pick(actions.help_actions())
        end,
        desc = 'Help actions',
      },
      -- Show prompts actions with telescope
      {
        '<leader>cp',
        function()
          local actions = require 'CopilotChat.actions'
          require('CopilotChat.integrations.telescope').pick(actions.prompt_actions())
        end,
        desc = 'Prompt actions',
      },
      {
        '<leader>cp',
        function()
          local actions = require 'CopilotChat.actions'
          require('CopilotChat.integrations.telescope').pick(actions.prompt_actions { selection = require('CopilotChat.select').visual })
        end,
        mode = 'x',
        desc = 'Prompt actions',
      },
      -- Code related commands
      { '<leader>ce', '<cmd>CopilotChatExplain<cr>', desc = 'Explain code', mode = { 'v' } },
      { '<leader>ct', '<cmd>CopilotChatTests<cr>', desc = 'Generate tests', mode = { 'n', 'v' } },
      { '<leader>cr', '<cmd>CopilotChatReview<cr>', desc = 'Review code', mode = { 'v' } },
      { '<leader>cR', '<cmd>CopilotChatRefactor<cr>', desc = 'Refactor code', mode = { 'v' } },
      { '<leader>cn', '<cmd>CopilotChatRename>', desc = 'Rename identifier', mode = { 'v' } },
      -- Chat with Copilot in visual mode
      {
        '<leader>cv',
        ':CopilotChatVisual',
        mode = 'x',
        desc = 'Copilot Chat with selected text',
      },
      {
        '<leader>cx',
        ':CopilotChatInline<cr>',
        mode = 'x',
        desc = 'Inline chat with selected text',
      },
      -- Custom input for CopilotChat
      {
        '<leader>ci',
        function()
          local input = vim.fn.input 'Ask Copilot: '
          if input ~= '' then
            vim.cmd('CopilotChat ' .. input)
          end
        end,
        desc = 'Ask input',
      },
      -- Generate commit message based on the git diff
      {
        '<leader>cm',
        '<cmd>CopilotChatCommit<cr>',
        desc = 'Generate commit message for all changes',
      },
      {
        '<leader>cM',
        '<cmd>CopilotChatCommitStaged<cr>',
        desc = 'Generate commit message for staged changes',
      },
      -- Quick chat with Copilot
      {
        '<leader>cq',
        function()
          local input = vim.fn.input 'Quick Chat: '
          if input ~= '' then
            vim.cmd('CopilotChatBuffer ' .. input)
          end
        end,
        desc = 'Quick chat',
      },
      -- Debug
      { '<leader>cd', '<cmd>CopilotChatDebugInfo<cr>', desc = 'Debug Info' },
      -- Fix the issue with diagnostic
      { '<leader>cf', '<cmd>CopilotChatFixDiagnostic<cr>', desc = 'Fix Diagnostic' },
      -- Clear buffer and chat history
      { '<leader>cl', '<cmd>CopilotChatReset<cr>', desc = 'Clear buffer and chat history' },
      -- Toggle Copilot Chat Vsplit
      { '<leader>cv', '<cmd>CopilotChatToggle<cr>', desc = 'Toggle' },
    },
    config = function(_, opts)
      local chat = require 'CopilotChat'
      local floating_window_opts = {
        layout = 'float',
        relative = 'cursor',
        width = 125,
        height = 0.4,
        col = 1,
      }

      chat.setup(vim.tbl_deep_extend('force', opts, {
        prompts = {
          -- Code related prompts
          Explain = {
            prompt = '> /COPILOT_EXPLAIN\n\nWrite an explanation for the selected code as paragraphs of text.',
          },
          Review = {
            prompt = '> /COPILOT_REVIEW\n\nReview the selected code.',
            -- see config.lua for implementation
          },
          Fix = {
            prompt = '> /COPILOT_GENERATE\n\nThere is a problem in this code. Rewrite the code to show it with the bug fixed.',
          },
          Optimize = {
            prompt = '> /COPILOT_GENERATE\n\nOptimize the selected code to improve performance and readability.',
          },
          Docs = {
            prompt = '> /COPILOT_GENERATE\n\nPlease add documentation comments to the selected code.',
          },
          Tests = {
            prompt = '> /COPILOT_GENERATE\n\nPlease generate tests for my code.',
          },
          Commit = {
            prompt = '> #git:staged\n\nWrite commit message for the change with commitizen convention. Make sure the title has maximum 50 characters and message is wrapped at 72 characters. Wrap the whole message in code block with language gitcommit.',
            window = floating_window_opts,
          },
          -- Text related prompts
          Summarize = {
            prompt = '/COPILOT_EXPLAIN\n\nSummarize the selected text.',
            description = 'Summarize the text',
            window = floating_window_opts,
          },
          Spelling = {
            prompt = '/COPILOT_GENERATE\n\nCorrect any grammar and spelling errors in the following text.',
            description = 'Correct spelling and grammar',
            window = floating_window_opts,
          },
          Wording = {
            prompt = '/COPILOT_GENERATE\n\nImprove the grammar and wording of the following text.',
            description = 'Improve grammar and wording',
            window = floating_window_opts,
          },
          Concise = {
            prompt = '/COPILOT_GENERATE\n\nRewrite the following text to make it more concise.',
            description = 'Make the text more concise',
            window = floating_window_opts,
          },
        },
      }))

      -- Custom buffer for CopilotChat
      vim.api.nvim_create_autocmd('BufEnter', {
        pattern = 'copilot-*',
        callback = function()
          vim.opt_local.relativenumber = true
          vim.opt_local.number = true

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
