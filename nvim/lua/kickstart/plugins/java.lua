return {
  'mfussenegger/nvim-jdtls',
  ft = 'java',
  dependencies = { 'mason-org/mason.nvim' },
  config = function()
    local jdtls = require 'jdtls'
    local mason_packages = vim.fn.stdpath 'data' .. '/mason/packages'

    -- Collect DAP bundles (present only after Mason installs them)
    local bundles = {}
    local debug_jar = vim.fn.glob(
      mason_packages .. '/java-debug-adapter/extension/server/com.microsoft.java.debug.plugin-*.jar', true)
    if debug_jar ~= '' then
      table.insert(bundles, debug_jar)
    end
    vim.list_extend(bundles, vim.split(
      vim.fn.glob(mason_packages .. '/java-test/extension/server/*.jar', true),
      '\n', { trimempty = true }))

    local function get_config()
      local root_dir = jdtls.setup.find_root { '.git', 'mvnw', 'gradlew', 'pom.xml', 'build.gradle', 'build.gradle.kts' }
        or vim.fn.getcwd()

      local workspace_dir = vim.fn.stdpath 'data' .. '/jdtls-workspaces/' .. root_dir:gsub('/', '_')

      return {
        cmd = {
          'jdtls',
          '--jvm-arg=-javaagent:' .. vim.fn.expand '~/.local/share/lombok/lombok.jar',
          '-data', workspace_dir,
        },
        root_dir = root_dir,
        capabilities = require('blink.cmp').get_lsp_capabilities(),
        init_options = {
          bundles = bundles,
          extendedClientCapabilities = jdtls.extendedClientCapabilities,
        },
        settings = {
          java = {
            eclipse = { downloadSources = true },
            maven = { downloadSources = true },
            configuration = { updateBuildConfiguration = 'interactive' },
            implementationsCodeLens = { enabled = true },
            referencesCodeLens = { enabled = true },
          },
        },
        on_attach = function(_, _)
          if #bundles > 0 then
            jdtls.setup_dap { hotcodereplace = 'auto' }
            require('jdtls.dap').setup_dap_main_class_configs()
          end
        end,
      }
    end

    vim.api.nvim_create_autocmd('FileType', {
      pattern = 'java',
      group = vim.api.nvim_create_augroup('nvim-jdtls', { clear = true }),
      callback = function()
        jdtls.start_or_attach(get_config())
      end,
    })
  end,
}
