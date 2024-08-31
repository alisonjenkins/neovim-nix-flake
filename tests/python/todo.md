# Python Example Todo
* Build a Lambda function as a container.
    * Create custom Python runtime layer using Nix.
        * Reference materials:
            * https://medium.com/@avijitsarkar123/aws-lambda-custom-runtime-really-works-how-i-developed-a-lambda-in-perl-9a481a7ab465
            * https://github.com/aws/aws-lambda-runtime-interface-emulator
            * https://github.com/NixOS/nixpkgs/blob/a0d6390cb3e82062a35d0288979c45756e481f60/pkgs/tools/admin/aws-lambda-runtime-interface-emulator/default.nix#L20
            * https://docs.aws.amazon.com/lambda/latest/dg/images-create.html

* Create justfile demonstrating the commands for running, checking and building.
    * Add justfile targets to:
        * Build container
        * Load container into docker daemon
        * Run dive against the container.

* Ensure that Nvim DAP works.
* Ensure that Neotest works.
* Create test that tests the lambda using SAM local
