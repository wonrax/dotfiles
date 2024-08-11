return {
  { -- Fuzzy Finder (files, lsp, etc)
    'nvim-telescope/telescope.nvim',
    version = '0.1.*',
    event = 'VimEnter',
    dependencies = {
      'nvim-lua/plenary.nvim',
      { -- If encountering errors, see telescope-fzf-native README for installation instructions
        'nvim-telescope/telescope-fzf-native.nvim',

        -- `build` is used to run some command when the plugin is installed/updated.
        -- This is only run then, not every time Neovim starts up.
        build = 'make',

        -- `cond` is a condition used to determine whether this plugin should be
        -- installed and loaded.
        cond = function()
          return vim.fn.executable 'make' == 1
        end,
      },
      { 'nvim-telescope/telescope-ui-select.nvim' },

      -- Useful for getting pretty icons, but requires a Nerd Font.
      { 'nvim-tree/nvim-web-devicons', enabled = vim.g.have_nerd_font },
      'nvim-telescope/telescope-live-grep-args.nvim',
    },
    config = function()
      -- Telescope is a fuzzy finder that comes with a lot of different things that
      -- it can fuzzy find! It's more than just a "file finder", it can search
      -- many different aspects of Neovim, your workspace, LSP, and more!
      --
      -- The easiest way to use Telescope, is to start by doing something like:
      --  :Telescope help_tags
      --
      -- After running this command, a window will open up and you're able to
      -- type in the prompt window. You'll see a list of `help_tags` options and
      -- a corresponding preview of the help.
      --
      -- Two important keymaps to use while in Telescope are:
      --  - Insert mode: <c-/>
      --  - Normal mode: ?
      --
      -- This opens a window that shows you all of the keymaps for the current
      -- Telescope picker. This is really useful to discover what Telescope can
      -- do as well as how to actually do it!

      local lga_actions = require 'telescope-live-grep-args.actions'

      -- [[ Configure Telescope ]]
      -- See `:help telescope` and `:help telescope.setup()`
      require('telescope').setup {
        extensions = {
          ['ui-select'] = {
            require('telescope.themes').get_dropdown(),
          },
          frecency = {
            -- do not show confirmation dialog when deleting entries because it
            -- may conflict with auto-session
            db_safe_mode = false,
          },
          live_grep_args = {
            auto_quoting = true, -- enable/disable auto-quoting
            -- define mappings, e.g.
            mappings = { -- extend mappings
              i = {
                ['<C-a>'] = lga_actions.quote_prompt(),
                ['<C-i>'] = lga_actions.quote_prompt { postfix = ' --iglob ' },
                -- freeze the current list and start a fuzzy search in the frozen list
                ['<C-space>'] = require('telescope.actions').to_fuzzy_refine,
              },
            },
            -- ... also accepts theme settings, for example:
            -- theme = "dropdown", -- use dropdown theme
            -- theme = { }, -- use own theme spec
            -- layout_config = { mirror=true }, -- mirror preview pane
          },
        },
        -- You can put your default mappings / updates / etc. in here
        --  All the info you're looking for is in `:help telescope.setup()`
        --
        defaults = {
          mappings = {
            i = {
              ['<esc>'] = require('telescope.actions').close,
              ['<c-j>'] = require('telescope.actions').move_selection_next,
              ['<c-k>'] = require('telescope.actions').move_selection_previous,
            },
          },
          path_display = { 'filename_first' },

          -- Responsive picker layout
          -- https://github.com/nvim-telescope/telescope.nvim/pull/2572
          create_layout = function(picker)
            local border = {
              results = {
                top_left = '┌',
                top = '─',
                top_right = '┬',
                right = '│',
                bottom_right = '',
                bottom = '',
                bottom_left = '',
                left = '│',
              },
              results_patch = {
                minimal = {
                  top_left = '┌',
                  top_right = '┐',
                },
                horizontal = {
                  top_left = '┌',
                  top_right = '┬',
                },
                vertical = {
                  top_left = '├',
                  top_right = '┤',
                },
              },
              prompt = {
                top_left = '├',
                top = '─',
                top_right = '┤',
                right = '│',
                bottom_right = '┘',
                bottom = '─',
                bottom_left = '└',
                left = '│',
              },
              prompt_patch = {
                minimal = {
                  bottom_right = '┘',
                },
                horizontal = {
                  bottom_right = '┴',
                },
                vertical = {
                  bottom_right = '┘',
                },
              },
              preview = {
                top_left = '┌',
                top = '─',
                top_right = '┐',
                right = '│',
                bottom_right = '┘',
                bottom = '─',
                bottom_left = '└',
                left = '│',
              },
              preview_patch = {
                minimal = {},
                horizontal = {
                  bottom = '─',
                  bottom_left = '',
                  bottom_right = '┘',
                  left = '',
                  top_left = '',
                },
                vertical = {
                  bottom = '',
                  bottom_left = '',
                  bottom_right = '',
                  left = '│',
                  top_left = '┌',
                },
              },
            }

            local Layout = require 'nui.layout'
            local Popup = require 'nui.popup'

            local TSLayout = require 'telescope.pickers.layout'

            local results = Popup {
              focusable = false,
              border = {
                style = border.results,
                text = {
                  top = picker.results_title,
                  top_align = 'center',
                },
              },
              win_options = {
                winhighlight = 'Normal:Normal',
              },
            }

            local prompt = Popup {
              enter = true,
              border = {
                style = border.prompt,
                text = {
                  top = picker.prompt_title,
                  top_align = 'center',
                },
              },
              win_options = {
                winhighlight = 'Normal:Normal',
              },
            }

            local preview = Popup {
              focusable = false,
              border = {
                style = border.preview,
                text = {
                  top = picker.preview_title,
                  top_align = 'center',
                },
              },
            }

            local box_by_kind = {
              vertical = Layout.Box({
                Layout.Box(preview, { grow = 1 }),
                Layout.Box(results, { grow = 1 }),
                Layout.Box(prompt, { size = 3 }),
              }, { dir = 'col' }),
              horizontal = Layout.Box({
                Layout.Box({
                  Layout.Box(results, { grow = 1 }),
                  Layout.Box(prompt, { size = 3 }),
                }, { dir = 'col', size = '50%' }),
                Layout.Box(preview, { size = '50%' }),
              }, { dir = 'row' }),
              minimal = Layout.Box({
                Layout.Box(results, { grow = 1 }),
                Layout.Box(prompt, { size = 3 }),
              }, { dir = 'col' }),
            }

            local function get_box()
              local height, width = vim.o.lines, vim.o.columns
              local box_kind = 'horizontal'
              if width < 100 then
                box_kind = 'vertical'
                if height < 40 then
                  box_kind = 'minimal'
                end
              elseif width < 120 then
                box_kind = 'minimal'
              end
              return box_by_kind[box_kind], box_kind
            end

            local function prepare_layout_parts(layout, box_type)
              layout.results = TSLayout.Window(results)
              results.border:set_style(border.results_patch[box_type])

              layout.prompt = TSLayout.Window(prompt)
              prompt.border:set_style(border.prompt_patch[box_type])

              if box_type == 'minimal' then
                layout.preview = nil
              else
                layout.preview = TSLayout.Window(preview)
                preview.border:set_style(border.preview_patch[box_type])
              end
            end

            local box, box_kind = get_box()
            local layout = Layout({
              relative = 'editor',
              position = '50%',
              size = {
                height = '60%',
                width = '90%',
              },
            }, box)

            layout.picker = picker
            prepare_layout_parts(layout, box_kind)

            local layout_update = layout.update
            function layout:update()
              local box, box_kind = get_box()
              prepare_layout_parts(layout, box_kind)
              layout_update(self, box)
            end

            return TSLayout(layout)
          end,
        },
      }

      -- Enable Telescope extensions if they are installed
      pcall(require('telescope').load_extension, 'fzf')
      pcall(require('telescope').load_extension, 'ui-select')
      pcall(require('telescope').load_extension, 'live_grep_args')

      -- See `:help telescope.builtin`
      local builtin = require 'telescope.builtin'

      -- We cache the results of "git rev-parse"
      -- Process creation is expensive in Windows, so this reduces latency
      local is_inside_work_tree = {}

      -- https://github.com/nvim-telescope/telescope.nvim/wiki/Configuration-Recipes#falling-back-to-find_files-if-git_files-cant-find-a-git-directory
      local find_project_files = function(opts)
        opts = opts or {}

        local cwd = vim.fn.getcwd()
        if is_inside_work_tree[cwd] == nil then
          vim.fn.system 'git rev-parse --is-inside-work-tree'
          is_inside_work_tree[cwd] = vim.v.shell_error == 0
        end

        if is_inside_work_tree[cwd] then
          opts.show_untracked = true
          builtin.git_files(opts)
        else
          builtin.find_files(opts)
        end
      end

      -- https://github.com/nvim-telescope/telescope.nvim/wiki/Configuration-Recipes#live-grep-from-project-git-root-with-fallback
      local live_grep_from_project_git_root = function(grep_handler)
        local function is_git_repo()
          vim.fn.system 'git rev-parse --is-inside-work-tree'

          return vim.v.shell_error == 0
        end

        local function get_git_root()
          local dot_git_path = vim.fn.finddir('.git', '.;')
          return vim.fn.fnamemodify(dot_git_path, ':h')
        end

        local opts = {
          hidden = true,
        }

        if is_git_repo() then
          opts = {
            cwd = get_git_root(),
          }
        end

        local vimgrep_arguments = { unpack(require('telescope.config').values.vimgrep_arguments) }
        -- I want to search in hidden/dot files.
        table.insert(vimgrep_arguments, '--hidden')
        -- I don't want to search in the `.git` directory.
        table.insert(vimgrep_arguments, '--glob')
        table.insert(vimgrep_arguments, '!**/.git/*')

        if grep_handler == nil then
          grep_handler = builtin.live_grep
        end

        grep_handler {
          prompt_title = 'Live Grep (from project git root)',
          vimgrep_arguments = vimgrep_arguments,
          opts = opts,
        }
      end

      vim.keymap.set('n', '<leader>fh', builtin.help_tags, { desc = '[F]ind [H]elp' })
      vim.keymap.set('n', '<leader>fk', builtin.keymaps, { desc = '[F]ind [K]eymaps' })
      vim.keymap.set('n', '<leader>fs', builtin.builtin, { desc = '[F]ind [S]elect Telescope' })
      vim.keymap.set('n', '<leader>fw', builtin.grep_string, { desc = '[F]ind current [W]ord' })
      vim.keymap.set('n', '<leader>fg', function()
        live_grep_from_project_git_root(require('telescope').extensions.live_grep_args.live_grep_args)
      end, { desc = '[F]ind by [G]rep' })
      vim.keymap.set('n', '<leader>fd', builtin.diagnostics, { desc = '[F]ind [D]iagnostics' })
      vim.keymap.set('n', '<leader>fr', builtin.resume, { desc = '[F]ind [R]esume' })
      vim.keymap.set('n', '<leader>f.', builtin.oldfiles, { desc = '[F]ind Recent Files ("." for repeat)' })
      vim.keymap.set('n', '<leader><leader>', builtin.buffers, { desc = '[ ] Find existing buffers' })

      -- Temporarily disable this so my muscle memory doesn't get confused
      -- with the new smart-open keybind.
      -- vim.keymap.set('n', '<leader>ff', find_project_files, { desc = '[F]ind [F]iles' })

      -- Slightly advanced example of overriding default behavior and theme
      vim.keymap.set('n', '<leader>/', function()
        -- You can pass additional configuration to Telescope to change the theme, layout, etc.
        builtin.current_buffer_fuzzy_find(require('telescope.themes').get_dropdown {
          winblend = 10,
          previewer = false,
        })
      end, { desc = '[/] Fuzzily search in current buffer' })

      -- It's also possible to pass additional configuration options.
      --  See `:help telescope.builtin.live_grep()` for information about particular keys
      vim.keymap.set('n', '<leader>f/', function()
        builtin.live_grep {
          grep_open_files = true,
          prompt_title = 'Live Grep in Open Files',
        }
      end, { desc = '[F]ind [/] in Open Files' })

      -- Shortcut for searching your Neovim configuration files
      vim.keymap.set('n', '<leader>fn', function()
        builtin.find_files { cwd = vim.fn.stdpath 'config' }
      end, { desc = '[F]ind [N]eovim files' })
    end,
  },
}
