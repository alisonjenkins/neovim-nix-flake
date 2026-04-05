{ pkgs, ... }:
let
  bg = pkgs.vimPlugins.nvim-treesitter.passthru.builtGrammars;
  # Pin grammars to versions matching nvim-treesitter queries (from upstream lockfile)
  grammarOverrides = {
    php = bg.php.overrideAttrs { src = pkgs.fetchFromGitHub { owner = "tree-sitter"; repo = "tree-sitter-php"; rev = "576a56fa7f8b68c91524cdd211eb2ffc43e7bb11"; hash = "sha256-kTiqj4KWHTZVJ6R6axubNGdcTNA+W02RTsBcoeR2xGU="; }; location = "php"; };
    php_only = bg.php.overrideAttrs { pname = "tree-sitter-php_only"; src = pkgs.fetchFromGitHub { owner = "tree-sitter"; repo = "tree-sitter-php"; rev = "576a56fa7f8b68c91524cdd211eb2ffc43e7bb11"; hash = "sha256-kTiqj4KWHTZVJ6R6axubNGdcTNA+W02RTsBcoeR2xGU="; }; location = "php_only"; };
    nu = bg.nu.overrideAttrs { src = pkgs.fetchFromGitHub { owner = "nushell"; repo = "tree-sitter-nu"; rev = "d5c71a10b4d1b02e38967b05f8de70e847448dd1"; hash = "sha256-7Ny3wXa5iE6s7szqTkPqaXWL/NL5yA2MbhdQHylxwE0="; }; };
    powershell = bg.powershell.overrideAttrs { src = pkgs.fetchFromGitHub { owner = "airbus-cert"; repo = "tree-sitter-powershell"; rev = "66d5e61126989c0aca57ff77d19b2064919b51e1"; hash = "sha256-M2vOS2UleHpZC8PbUf+PHxjWz4BMBhyVxcuUsuMx34Q="; }; };
    gleam = bg.gleam.overrideAttrs { src = pkgs.fetchFromGitHub { owner = "gleam-lang"; repo = "tree-sitter-gleam"; rev = "99ec4101504452c488b7c835fb65cfef75b090b7"; hash = "sha256-FEecjw1nYYO8U+qLjOK28qTMCO1pJkwdUDzlDvmle4c="; }; };
    gotmpl = bg.gotmpl.overrideAttrs { src = pkgs.fetchFromGitHub { owner = "ngalaiko"; repo = "tree-sitter-go-template"; rev = "5f19a36bb1eebb30454e277b222b278ceafed0dd"; hash = "sha256-apZ5yhWzLxaJFxMcuugNTuCxdDUxhKTZecZFsvjyqdo="; }; };
    blade = bg.blade.overrideAttrs { src = pkgs.fetchFromGitHub { owner = "EmranMR"; repo = "tree-sitter-blade"; rev = "bcdc4b01827cac21205f7453e9be02f906943128"; hash = "sha256-Svco/cweC311fUlKi34sh0AWfP/VYRWJMXyAuUVRhAw="; }; };
    angular = bg.angular.overrideAttrs { src = pkgs.fetchFromGitHub { owner = "dlvandenberg"; repo = "tree-sitter-angular"; rev = "843525141575e397541e119698f0532755e959f6"; hash = "sha256-SPBtbwEMGPrEUCbxSlQl44+hK4Yphngp8QsLkmMsDBk="; }; };
    fortran = bg.fortran.overrideAttrs { src = pkgs.fetchFromGitHub { owner = "stadelmanma"; repo = "tree-sitter-fortran"; rev = "d738334e4a21866a1ab81fb3f27f9b0b2ad2e515"; hash = "sha256-NiGBc8o+WOegHm/2yl5EXAdjpKE+l9Lo5bUvOkCWXqo="; }; };
    desktop = bg.desktop.overrideAttrs { src = pkgs.fetchFromGitHub { owner = "ValdezFOmar"; repo = "tree-sitter-desktop"; rev = "6d66eea37afa1d6bc1e25ef457113743df42416d"; hash = "sha256-vaWcgt4bwO1PCG0BJrp6oSY6DEWfMiuWtOPUwKvzmPg="; }; };
    tmux = bg.tmux.overrideAttrs { src = pkgs.fetchFromGitHub { owner = "Freed-Wu"; repo = "tree-sitter-tmux"; rev = "0252ecd080016e45e6305ef1a943388f5ae2f4b4"; hash = "sha256-8f78qYxqoiOAnl3HzEbF4Rci3rFy0SnELoU+QP7pUlk="; }; };
    chatito = bg.chatito.overrideAttrs { src = pkgs.fetchFromGitHub { owner = "ObserverOfTime"; repo = "tree-sitter-chatito"; rev = "b4cbe9ab7672d5106e9550d8413835395a1be362"; hash = "sha256-te2Eg8J4Zf5H6FKLnCAyyKSjTABESUKzqQWwW/k/Y1c="; }; };
    editorconfig = bg.editorconfig.overrideAttrs { src = pkgs.fetchFromGitHub { owner = "ValdezFOmar"; repo = "tree-sitter-editorconfig"; rev = "3f2b371537355f6e53cc3af37f79ba450efb5132"; hash = "sha256-z5pTG7EbmEZV+5RtXI8jGxxb0ifb67EJXquWQ0IA1a8="; }; };
    gdscript = bg.gdscript.overrideAttrs { src = pkgs.fetchFromGitHub { owner = "PrestonKnopp"; repo = "tree-sitter-gdscript"; rev = "48b49330888a4669b48619b211cc8da573827725"; hash = "sha256-mGmrCK3nGSzi/66mOxvpRyTA9b74aTMSoIISqzj+l90="; }; };
    gdshader = bg.gdshader.overrideAttrs { src = pkgs.fetchFromGitHub { owner = "GodOfAvacyn"; repo = "tree-sitter-gdshader"; rev = "ffd9f958df13cae04593781d7d2562295a872455"; hash = "sha256-JWlDs0w10TqsPYgZvvaJwAueOciCYaws1Nr8rb0UKy4="; }; };
    inko = bg.inko.overrideAttrs { src = pkgs.fetchFromGitHub { owner = "inko-lang"; repo = "tree-sitter-inko"; rev = "f58a87ac4dc6a7955c64c9e4408fbd693e804686"; hash = "sha256-hZdbF9lw7fR5K8UfUaESS7/c4v9u7vEcSylEEbc6//4="; }; };
    julia = bg.julia.overrideAttrs { src = pkgs.fetchFromGitHub { owner = "tree-sitter"; repo = "tree-sitter-julia"; rev = "12a3aede757bc7fbdfb1909507c7a6fddd31df37"; hash = "sha256-527US8LI8ZItb/O0em47+v4HnYnhJd48KBAWpasD62E="; }; };
    kotlin = bg.kotlin.overrideAttrs { src = pkgs.fetchFromGitHub { owner = "fwcd"; repo = "tree-sitter-kotlin"; rev = "c4ddea359a7ff4d92360b2efcd6cfce5dc25afe6"; hash = "sha256-7REd272fpCP/ggzg7wLf5DS6QX9SIO9YGPdvj2c2w58="; }; };
    koto = bg.koto.overrideAttrs { src = pkgs.fetchFromGitHub { owner = "koto-lang"; repo = "tree-sitter-koto"; rev = "46770abba021e2ddd2c51d9fa3087fd1ab6b2aea"; hash = "sha256-BMBwkWVvW4qBX6DqM29Ne17K116yUiH2njdKkzeXmTY="; }; };
    matlab = bg.matlab.overrideAttrs { src = pkgs.fetchFromGitHub { owner = "acristoffers"; repo = "tree-sitter-matlab"; rev = "bbf1b3f0bd7417c1efb8958fe95be3d0d540207a"; hash = "sha256-dFsHOqleUTJCzidlKv/5kpawYhbn0jmOIpPrpJQJj80="; }; };
    nickel = bg.nickel.overrideAttrs { src = pkgs.fetchFromGitHub { owner = "nickel-lang"; repo = "tree-sitter-nickel"; rev = "25464b33522c3f609fa512aa9651707c0b66d48b"; hash = "sha256-dQeUoHQHkPYywYIm3TMnTWPXUlh2xh8M5CVUiXASBu8="; }; };
    purescript = bg.purescript.overrideAttrs { src = pkgs.fetchFromGitHub { owner = "postsolar"; repo = "tree-sitter-purescript"; rev = "daf9b3e2be18b0b2996a1281f7783e0d041d8b80"; hash = "sha256-eY2WF2n0fZUl1zxZZHJVYR8b1FwaAjkCeSeOdSf67m4="; }; };
    robot = bg.robot.overrideAttrs { src = pkgs.fetchFromGitHub { owner = "Hubro"; repo = "tree-sitter-robot"; rev = "17c2300e91fc9da4ba14c16558bf4292941dc074"; hash = "sha256-9f0xFmhEQnETvV2SAZW+jRtsVdl0ZT3CDmGkcd3Fn88="; }; };
    supercollider = bg.supercollider.overrideAttrs { src = pkgs.fetchFromGitHub { owner = "madskjeldgaard"; repo = "tree-sitter-supercollider"; rev = "1a8ee0da9a4f2df5a8a22f4d637ac863623a78a7"; hash = "sha256-G23AZO1zvTvRE9ciV7qMuSoaCYulhyOkwiRwgK06NRQ="; }; };
    t32 = bg.t32.overrideAttrs { src = pkgs.fetchgit { url = "https://gitlab.com/xasc/tree-sitter-t32.git"; rev = "e5a12f798f056049642aa03fbb83786e3a5b95d4"; hash = "sha256-oOykmtAFPQiqK02nia8/m8pg2fi5yKt7dzZOGr9f3dQ="; }; };
    tcl = bg.tcl.overrideAttrs { src = pkgs.fetchFromGitHub { owner = "tree-sitter-grammars"; repo = "tree-sitter-tcl"; rev = "f15e711167661d1ba541d4f62b9dbfc4ce61ec56"; hash = "sha256-173xUAc2/LMDQSTEM3l3R4UuF/R5fdUyhEpXv6Eh02s="; }; };
    typoscript = bg.typoscript.overrideAttrs { src = pkgs.fetchFromGitHub { owner = "Teddytrombone"; repo = "tree-sitter-typoscript"; rev = "5d8fde870b0ded1f429ba5bb249a9d9f8589ff5f"; hash = "sha256-GysGb879dk5e1U6OO26q1gVAhkWxc/GRpkNN785ZoQw="; }; };
    vento = bg.vento.overrideAttrs { src = pkgs.fetchFromGitHub { owner = "ventojs"; repo = "tree-sitter-vento"; rev = "3b32474bc29584ea214e4e84b47102408263fe0e"; hash = "sha256-h8yC+MJIAH7DM69UQ8moJBmcmrSZkxvWrMb+NqtYB2Y="; }; };
    wit = bg.wit.overrideAttrs { src = pkgs.fetchFromGitHub { owner = "liamwh"; repo = "tree-sitter-wit"; rev = "81490b4e74c792369e005f72b0d46fe082d3fed2"; hash = "sha256-L8dIOVJ3L2TXg1l4BXMOQeOsNxVkGPZimG619n3kHZE="; }; };
    ziggy_schema = bg.ziggy_schema.overrideAttrs { src = pkgs.fetchFromGitHub { owner = "kristoff-it"; repo = "ziggy"; rev = "8a29017169f43dc2c3526817e98142eb9a335087"; hash = "sha256-w4qq/SBlRQw3r9iIZ2RY3infa/ysopOQX5QDS7+8kt8="; }; location = "tree-sitter-ziggy-schema"; };
  };
  # Map from pname to override key
  pnameToKey = {
    "tree-sitter-chatito" = "chatito";
    "tree-sitter-editorconfig" = "editorconfig";
    "tree-sitter-gdscript" = "gdscript";
    "tree-sitter-gdshader" = "gdshader";
    "tree-sitter-inko" = "inko";
    "tree-sitter-julia" = "julia";
    "tree-sitter-kotlin" = "kotlin";
    "tree-sitter-koto" = "koto";
    "tree-sitter-matlab" = "matlab";
    "tree-sitter-nickel" = "nickel";
    "tree-sitter-php" = "php";
    "tree-sitter-php_only" = "php_only";
    "tree-sitter-purescript" = "purescript";
    "tree-sitter-robot" = "robot";
    "tree-sitter-supercollider" = "supercollider";
    "tree-sitter-t32" = "t32";
    "tree-sitter-tcl" = "tcl";
    "tree-sitter-typoscript" = "typoscript";
    "tree-sitter-vento" = "vento";
    "tree-sitter-wit" = "wit";
    "tree-sitter-ziggy_schema" = "ziggy_schema";
    "tree-sitter-nu" = "nu";
    "tree-sitter-powershell" = "powershell";
    "tree-sitter-gleam" = "gleam";
    "tree-sitter-gotmpl" = "gotmpl";
    "tree-sitter-blade" = "blade";
    "tree-sitter-angular" = "angular";
    "tree-sitter-fortran" = "fortran";
    "tree-sitter-desktop" = "desktop";
    "tree-sitter-tmux" = "tmux";
  };
  # Replace matching grammars in allGrammars with overridden versions
  patchedGrammars = map (g:
    let key = pnameToKey.${g.pname or ""} or null;
    in if key != null && builtins.hasAttr key grammarOverrides
       then grammarOverrides.${key}
       else g
  ) pkgs.vimPlugins.nvim-treesitter.passthru.allGrammars;
