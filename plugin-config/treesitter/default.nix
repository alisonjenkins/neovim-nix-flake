{ pkgs, ... }:
{
  treesitter =
    {
      enable = true;

      grammarPackages = if pkgs.stdenv.isLinux then pkgs.vimPlugins.nvim-treesitter.passthru.allGrammars else with pkgs.vimPlugins.nvim-treesitter.builtGrammars; [
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
        blueprint
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
        fusion
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
        jsonc
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
        robots
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
        indent = { enable = false; };  # Keep disabled for performance
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
        auto_install = false;  # Don't auto-install at runtime
        ensure_installed = []; # All grammars are managed by Nix

        # Performance settings
        sync_install = false;
      };
    };
}
