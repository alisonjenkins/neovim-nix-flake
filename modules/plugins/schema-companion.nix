{ lib, ... }:
lib.nixvim.plugins.mkNeovimPlugin {
  name = "schema-companion";
  package = "schema-companion-nvim";
  moduleName = "schema-companion";

  description = ''
    Schema-companion.nvim integration. Calls `require("schema-companion").setup(settings)`
    via the standard NixVim pipeline, then layers schema-aware capabilities and
    handlers on top of NixVim's `vim.lsp.config(server, ...)` calls per declared
    adapter (`vim.lsp.config(server, sc.setup_client(adapter, {}))`).
  '';

  maintainers = [ ];

  settingsExample = {
    log_level.__raw = "vim.log.levels.WARN";
  };

  extraOptions = {
    adapters = lib.mkOption {
      default = { };
      description = ''
        Per-adapter configurations. Attribute name is the schema-companion
        adapter (e.g. `yamlls`, `helmls`). Each adapter wires
        `vim.lsp.config(<server>, schema_companion.setup_client(<adapter>, {}))`
        inside `vim.schedule` so the merge runs after NixVim's auto-emitted
        `vim.lsp.config` for the same server.
      '';
      type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        options = {
          server = lib.mkOption {
            type = lib.types.str;
            default = name;
            description = ''
              Neovim LSP server name passed to `vim.lsp.config`. Defaults to
              the adapter name. Override when the LSP server name differs from
              the adapter (e.g. `helmls` adapter targets `helm_ls` server).
            '';
          };
          sources = lib.mkOption {
            default = [ ];
            description = ''
              Source list passed to the adapter. Each entry's `type` field
              selects the schema-companion source kind:
              - `matcher`: `sc.sources.matchers.<name>.setup(<settings>)`.
              - `lsp`:     `sc.sources.lsp.setup()`.
              - `schemas`: `sc.sources.schemas.setup(<schemas>)`.
            '';
            type = lib.types.listOf (lib.types.submodule {
              options = {
                type = lib.mkOption {
                  type = lib.types.enum [ "matcher" "lsp" "schemas" ];
                };
                name = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "Matcher name (required when type=matcher).";
                };
                settings = lib.mkOption {
                  type = with lib.types; attrsOf anything;
                  default = { };
                  description = "Matcher settings (type=matcher only).";
                };
                schemas = lib.mkOption {
                  type = with lib.types; listOf (attrsOf anything);
                  default = [ ];
                  description = "Schema definitions (type=schemas only).";
                };
              };
            });
          };
        };
      }));
    };
  };

  extraConfig = cfg:
    let
      renderSource = s:
        if s.type == "matcher" then
          assert lib.assertMsg (s.name != null) "schema-companion source type=matcher requires a name";
          "sc.sources.matchers.${s.name}.setup(${lib.nixvim.toLuaObject s.settings})"
        else if s.type == "lsp" then
          "sc.sources.lsp.setup()"
        else
          "sc.sources.schemas.setup(${lib.nixvim.toLuaObject s.schemas})";

      renderAdapter = adapter: a: ''
        vim.lsp.config(${lib.nixvim.toLuaObject a.server}, sc.setup_client(
          sc.adapters.${adapter}.setup({
            sources = {
              ${lib.concatMapStringsSep ",\n              " renderSource a.sources},
            },
          }),
          {}
        ))
      '';
    in
    {
      extraConfigLua = ''
        -- yamlls native custom-schema-request flow:
        -- yamlls asks the client for the schema URI per buffer via
        -- `custom/schema/request`. We answer with schema-companion's matcher
        -- (kubernetes GVK detection). yamlls fetches + validates strictly.
        -- No modeline edit, no yaml.schemas mutation, no oneOf dispatcher.
        --
        -- yaml.schemas is left empty (schemastore.nvim yaml mode disabled) so
        -- the customSchemaProvider path in yamlSchemaService.getSchemaForResource
        -- isn't bypassed by competing matches.
        local function _sc_match_uri(bufnr)
          if vim.fn.bufloaded(bufnr) == 0 then pcall(vim.fn.bufload, bufnr) end
          -- Inline the kubernetes apiVersion+kind → datreeio CRD URL mapping.
          -- Avoids dependency on schema-companion's per-buffer context which
          -- isn't reliably set up in our flow (schedule ordering vs LSP attach).
          local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
          local group, version, kind
          for _, line in ipairs(lines) do
            local g, v = line:match("^apiVersion:%s*([^%s/]+)/([^%s]+)")
            if g then group, version = g, v end
            local k = line:match("^kind:%s*(%S+)")
            if k then kind = k end
            if group and version and kind then break end
          end
          if not (group and version and kind) then return nil end
          return string.format(
            "https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/%s/%s_%s.json",
            group:lower(), kind:lower(), version:lower()
          )
        end

        vim.lsp.handlers["custom/schema/request"] = function(_, params)
          local resource = type(params) == "table" and (params.uri or params[1]) or params
          if type(resource) ~= "string" then return {} end
          local ok, bufnr = pcall(vim.uri_to_bufnr, resource)
          if not ok or not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
            return {}
          end
          local uri = _sc_match_uri(bufnr)
          if uri then return uri end
          return {}
        end

        -- Send `yaml/registerCustomSchemaRequest` from yamlls's on_init.
        -- This must run BEFORE yamlls processes textDocument/didOpen, so
        -- on_init is the right hook (LspAttach fires too late on first buffer).
        vim.lsp.config("yamlls", {
          on_init = function(client)
            pcall(function() client:notify("yaml/registerCustomSchemaRequest") end)
            return true
          end,
        })

        ${lib.optionalString (cfg.adapters != { }) ''
          -- schema-companion picker UI integration (best-effort; does not gate
          -- validation, which is handled via custom/schema/request above).
          vim.schedule(function()
            local sc_ok, sc = pcall(require, "schema-companion")
            if not sc_ok then return end
            ${lib.concatStringsSep "\n          " (lib.mapAttrsToList renderAdapter cfg.adapters)}
          end)
        ''}
      '';
    };
}
