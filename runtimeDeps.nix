{ pkgs }:
{
  deps1 = with pkgs; [
    nodePackages.typescript
    nodePackages.typescript-language-server
  ];
  deps2 = with pkgs; [
    lazygit
  ];
}