in
{
  treesitter =
    {
      enable = true;

      grammarPackages = if pkgs.stdenv.isLinux then patchedGrammars else with pkgs.vimPlugins.nvim-treesitter.builtGrammars; [
        ada
        agda
        angular
        apex
        arduino
        asm
        astro
        authzed
        awk
        bash
        bass
        beancount
        bibtex
        bicep
        bitbake
        bp
        c
        c_sharp
        caddy
        cairo
        capnp
        chatito
        clojure
        cmake
        comment
        commonlisp
        cooklang
        corn
        cpon
        cpp
        css
        csv
        cuda
        cue
        cylc
        d
        dart
        desktop
        devicetree
        dhall
        diff
        disassembly
        djot
        dockerfile
        dot
        doxygen
        dtd
        earthfile
        ebnf
        editorconfig
        eds
        eex
        elixir
        elm
        elsa
        elvish
        embedded_template
        enforce
        erlang
        facility
        faust
        fennel
        fidl
        firrtl
        fish
        foam
        forth
        fortran
        fsh
        fsharp
        func
        gap
        gaptst
        gdscript
        gdshader
        git_config
        git_rebase
        gitattributes
        gitcommit
        gitignore
        gleam
        glimmer
        glimmer_javascript
        glimmer_typescript
        glsl
        gn
        gnuplot
        go
        goctl
        godot_resource
        gomod
        gosum
        gotmpl
        gowork
        gpg
        graphql
        gren
        groovy
        gstlaunch
        hack
        hare
        haskell
        haskell_persistent
        hcl
        heex
        helm
        hjson
        hlsl
        hlsplaylist
        hocon
        hoon
        html
        htmldjango
        http
        hurl
        hyprlang
        idl
        idris
        ini
        inko
        ispc
        janet_simple
        java
        javadoc
        javascript
        jinja
        jinja_inline
        jq
        jsdoc
        json
        json5
        jsonnet
        julia
        just
        kcl
        kconfig
        kdl
        kotlin
        koto
        kusto
        lalrpop
        latex
        ledger
        leo
        linkerscript
        liquid
        liquidsoap
        llvm
        lua
        luadoc
        luap
        luau
        m68k
        make
        markdown
        markdown_inline
        matlab
        menhir
        mermaid
        meson
        mlir
        muttrc
        nasm
        nginx
        nickel
        nim
        nim_format_string
        ninja
        nix
        nqc
        nu
        objc
        objdump
        ocaml
        ocaml_interface
        ocamllex
        odin
        pascal
        passwd
        pem
        perl
        php
        php_only
        phpdoc
        pioasm
        po
        pod
        poe_filter
        pony
        powershell
        printf
        prisma
        problog
        prolog
        promql
        properties
        proto
        prql
        psv
        pug
        puppet
        purescript
        pymanifest
        python
        ql
        qmldir
        qmljs
        query
        r
        racket
        ralph
        rasi
        razor
        rbs
        re2c
        readline
        regex
        rego
        requirements
        rescript
        rnoweb
        robot
        roc
        ron
        rst
        ruby
        runescript
        rust
        scala
        scfg
        scheme
        scss
        sflog
        slang
        slim
        slint
        smali
        smithy
        snakemake
        solidity
        soql
        sosl
        sourcepawn
        sparql
        sql
        squirrel
        ssh_config
        starlark
        strace
        styled
        supercollider
        superhtml
        surface
        svelte
        sway
        swift
        sxhkdrc
        systemtap
        t32
        tablegen
        tact
        tcl
        teal
        templ
        tera
        terraform
        textproto
        thrift
        tiger
        tlaplus
        tmux
        todotxt
        toml
        tsv
        tsx
        turtle
        twig
        typescript
        typespec
        typoscript
        typst
        udev
        ungrammar
        unison
        usd
        uxntal
        v
        vala
        vento
        vhdl
        vhs
        vim
        vimdoc
        vrl
        vue
        wgsl
        wgsl_bevy
        wing
        wit
        xcompose
        xml
        xresources
        yaml
        yang
        yuck
        zathurarc
        zig
        ziggy
        ziggy_schema
      ];

      settings = {
        # Performance optimizations for treesitter
        incremental_selection = { enable = true; };
        indent = { enable = false; }; # Keep disabled for performance
        textobjects.enable = true;

        highlight = {
          enable = true;

          # Optimize highlighting performance
          disable = ''
            function(lang, bufnr)
              local line_count = vim.api.nvim_buf_line_count(bufnr)
              -- Disable for very large files
              if line_count > 10000 then
                return true
              end
              -- Disable for certain large filetypes that don't need highlighting
              local ft = vim.bo[bufnr].filetype
              if ft == "help" or ft == "man" then
                return true
              end
              return false
            end
          '';

          # Reduce highlighting update frequency for performance
          additional_vim_regex_highlighting = false;
        };

        # Optimize parser loading
        auto_install = false; # Don't auto-install at runtime
        ensure_installed = [ ]; # All grammars are managed by Nix

        # Performance settings
        sync_install = false;
      };
    };
}
