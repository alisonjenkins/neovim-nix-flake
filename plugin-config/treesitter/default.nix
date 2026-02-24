{ pkgs, ... }:
let
  # Override Python grammar with newer version that supports except* (PEP 654)
  # TODO: Remove this override once nixpkgs updates to tree-sitter-python v0.26.0+
  pythonGrammar = pkgs.tree-sitter.buildGrammar {
    language = "python";
    version = "0.25.0-unstable-2025-09-15";
    src = pkgs.fetchFromGitHub {
      owner = "tree-sitter";
      repo = "tree-sitter-python";
      # Commit after v0.25.0 that includes except* support
      rev = "26855eabccb19c6abf499fbc5b8dc7cc9ab8bc64";
      hash = "sha256-gHeja/X/Ux8fa5rh0b69/bcUcmHBcXsK5uJ1ibtuI20=";
    };
  };

  # Get base grammar list, excluding python
  baseGrammars = if pkgs.stdenv.isLinux
    then pkgs.vimPlugins.nvim-treesitter.passthru.allGrammars
    else with pkgs.vimPlugins.nvim-treesitter.builtGrammars; [
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
        # python - using custom override (see pythonGrammar above)
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
in
{
  treesitter =
    {
      enable = true;

      # Always append custom Python grammar to override the default
      grammarPackages = if pkgs.stdenv.isLinux
        then baseGrammars ++ [ pythonGrammar ]
        else baseGrammars ++ [ pythonGrammar ];

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
