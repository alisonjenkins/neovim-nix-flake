{ lib, config, pkgs, ... }:
let
  cfg = config.plugins.yeet;
  boolToLua = b: if b then "true" else "false";
  nullOrStr = v: if v == null then "nil" else ''"${v}"'';
in
{
  options.plugins.yeet = {
    enable = lib.mkEnableOption "yeet.nvim - run commands in terminal buffers or tmux panes";

    settings = {
      yeetAndRun = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Send <CR> to channel after command for immediate execution.";
      };
      clearBeforeYeet = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Send 'clear<CR>' to channel before executing command.";
      };
      interruptBeforeYeet = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Send Ctrl-C to channel before executing command.";
      };
      retryLastTargetOnFailure = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Reuse last target if the previously selected target is unavailable.";
      };
      hideTermBuffers = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Hide Neovim terminal buffers from target selection.";
      };
      useCacheFile = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Open cache file instead of in-memory prompt when listing commands.";
      };
      shell = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Custom shell for spawning targets (null uses system default).";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    extraPlugins = [
      (pkgs.vimUtils.buildVimPlugin {
        pname = "yeet-nvim";
        version = "unstable-2025-01-01";
        src = pkgs.fetchFromGitHub {
          owner = "samharju";
          repo = "yeet.nvim";
          rev = "5e626267e15938777a628c715e1770f84f213f52";
          hash = "sha256-PsMTunKvcM4Jrt4mjIdPdNRgnnkP9YSXL7qA+rVsaIA=";
        };
      })
    ];

    extraConfigLua = ''
      require('yeet').setup({
        yeet_and_run = ${boolToLua cfg.settings.yeetAndRun},
        clear_before_yeet = ${boolToLua cfg.settings.clearBeforeYeet},
        interrupt_before_yeet = ${boolToLua cfg.settings.interruptBeforeYeet},
        retry_last_target_on_failure = ${boolToLua cfg.settings.retryLastTargetOnFailure},
        hide_term_buffers = ${boolToLua cfg.settings.hideTermBuffers},
        use_cache_file = ${boolToLua cfg.settings.useCacheFile},
        shell = ${nullOrStr cfg.settings.shell},
      })
    '';
  };
}
