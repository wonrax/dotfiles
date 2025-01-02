return {
  {
    'mistricky/codesnap.nvim',
    -- Build from source instead of using the prebuilt binary because we
    -- already have rust and build deps installed. If you can't build, modify
    -- this to use the prebuilt binary, i.e. just only 'make'.
    build = 'make',
    version = '*',
    opts = {
      mac_window_bar = false,
      has_line_number = true,
      bg_color = '#535c68',
      bg_x_padding = 32,
      bg_y_padding = 32,
      watermark = '',
    },
  },
}
