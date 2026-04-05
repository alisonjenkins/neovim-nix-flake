local M = {}

-- Provider mapping: resource prefix -> registry namespace/name
-- The prefix is extracted via rtype:match("^([^_]+)_"), so keys here
-- must match that extraction (e.g. "local" not "local_").
M.provider_map = {
  archive = "hashicorp/archive",
  aws = "hashicorp/aws",
  azuread = "hashicorp/azuread",
  azurerm = "hashicorp/azurerm",
  cloudflare = "cloudflare/cloudflare",
  consul = "hashicorp/consul",
  datadog = "DataDog/datadog",
  digitalocean = "digitalocean/digitalocean",
  dns = "hashicorp/dns",
  external = "hashicorp/external",
  github = "integrations/github",
  gitlab = "gitlabhq/gitlab",
  google = "hashicorp/google",
  hcloud = "hetznercloud/hcloud",
  helm = "hashicorp/helm",
  http = "hashicorp/http",
  kubernetes = "hashicorp/kubernetes",
  linode = "linode/linode",
  ["local"] = "hashicorp/local",
  nomad = "hashicorp/nomad",
  null = "hashicorp/null",
  oci = "oracle/oci",
  random = "hashicorp/random",
  template = "hashicorp/template",
  tls = "hashicorp/tls",
  vault = "hashicorp/vault",
  vsphere = "hashicorp/vsphere",
}

-- GitHub repo mapping: provider namespace/name -> GitHub org/repo
-- Only needed for providers whose GitHub repo name doesn't follow
-- the standard "terraform-provider-<name>" convention.
M.github_repo_map = {
  ["integrations/github"] = "integrations/terraform-provider-github",
  ["gitlabhq/gitlab"] = "gitlabhq/terraform-provider-gitlab",
  ["DataDog/datadog"] = "DataDog/terraform-provider-datadog",
}

--- Parse a line of HCL for a terraform resource, data source, or module block
--- @param line string A line of HCL code
--- @return string|nil kind "resource", "data", "module", or nil
--- @return string|nil rtype The resource type (e.g. "aws_instance") or module name
function M.parse_line(line)
  local kind, rtype = line:match('^%s*(resource)%s+"([^"]+)"')
  if not kind then
    kind, rtype = line:match('^%s*(data)%s+"([^"]+)"')
  end
  if not kind then
    kind, rtype = line:match('^%s*(module)%s+"([^"]+)"')
  end
  return kind, rtype
end

--- Parse an attribute or block name from an HCL line
--- Handles: `attr = value` (attribute), `attr {` (block)
--- Supports both indented and unindented lines.
--- @param line string A line of HCL code
--- @return string|nil name The attribute or block name
--- @return string|nil kind "attribute" or "block"
function M.parse_attribute(line)
  -- Skip lines that are resource/data declarations
  if M.parse_line(line) then return nil, nil end
  -- Match block opening: `ebs_block_device {` or `  ebs_block_device {`
  local block = line:match('^%s*([a-z][a-z0-9_]*)%s*{')
  if block then return block, "block" end
  -- Match attribute assignment: `ami = "abc"` or `  ami   =   "abc"`
  local attr = line:match('^%s*([a-z][a-z0-9_]*)%s*=')
  if attr then return attr, "attribute" end
  return nil, nil
end

--- Convert a string to a Terraform Registry anchor slug
--- Matches the `slugify` npm package with `{ lower: true }` used by
--- hashicorp/dev-portal: lowercase, spaces to hyphens, strip backticks
--- and non-word characters, but preserve underscores.
--- @param s string The string to slugify
--- @return string slug The anchor slug
function M.slugify(s)
  s = s:lower()
  s = s:gsub("`", "")
  s = s:gsub("%s+", "-")
  s = s:gsub("[^%w%-_]", "")
  s = s:gsub("%-+", "-")
  s = s:gsub("^%-+", "")
  s = s:gsub("%-+$", "")
  return s
end

