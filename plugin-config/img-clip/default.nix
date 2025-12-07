{ ... }: {
  img-clip = {
    enable = true;

    settings = {
      default = {
        dir_path = "assets";
        file_name = "%y-%m-%d-%h-%m-%s";
        relative_to_current_file = false;
        template = "$file_path";
        use_absolute_path = false;
      };
      filetypes = {
        markdown = {
          download_images = true;
        };
      };
    };
  };
}
