-- Mostly yanked from
-- https://github.com/jellydn/lazy-nvim-ide/blob/a4e259de5e466367683a7e89fa943366fb0e8af5/lua/plugins/extras/copilot-chat-v2.lua

local prompts = {
  -- Code related prompts
  Explain = 'Explain how the following code works.',
  Review = 'Review the following code and provide suggestions for improvement.',
  Tests = 'Explain how the selected code works, then generate unit tests for it.',
  Refactor = 'Refactor the following code to improve its clarity and readability.',
  FixCode = 'Fix the following code to make it work as intended.',
  FixError = 'Explain the error in the following text and provide a solution.',
  BetterNamings = 'Provide better names for the following variables and functions.',
  Documentation = 'Provide documentation for the following code.',
  SwaggerApiDocs = 'Provide documentation for the following API using Swagger.',
  SwaggerJsDocs = 'Write JSDoc for the following API using Swagger.',
  -- Text related prompts
  Summarize = 'Summarize the following text.',
  Spelling = 'Correct any grammar and spelling errors in the following text.',
  Wording = 'Improve the grammar and wording of the following text.',
  Concise = 'Rewrite the following text to make it more concise.',
}

return {
  {
    'CopilotC-Nvim/CopilotChat.nvim',
    branch = 'canary',
    dependencies = {
      { 'github/copilot.vim' }, -- or github/copilot.vim
      { 'nvim-lua/plenary.nvim' }, -- for curl, log wrapper
      { 'nvim-telescope/telescope.nvim' },
    },
    opts = {
      prompts = prompts,
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
        -- Show the prompt
        show_system_prompt = {
          normal = 'gmp',
        },
        -- Show the user selection
        show_user_selection = {
          normal = 'gms',
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
        desc = 'CopilotChat - Help actions',
      },
      -- Show prompts actions with telescope
      {
        '<leader>cp',
        function()
          local actions = require 'CopilotChat.actions'
          require('CopilotChat.integrations.telescope').pick(actions.prompt_actions())
        end,
        desc = 'CopilotChat - Prompt actions',
      },
      {
        '<leader>cp',
        ":lua require('CopilotChat.integrations.telescope').pick(require('CopilotChat.actions').prompt_actions({selection = require('CopilotChat.select').visual}))<CR>",
        mode = 'x',
        desc = 'CopilotChat - Prompt actions',
      },
      -- Code related commands
      { '<leader>ce', '<cmd>CopilotChatExplain<cr>', desc = 'CopilotChat - Explain code', mode = { 'n', 'v' } },
      { '<leader>ct', '<cmd>CopilotChatTests<cr>', desc = 'CopilotChat - Generate tests', mode = { 'n', 'v' } },
      { '<leader>cr', '<cmd>CopilotChatReview<cr>', desc = 'CopilotChat - Review code', mode = { 'n', 'v' } },
      { '<leader>cR', '<cmd>CopilotChatRefactor<cr>', desc = 'CopilotChat - Refactor code', mode = { 'n', 'v' } },
      { '<leader>cn', '<cmd>CopilotChatBetterNamings<cr>', desc = 'CopilotChat - Better Naming', mode = { 'n', 'v' } },
      -- Chat with Copilot in visual mode
      {
        '<leader>cv',
        ':CopilotChatVisual',
        mode = 'x',
        desc = 'CopilotChat - Open in vertical split',
      },
      {
        '<leader>cx',
        ':CopilotChatInline<cr>',
        mode = 'x',
        desc = 'CopilotChat - Inline chat',
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
        desc = 'CopilotChat - Ask input',
      },
      -- Generate commit message based on the git diff
      {
        '<leader>cm',
        '<cmd>CopilotChatCommit<cr>',
        desc = 'CopilotChat - Generate commit message for all changes',
      },
      {
        '<leader>cM',
        '<cmd>CopilotChatCommitStaged<cr>',
        desc = 'CopilotChat - Generate commit message for staged changes',
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
        desc = 'CopilotChat - Quick chat',
      },
      -- Debug
      { '<leader>cd', '<cmd>CopilotChatDebugInfo<cr>', desc = 'CopilotChat - Debug Info' },
      -- Fix the issue with diagnostic
      { '<leader>cf', '<cmd>CopilotChatFixDiagnostic<cr>', desc = 'CopilotChat - Fix Diagnostic' },
      -- Clear buffer and chat history
      { '<leader>cl', '<cmd>CopilotChatReset<cr>', desc = 'CopilotChat - Clear buffer and chat history' },
      -- Toggle Copilot Chat Vsplit
      { '<leader>cv', '<cmd>CopilotChatToggle<cr>', desc = 'CopilotChat - Toggle' },
    },
    config = function(_, opts)
      local chat = require 'CopilotChat'
      local select = require 'CopilotChat.select'

      -- Override the git prompts message
      opts.prompts.Commit = {
        prompt = 'Write commit message for the change with commitizen convention',
        selection = select.gitdiff,
      }
      opts.prompts.CommitStaged = {
        prompt = 'Write commit message for the change with commitizen convention',
        selection = function(source)
          return select.gitdiff(source, true)
        end,
      }

      chat.setup(opts)
      -- Setup the CMP integration
      require('CopilotChat.integrations.cmp').setup()

      vim.api.nvim_create_user_command('CopilotChatVisual', function(args)
        chat.ask(args.args, { selection = select.visual })
      end, { nargs = '*', range = true })

      -- Inline chat with Copilot
      vim.api.nvim_create_user_command('CopilotChatInline', function(args)
        chat.ask(args.args, {
          selection = select.visual,
          window = {
            layout = 'float',
            relative = 'cursor',
            width = 1,
            height = 0.4,
            row = 1,
          },
        })
      end, { nargs = '*', range = true })

      -- Restore CopilotChatBuffer
      vim.api.nvim_create_user_command('CopilotChatBuffer', function(args)
        chat.ask(args.args, { selection = select.buffer })
      end, { nargs = '*', range = true })

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