--- Generate a slug matching @hashicorp/remark-plugins generate_slug.js
--- Uses \W+ -> "-" (non-word chars to hyphens), which preserves underscores.
--- Tracks duplicates via the links array and appends -1, -2, etc.
--- @param text string The text to slugify
--- @param links table Array of previously generated slugs (modified in place)
--- @return string slug The unique slug
function M.generate_slug(text, links)
  local slug = text:lower():match("^%s*(.-)%s*$") -- trim
  slug = slug:gsub("</?[^>]*>", "")       -- strip HTML tags
  slug = slug:gsub("%(%(%#.-%)?%)?", "")  -- strip anchor link aliases ((#...))
  slug = slug:gsub("[^%w_]+", "-")        -- non-word chars to "-" (preserving underscores)
  slug = slug:gsub("%-+", "-")            -- collapse "-"
  slug = slug:gsub("^%-", "")             -- remove leading "-"
  slug = slug:gsub("%-$", "")             -- remove trailing "-"

  -- Count duplicates
  local dupe_count = 0
  for _, existing in ipairs(links) do
    if existing == slug then
      dupe_count = dupe_count + 1
    end
  end
  table.insert(links, slug)

  if dupe_count > 0 then
    slug = slug .. "-" .. dupe_count
  end

  return slug
end

--- Find the correct anchor for a given attribute name in registry documentation.
--- Supports both Terraform and OpenTofu registries which use different anchor
--- generation algorithms.
---
--- Terraform registry (showdown + anchor-links-list extension):
---   Headings get slugified IDs via ghCompatibleHeaderId (dedup: bare, -1, -2).
---   List items with `code` get anchors as raw_text-N where N starts at 1,
---   tracked by an independent counter from headings.
---
--- OpenTofu registry (rehype-slug / github-slugger):
---   Only headings get anchors (dedup: bare, -1, -2). No list item anchors.
---   Falls back to the section heading (e.g. #argument-reference).
---
--- @param markdown string The raw markdown content
--- @param target_attr string The attribute name to find
--- @param registry string|nil "terraform" or "opentofu" (defaults to "terraform")
--- @return string|nil anchor The anchor slug, or nil if not found
function M.find_anchor_in_markdown(markdown, target_attr, registry)
  registry = registry or "terraform"

  if registry == "opentofu" then
    -- OpenTofu has no list item anchors; find the section heading the
    -- attribute lives under and return that heading's slug.
    local links = {}
    local current_section = nil

    for line in markdown:gmatch("[^\n]+") do
      local heading_text = line:match("^#+%s+(.+)")
      if heading_text then
        local slug = M.generate_slug(heading_text, links)
        local lower = heading_text:lower()
        if lower:match("argument reference") or lower:match("attribute reference") then
          current_section = slug
        end
      else
        local code_value = line:match("^%s*[%*%-]%s+`([^`]+)`")
        if code_value and code_value == target_attr and current_section then
          return current_section
        end
      end
    end

    return nil
  end

  -- Terraform registry: list items get their own anchors via anchor-links-list
  -- extension. The counter is independent from headings and always starts at 1.
  local list_counts = {}

  for line in markdown:gmatch("[^\n]+") do
    -- Skip headings (they have their own separate counter we don't need)
    if not line:match("^#+%s+") then
      local code_value = line:match("^%s*[%*%-]%s+`([^`]+)`")
      if code_value then
        list_counts[code_value] = (list_counts[code_value] or 0) + 1
        if code_value == target_attr then
          return code_value .. "-" .. list_counts[code_value]
        end
      end
    end
  end

  return nil
end

--- Registry definitions
--- @type table<string, { base: string, providers_path: string, data_sources_path: string }>
M.registries = {
  terraform = {
    base = "https://registry.terraform.io",
    providers_path = "providers",
    data_sources_path = "data-sources",
    modules_path = "modules",
  },
  opentofu = {
    base = "https://search.opentofu.org",
    providers_path = "provider",
    data_sources_path = "datasources",
    modules_path = "module",
  },
}

--- Active registry name ("terraform" or "opentofu")
M.active_registry = "terraform"

--- Build a registry URL for a terraform resource type
--- @param provider string Provider namespace/name (e.g. "hashicorp/aws")
--- @param doc_type string "resources" or "data-sources"
--- @param resource_name string Resource name without provider prefix (e.g. "instance")
--- @param registry string|nil Registry name ("terraform" or "opentofu"), defaults to active
--- @return string url The full registry URL
function M.build_doc_url(provider, doc_type, resource_name, registry)
  local reg = M.registries[registry or M.active_registry] or M.registries.terraform
  local path_type = doc_type
  if doc_type == "data-sources" then
    path_type = reg.data_sources_path
  end
  return string.format(
    "%s/%s/%s/latest/docs/%s/%s",
    reg.base, reg.providers_path, provider, path_type, resource_name
  )
end

--- Build a registry URL for a terraform module
--- @param source string Module source (e.g. "terraform-module/github-oidc-provider/aws")
--- @param registry string|nil Registry name ("terraform" or "opentofu"), defaults to active
--- @return string url The full registry URL
function M.build_module_url(source, registry)
  local reg = M.registries[registry or M.active_registry] or M.registries.terraform
  return string.format("%s/%s/%s/latest", reg.base, reg.modules_path, source)
end

--- Check whether a module source string refers to a public registry module.
--- Registry sources have the form "namespace/name/provider" (exactly 3 parts,
--- no path prefixes or scheme).
--- @param source string The source value from a module block
--- @return boolean
function M.is_registry_module(source)
  if not source then return false end
  -- Exclude paths, git URLs, s3, gcs, etc.
  if source:match("^%.") or source:match("^/") then return false end
  if source:match("^%w+::") then return false end
  if source:match("^https?://") then return false end
  -- Exclude known Git hosting shorthand (github.com/..., bitbucket.org/..., etc.)
  for host in pairs(M.git_hosts) do
    if source:match("^" .. host:gsub("%.", "%%.") .. "/") then return false end
  end
  -- Registry modules have exactly 3 slash-separated parts
  local parts = 0
  for _ in source:gmatch("[^/]+") do parts = parts + 1 end
  return parts == 3
end

--- Search within a module block for the source attribute value.
--- Scans lines between the module declaration and its closing brace.
--- @param bufnr number Buffer number
--- @param module_line number 0-indexed line of the module declaration
--- @return string|nil source The source value, or nil
function M.find_module_source(bufnr, module_line)
  local total = vim.api.nvim_buf_line_count(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, module_line, total, false)
  local depth = 0
  for _, l in ipairs(lines) do
    for _ in l:gmatch("{") do depth = depth + 1 end
    for _ in l:gmatch("}") do depth = depth - 1 end
    local src = l:match('^%s*source%s*=%s*"([^"]+)"')
    if src then return src end
    if depth <= 0 then break end
  end
  return nil
end

--- Known Git hosting services and their tree-browse path segments.
--- @type table<string, string>
M.git_hosts = {
  ["github.com"] = "tree",
  ["gitlab.com"] = "-/tree",
  ["bitbucket.org"] = "src",
}

--- Parse common Terraform module source components: base path, ref, and subdir.
--- Handles `?ref=...` query params and `//subdir` notation.
--- @param raw string The source string (after any scheme prefix is stripped)
--- @return string base The path without ref or subdir
--- @return string|nil ref The ref value, or nil
--- @return string|nil subdir The subdirectory, or nil
local function parse_source_parts(raw)
  local ref = nil
  local subdir = nil

  -- Extract ?ref=...
  local without_ref, r = raw:match("^(.-)%?ref=(.+)$")
  if without_ref then
    ref = r
    raw = without_ref
  end

  -- Extract //subdir — find "//" that is NOT part of "://" in URL schemes
  local search_start = 1
  local scheme_end = raw:find("://")
  if scheme_end then
    search_start = scheme_end + 3
  end
  local dslash_pos = raw:find("//", search_start, true)
  if dslash_pos then
    subdir = raw:sub(dslash_pos + 2)
    raw = raw:sub(1, dslash_pos - 1)
  end

  return raw, ref, subdir
end

--- Build a browsable URL from a base URL, optional ref, and optional subdir
--- using the tree-browse path for the given host.
--- @param base_url string The base HTTPS URL (e.g. "https://github.com/org/repo")
--- @param ref string|nil Git ref (branch/tag/sha)
--- @param subdir string|nil Subdirectory path
--- @param tree_segment string The host's tree-browse path (e.g. "tree", "src")
--- @return string url The browsable URL
local function build_tree_url(base_url, ref, subdir, tree_segment)
  if ref and subdir then
    return base_url .. "/" .. tree_segment .. "/" .. ref .. "/" .. subdir
  elseif ref then
    return base_url .. "/" .. tree_segment .. "/" .. ref
  elseif subdir then
    return base_url .. "/" .. tree_segment .. "/HEAD/" .. subdir
  end
  return base_url
end

--- Resolve a non-registry module source to a browsable HTTPS URL.
--- Handles GitHub/Bitbucket shorthand, git:: prefixed URLs, and HTTPS archives.
--- Returns nil for non-browsable sources (SSH, S3, GCS, local paths).
--- @param source string The module source value
--- @return string|nil url A browsable URL, or nil
function M.resolve_module_browse_url(source)
  if not source or source == "" then return nil end
  if M.is_registry_module(source) then return nil end

  -- Local paths
  if source:match("^%.") or source:match("^/") then return nil end

  -- S3/GCS (private)
  if source:match("^s3::") or source:match("^gcs::") then return nil end

  -- GitHub/Bitbucket/GitLab shorthand: "github.com/org/repo..."
  for host, tree_seg in pairs(M.git_hosts) do
    if source:match("^" .. host:gsub("%.", "%%.") .. "/") then
      local path = source:sub(#host + 2) -- strip "github.com/"
      local base, ref, subdir = parse_source_parts(path)
      local base_url = "https://" .. host .. "/" .. base
      return build_tree_url(base_url, ref, subdir, tree_seg)
    end
  end

  -- git:: prefixed URLs
  if source:match("^git::") then
    local inner = source:sub(6) -- strip "git::"
    -- SSH URLs are not browsable
    if inner:match("^ssh://") or inner:match("git@") then return nil end
    -- Strip .git suffix before parsing
    inner = inner:gsub("%.git$", ""):gsub("%.git%?", "?")
    local base, ref, subdir = parse_source_parts(inner)
    -- Determine tree segment from host
    local host = base:match("^https?://([^/]+)")
    local tree_seg = host and M.git_hosts[host] or "tree"
    return build_tree_url(base, ref, subdir, tree_seg)
  end

  -- HTTPS/HTTP URLs
  if source:match("^https?://") then
    local host = source:match("^https?://([^/]+)")
    if host and M.git_hosts[host] then
      -- Known host: extract org/repo from path
      local org, repo = source:match("^https?://[^/]+/([^/]+)/([^/]+)")
      if org and repo then
        return "https://" .. host .. "/" .. org .. "/" .. repo
      end
    end
    -- Archive URL on unknown host: strip filename if it ends with a known extension
    if source:match("%.[Zz][Ii][Pp]$")
      or source:match("%.tar%.gz$")
      or source:match("%.tar%.bz2$")
      or source:match("%.tgz$") then
      local parent = source:match("^(https?://.+/)")
      return parent
    end
    -- Non-archive HTTPS URL (e.g. self-hosted Git): return as-is
    return source
  end

  return nil
end

--- Build the GitHub raw content URL for a provider doc
--- @param provider string Provider namespace/name (e.g. "hashicorp/aws")
--- @param doc_type string "resources" or "data-sources"
--- @param resource_name string Resource name without provider prefix
--- @return string url The raw GitHub URL
function M.build_github_doc_url(provider, doc_type, resource_name)
  local github_repo = M.github_repo_map[provider]
  if not github_repo then
    local ns, name = provider:match("([^/]+)/([^/]+)")
    if ns and name then
      github_repo = ns .. "/terraform-provider-" .. name
    else
      github_repo = "hashicorp/terraform-provider-" .. provider
    end
  end
  -- Resources use "r/", data sources use "d/"
  local doc_prefix = (doc_type == "data-sources") and "d" or "r"
  return string.format(
    "https://raw.githubusercontent.com/%s/main/website/docs/%s/%s.html.markdown",
    github_repo, doc_prefix, resource_name
  )
end

--- Build the Terraform Registry API URL to fetch doc content
--- @param provider string Provider namespace/name (e.g. "hashicorp/aws")
--- @param doc_type string "resources" or "data-sources"
--- @param resource_name string Resource name without provider prefix
--- @return string url The registry API URL
function M.build_registry_api_url(provider, doc_type, resource_name)
  local ns, name = provider:match("([^/]+)/([^/]+)")
  if not ns then return "" end
  local category = (doc_type == "data-sources") and "data-sources" or "resources"
  return string.format(
    "https://registry.terraform.io/v2/provider-docs"
      .. "?filter%%5Bprovider-name%%5D=%s"
      .. "&filter%%5Bprovider-namespace%%5D=%s"
      .. "&filter%%5Bcategory%%5D=%s"
      .. "&filter%%5Bslug%%5D=%s"
      .. "&page%%5Bsize%%5D=1",
    name, ns, category, resource_name
  )
end

--- Fetch markdown content for a provider doc, trying the registry API first,
--- then falling back to GitHub raw content.
--- @param provider string Provider namespace/name
--- @param doc_type string "resources" or "data-sources"
--- @param resource_name string Resource name without provider prefix
--- @param callback function Called with (markdown_string) or (nil) on failure
function M.fetch_doc_markdown(provider, doc_type, resource_name, callback)
  local api_url = M.build_registry_api_url(provider, doc_type, resource_name)

  vim.system(
    { "curl", "-sL", "--max-time", "10", api_url },
    {},
    vim.schedule_wrap(function(result)
      -- Try to parse JSON response from registry API
      if result.code == 0 and result.stdout and result.stdout ~= "" then
        local ok, data = pcall(vim.json.decode, result.stdout)
        if ok and data and data.data and data.data[1] then
          local content = data.data[1].attributes and data.data[1].attributes.content
          if content and content ~= "" then
            callback(content)
            return
          end
        end
      end

      -- Fall back to GitHub raw content
      local github_url = M.build_github_doc_url(provider, doc_type, resource_name)
      vim.system(
        { "curl", "-sL", "--max-time", "10", github_url },
        {},
        vim.schedule_wrap(function(gh_result)
          if gh_result.code == 0 and gh_result.stdout and gh_result.stdout ~= "" then
            callback(gh_result.stdout)
          else
            callback(nil)
          end
        end)
      )
    end)
  )
end

--- Resolve a full resource type string to a documentation URL (without anchor)
--- @param rtype string The full resource type (e.g. "aws_instance")
--- @param kind string|nil "resource", "data", or nil (defaults to "resources")
--- @param attribute string|nil Unused, kept for API compat
--- @param registry string|nil Registry name ("terraform" or "opentofu"), defaults to active
--- @return string|nil url The registry URL, or nil if the type cannot be parsed
--- @return string|nil err Error message if the type cannot be parsed
function M.resolve_doc_url(rtype, kind, attribute, registry)
  if not rtype then
    return nil, "No resource type provided"
  end

  local prefix = rtype:match("^([^_]+)_")
  if not prefix then
    return nil, "Cannot determine provider from: " .. rtype
  end

  local provider = M.provider_map[prefix] or ("hashicorp/" .. prefix)
  local resource_name = rtype:sub(#prefix + 2)
  local doc_type = (kind == "data") and "data-sources" or "resources"

  return M.build_doc_url(provider, doc_type, resource_name, registry), nil
end

--- Search buffer lines upward from a given line number to find the enclosing
--- resource or data block declaration.
--- @param bufnr number Buffer number
--- @param start_line number 0-indexed line to start searching from
--- @return string|nil kind "resource", "data", or nil
--- @return string|nil rtype The resource type
function M.find_enclosing_block(bufnr, start_line)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, start_line + 1, false)
  for i = #lines, 1, -1 do
    local kind, rtype = M.parse_line(lines[i])
    if kind then return kind, rtype end
  end
  return nil, nil
end

--- Search buffer lines upward from a given line number to find the enclosing
--- attribute assignment at the resource block level. Handles multiline values
--- (maps, lists) by tracking brace/bracket nesting depth.
--- @param bufnr number Buffer number
--- @param start_line number 0-indexed line to start searching from
--- @return string|nil attr The attribute name, or nil
function M.find_enclosing_attribute(bufnr, start_line)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, start_line + 1, false)
  local depth = 0
  local was_nested = false

  for i = #lines, 1, -1 do
    local l = lines[i]

    -- Stop if we hit a resource/data/module declaration (we've left the block)
    if M.parse_line(l) then return nil end

    -- Count closing delimiters on this line (going upward, these increase depth)
    for _ in l:gmatch("}") do depth = depth + 1 end
    for _ in l:gmatch("]") do depth = depth + 1 end

    if depth > 0 then was_nested = true end

    -- Count opening delimiters on this line (going upward, these decrease depth)
    for _ in l:gmatch("{") do depth = depth - 1 end
    for _ in l:gmatch("%[") do depth = depth - 1 end

    -- Match when we've exited nesting: either depth went negative (cursor was
    -- inside the value) or depth returned to 0 after being positive (cursor was
    -- on a closing delimiter like } or ]).
    if depth < 0 or (depth <= 0 and was_nested) then
      local attr = M.parse_attribute(l)
      if attr then return attr end
    end
  end

  return nil
end

--- Open registry docs for the resource or module under cursor.
--- If the cursor is on an attribute line inside a resource/data block, fetches
--- doc markdown (registry API first, GitHub raw content fallback) to compute the
--- correct anchor, then opens the URL.
--- If on a resource/data/module declaration line, opens the docs directly.
--- @param registry string|nil Registry name ("terraform" or "opentofu"), defaults to active
function M.open_docs(registry)
  local line = vim.api.nvim_get_current_line()
  local kind, rtype = M.parse_line(line)
  local attribute = nil

  if kind then
    attribute = nil
  else
    attribute = M.parse_attribute(line)
    local bufnr = vim.api.nvim_get_current_buf()
    local cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1
    kind, rtype = M.find_enclosing_block(bufnr, cursor_line)

    -- If parse_attribute returned nil (e.g. inside a multiline map/list value)
    -- or returned an inner key (not a resource-level attribute), search upward
    -- through nesting to find the enclosing resource-level attribute.
    if not attribute then
      attribute = M.find_enclosing_attribute(bufnr, cursor_line)
    end
  end

  -- Handle module blocks: find source and open module docs
  if kind == "module" then
    local bufnr = vim.api.nvim_get_current_buf()
    -- Find the module declaration line to scan for source
    local cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, cursor_line + 1, false)
    local module_line = nil
    for i = #lines, 1, -1 do
      local k = M.parse_line(lines[i])
      if k == "module" then
        module_line = i - 1 -- 0-indexed
        break
      end
    end

    if not module_line then
      vim.notify("Could not find module declaration", vim.log.levels.WARN)
      return
    end

    local source = M.find_module_source(bufnr, module_line)
    if not source then
      vim.notify("Could not find module source", vim.log.levels.WARN)
      return
    end

    -- Non-registry modules: resolve to a browsable URL directly
    if not M.is_registry_module(source) then
      local browse_url = M.resolve_module_browse_url(source)
      if browse_url then
        vim.ui.open(browse_url)
      else
        vim.notify("Cannot browse module source: " .. source, vim.log.levels.WARN)
      end
      return
    end

    local base_url = M.build_module_url(source, registry)

    -- For Terraform registry, module inputs use #input_{name} anchors
    if attribute and attribute ~= "source" and attribute ~= "version" then
      local reg_name = registry or M.active_registry
      if reg_name == "terraform" then
        vim.ui.open(base_url .. "#input_" .. attribute)
      else
        vim.ui.open(base_url .. "#inputs")
      end
    else
      vim.ui.open(base_url)
    end
    return
  end

  if not rtype then
    rtype = vim.fn.expand("<cWORD>"):match("[%w_]+")
    kind = nil
    attribute = nil
  end

  if not rtype then
    vim.notify("No terraform resource found", vim.log.levels.WARN)
    return
  end

  local prefix = rtype:match("^([^_]+)_")
  if not prefix then
    vim.notify("Cannot determine provider from: " .. rtype, vim.log.levels.WARN)
    return
  end

  local provider = M.provider_map[prefix] or ("hashicorp/" .. prefix)
  local resource_name = rtype:sub(#prefix + 2)
  local doc_type = (kind == "data") and "data-sources" or "resources"
  local base_url = M.build_doc_url(provider, doc_type, resource_name, registry)

  if not attribute then
    vim.ui.open(base_url)
    return
  end

  -- Fetch doc markdown (registry API first, GitHub fallback) to compute anchor
  vim.notify("Looking up docs anchor...", vim.log.levels.INFO)

  M.fetch_doc_markdown(provider, doc_type, resource_name, function(markdown)
    if not markdown then
      vim.notify("Could not fetch docs, opening without anchor", vim.log.levels.WARN)
      vim.ui.open(base_url)
      return
    end

    local anchor = M.find_anchor_in_markdown(markdown, attribute, registry)
    if anchor then
      vim.ui.open(base_url .. "#" .. anchor)
    else
      vim.notify(
        "Anchor not found for '" .. attribute .. "', opening docs page",
        vim.log.levels.INFO
      )
      vim.ui.open(base_url)
    end
  end)
end

--- Extract namespace and provider name from a provider schema key
--- Handles both terraform and opentofu registry domains.
--- @param provider_key string e.g. "registry.terraform.io/hashicorp/aws"
--- @return string|nil ns The namespace (e.g. "hashicorp")
--- @return string|nil name The provider name (e.g. "aws")
function M.parse_provider_key(provider_key)
  local ns, name = provider_key:match("registry%.[^/]+/([^/]+)/([^/]+)")
  return ns, name
end

--- Strip the provider prefix from a full resource type to get the doc slug
--- @param full_name string e.g. "aws_instance" or "google_compute_instance"
--- @return string resource_slug e.g. "instance" or "compute_instance"
function M.strip_provider_prefix(full_name)
  return full_name:match("^[^_]+_(.+)") or full_name
end

--- Open a Snacks picker to browse terraform provider docs
--- @param registry string|nil Registry name ("terraform" or "opentofu"), defaults to active
function M.docs_picker(registry)
  local snacks_ok, snacks = pcall(require, "snacks")
  if not snacks_ok then
    vim.notify("Snacks not available", vim.log.levels.ERROR)
    return
  end

  local cwd = vim.fn.getcwd()
  local has_terraform = vim.fn.executable("terraform") == 1
  local has_tofu = vim.fn.executable("tofu") == 1
  local prefer_tofu = (registry or M.active_registry) == "opentofu"
  local schema_cmd
  if prefer_tofu then
    schema_cmd = (has_tofu and "tofu") or (has_terraform and "terraform") or nil
  else
    schema_cmd = (has_terraform and "terraform") or (has_tofu and "tofu") or nil
  end
  if not schema_cmd then
    vim.notify("Neither terraform nor tofu found in PATH", vim.log.levels.ERROR)
    return
  end
  vim.notify("Loading provider schemas...", vim.log.levels.INFO)

  vim.system(
    { schema_cmd, "providers", "schema", "-json" },
    { cwd = cwd },
    vim.schedule_wrap(function(result)
      if result.code ~= 0 then
        vim.notify(
          "Failed to load schemas. Run " .. schema_cmd .. " init first.",
          vim.log.levels.WARN
        )
        return
      end

      local ok, schemas = pcall(vim.json.decode, result.stdout)
      if not ok or not schemas or not schemas.provider_schemas then
        vim.notify("Failed to parse provider schemas", vim.log.levels.ERROR)
        return
      end

      local items = {}
      for provider_key, provider_data in pairs(schemas.provider_schemas) do
        local ns, name = M.parse_provider_key(provider_key)
        if not ns then
          goto continue
        end

        local provider_id = ns .. "/" .. name

        if provider_data.resource_schemas then
          for resource_name, _ in pairs(provider_data.resource_schemas) do
            table.insert(items, {
              text = resource_name,
              label = "resource",
              provider = provider_id,
              doc_type = "resources",
              resource = M.strip_provider_prefix(resource_name),
            })
          end
        end

        if provider_data.data_source_schemas then
          for ds_name, _ in pairs(provider_data.data_source_schemas) do
            table.insert(items, {
              text = ds_name,
              label = "data",
              provider = provider_id,
              doc_type = "data-sources",
              resource = M.strip_provider_prefix(ds_name),
            })
          end
        end

        ::continue::
      end

      table.sort(items, function(a, b) return a.text < b.text end)

      local picker_title = (registry or M.active_registry) == "opentofu"
        and "OpenTofu Docs" or "Terraform Docs"

      snacks.picker({
        title = picker_title,
        items = items,
        format = function(item)
          return {
            { "[" .. item.label .. "] ", item.label == "data" and "Type" or "Function" },
            { item.text },
          }
        end,
        confirm = function(picker, item)
          picker:close()
          if item then
            vim.ui.open(M.build_doc_url(item.provider, item.doc_type, item.resource, registry))
          end
        end,
      })
    end)
  )
end

--- Register user commands
function M.setup()
  vim.api.nvim_create_user_command("TerraformDoc", function()
    M.open_docs("terraform")
  end, {})
  vim.api.nvim_create_user_command("TofuDoc", function()
    M.open_docs("opentofu")
  end, {})
  vim.api.nvim_create_user_command("TerraformDocPicker", function()
    M.docs_picker("terraform")
  end, {})
  vim.api.nvim_create_user_command("TofuDocPicker", function()
    M.docs_picker("opentofu")
  end, {})

  -- Disable trivy diagnostics by default (registered but inactive).
  -- Users can toggle on with <leader>.T when needed.
  vim.schedule(function()
    local ok, null_ls = pcall(require, "null-ls")
    if ok then
      null_ls.disable({ name = "trivy" })
    end
  end)
end

return M
