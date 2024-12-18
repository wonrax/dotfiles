return {
  {
    'nvimdev/lspsaga.nvim',
    config = function()
      require('lspsaga').setup {
        code_action = {
          show_server_name = true,
        },
        lightbulb = {
          enable = false,
        },
        ui = {
          border = 'rounded',
          lines = { '└', '├', '│', '─', '┌' },
        },
        symbol_in_winbar = {
          -- Disabled to render our own padded custom symbols
          enable = false,
          show_file = false,
        },
        rename = {
          keys = {
            -- quit = 'q',
          },
        },
        diagnostic = {
          keys = {
            quit = { 'q', '<ESC>' },
            quit_in_show = { 'q', '<ESC>' },
            toggle_or_jump = { 'o', '<CR>' },
          },
        },
      }

      require('which-key').add {
        { '<leader>d', group = 'Lsp [D]iagnostic' },
        { '<leader>dd', desc = 'Show [D]iagnostic messages in buffer' },
        { '<leader>dw', desc = 'Show [D]iagnostic messages in [w]orkspace' },
      }

      vim.api.nvim_create_autocmd('CursorMoved', {
        callback = function()
          local bar = require('lspsaga.symbol.winbar').get_bar()
          vim.opt_local.winbar = bar and ' ' .. bar or ''
        end,
      })
    end,
    keys = {
      {
        '<leader>rn',
        mode = { 'n' },
        function()
          vim.cmd 'Lspsaga rename'
        end,
      },
      {
        ']d',
        mode = { 'n' },
        function()
          vim.cmd 'Lspsaga diagnostic_jump_next'
        end,
      },
      {
        '[d',
        mode = { 'n' },
        function()
          vim.cmd 'Lspsaga diagnostic_jump_prev'
        end,
      },
      {
        '<leader>dd',
        mode = { 'n' },
        function()
          vim.cmd 'Lspsaga show_buf_diagnostics ++normal'
        end,
      },
      {
        '<leader>dw',
        mode = { 'n' },
        function()
          vim.cmd 'Lspsaga show_workspace_diagnostics ++normal'
        end,
      },
      {
        '<leader>o',
        mode = { 'n' },
        function()
          vim.cmd 'Lspsaga outline'
        end,
      },
      {
        'gr',
        mode = { 'n' },
        function()
          vim.cmd 'Lspsaga finder ref'
        end,
      },
      {
        'gD',
        mode = { 'n' },
        function()
          vim.cmd 'Lspsaga finder ref+def+imp'
        end,
      },
      {
        'gd',
        mode = { 'n' },
        function()
          -- Jump to definition if there is only one, otherwise open Lspsaga finder

          local params = vim.lsp.util.make_position_params()

          vim.lsp.buf_request(0, 'textDocument/definition', params, function(err, result, ctx, config)
            if err then
              print('Error: ' .. err.message)
              return
            end

            if not result or vim.tbl_isempty(result) then
              return
            end

            local count = 0
            if vim.tbl_islist(result) then
              count = #result
            elseif type(result) == 'table' then
              count = 1
            end

            if count == 1 then
              -- Jump directly to the single definition
              vim.lsp.buf.definition()
            else
              -- Open Lspsaga finder for multiple definitions
              vim.cmd 'Lspsaga finder def'
            end
          end)
        end,
      },
    },
    event = 'LspAttach',
    dependencies = {
      'nvim-treesitter/nvim-treesitter', -- optional
      'nvim-tree/nvim-web-devicons', -- optional
    },
  },
}
