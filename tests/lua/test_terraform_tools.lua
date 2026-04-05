#!/usr/bin/env lua
-- Tests for terraform-tools.lua parsing and URL generation
-- Runs with plain Lua (no Neovim required) on Linux and macOS

-- Minimal shim: only needed so require("terraform-tools") doesn't error on
-- vim.api / vim.fn references at call sites (those code paths aren't exercised
-- in these tests).
_G.vim = _G.vim or {
  api = {},
  fn = {},
  ui = {},
  notify = function() end,
  log = { levels = { WARN = 2, ERROR = 4, INFO = 1 } },
  pesc = function(s) return (s:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1")) end,
}

-- Adjust package.path so we can require the module under test
local script_dir = arg[0]:match("(.*/)")
if script_dir then
  package.path = script_dir .. "/../../lua/?.lua;" .. package.path
else
  package.path = "lua/?.lua;" .. package.path
end

local tf = require("terraform-tools")

-- Simple test harness
local passed = 0
local failed = 0
local errors = {}

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    io.write("  PASS  " .. name .. "\n")
  else
    failed = failed + 1
    table.insert(errors, { name = name, err = err })
    io.write("  FAIL  " .. name .. "\n")
    io.write("        " .. tostring(err) .. "\n")
  end
end

local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    error(string.format(
      "%s\n  expected: %s\n  actual:   %s",
      msg or "assertion failed", tostring(expected), tostring(actual)
    ))
  end
end

local function assert_nil(actual, msg)
  if actual ~= nil then
    error(string.format(
      "%s\n  expected nil, got: %s",
      msg or "assertion failed", tostring(actual)
    ))
  end
end

local function assert_match(str, pattern, msg)
  if not str or not str:match(pattern) then
    error(string.format(
      "%s\n  expected match for: %s\n  in: %s",
      msg or "assertion failed", pattern, tostring(str)
    ))
  end
end

-- ---------------------------------------------------------------------------
-- parse_line tests
-- ---------------------------------------------------------------------------
io.write("\n== parse_line ==\n")

test("parses resource block", function()
  local kind, rtype = tf.parse_line('resource "aws_instance" "web" {')
  assert_eq(kind, "resource")
  assert_eq(rtype, "aws_instance")
end)

test("parses data block", function()
  local kind, rtype = tf.parse_line('data "aws_ami" "ubuntu" {')
  assert_eq(kind, "data")
  assert_eq(rtype, "aws_ami")
end)

test("parses resource with leading whitespace", function()
  local kind, rtype = tf.parse_line('  resource "google_compute_instance" "vm" {')
  assert_eq(kind, "resource")
  assert_eq(rtype, "google_compute_instance")
end)

test("parses data with leading tabs", function()
  local kind, rtype = tf.parse_line('\tdata "azurerm_resource_group" "rg" {')
  assert_eq(kind, "data")
  assert_eq(rtype, "azurerm_resource_group")
end)

test("returns nil for non-resource line", function()
  local kind, rtype = tf.parse_line('  name = "my-instance"')
  assert_nil(kind)
  assert_nil(rtype)
end)

test("returns nil for empty line", function()
  local kind, rtype = tf.parse_line("")
  assert_nil(kind)
  assert_nil(rtype)
end)

test("returns nil for comment line", function()
  local kind, rtype = tf.parse_line('# resource "aws_instance" "web" {')
  assert_nil(kind)
  assert_nil(rtype)
end)

test("parses resource with no trailing brace", function()
  local kind, rtype = tf.parse_line('resource "aws_s3_bucket" "b"')
  assert_eq(kind, "resource")
  assert_eq(rtype, "aws_s3_bucket")
end)

test("parses multi-underscore resource type", function()
  local kind, rtype = tf.parse_line('resource "aws_iam_role_policy_attachment" "attach" {')
  assert_eq(kind, "resource")
  assert_eq(rtype, "aws_iam_role_policy_attachment")
end)

test("parses module block", function()
  local kind, rtype = tf.parse_line('module "github_oidc" {')
  assert_eq(kind, "module")
  assert_eq(rtype, "github_oidc")
end)

test("parses module with leading whitespace", function()
  local kind, rtype = tf.parse_line('  module "vpc" {')
  assert_eq(kind, "module")
  assert_eq(rtype, "vpc")
end)

-- ---------------------------------------------------------------------------
-- build_doc_url tests
-- ---------------------------------------------------------------------------
io.write("\n== build_doc_url ==\n")

test("builds resource URL", function()
  local url = tf.build_doc_url("hashicorp/aws", "resources", "instance")
  assert_eq(url, "https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/instance")
end)

test("builds data source URL", function()
  local url = tf.build_doc_url("hashicorp/aws", "data-sources", "ami")
  assert_eq(url, "https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ami")
end)

test("builds URL for third-party provider", function()
  local url = tf.build_doc_url("cloudflare/cloudflare", "resources", "record")
  assert_eq(url, "https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/record")
end)

test("URL uses forward slashes (cross-platform path safety)", function()
  local url = tf.build_doc_url("hashicorp/aws", "resources", "instance")
  assert_eq(url:find("\\"), nil, "URL should not contain backslashes")
  assert_match(url, "^https://", "URL should start with https://")
end)

test("builds OpenTofu resource URL", function()
  local url = tf.build_doc_url("hashicorp/aws", "resources", "instance", "opentofu")
  assert_eq(url, "https://search.opentofu.org/provider/hashicorp/aws/latest/docs/resources/instance")
end)

test("builds OpenTofu data source URL (datasources not data-sources)", function()
  local url = tf.build_doc_url("hashicorp/aws", "data-sources", "ami", "opentofu")
  assert_eq(url, "https://search.opentofu.org/provider/hashicorp/aws/latest/docs/datasources/ami")
end)

test("builds OpenTofu URL for third-party provider", function()
  local url = tf.build_doc_url("cloudflare/cloudflare", "resources", "record", "opentofu")
  assert_eq(url, "https://search.opentofu.org/provider/cloudflare/cloudflare/latest/docs/resources/record")
end)

test("defaults to terraform registry", function()
  local url = tf.build_doc_url("hashicorp/aws", "resources", "instance", nil)
  assert_match(url, "^https://registry%.terraform%.io/")
end)

-- ---------------------------------------------------------------------------
-- resolve_doc_url tests
-- ---------------------------------------------------------------------------
io.write("\n== resolve_doc_url ==\n")

test("resolves AWS resource", function()
  local url, err = tf.resolve_doc_url("aws_instance", "resource")
  assert_nil(err)
  assert_eq(url, "https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/instance")
end)

test("resolves AWS data source", function()
  local url, err = tf.resolve_doc_url("aws_ami", "data")
  assert_nil(err)
  assert_eq(url, "https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ami")
end)

test("resolves Azure resource", function()
  local url, err = tf.resolve_doc_url("azurerm_resource_group", "resource")
  assert_nil(err)
  assert_eq(url, "https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/resource_group")
end)

test("resolves Google resource", function()
  local url, err = tf.resolve_doc_url("google_compute_instance", "resource")
  assert_nil(err)
  assert_eq(url, "https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_instance")
end)

test("resolves Cloudflare resource", function()
  local url, err = tf.resolve_doc_url("cloudflare_record", "resource")
  assert_nil(err)
  assert_eq(url, "https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/record")
end)

test("resolves GitHub resource", function()
  local url, err = tf.resolve_doc_url("github_repository", "resource")
  assert_nil(err)
  assert_eq(url, "https://registry.terraform.io/providers/integrations/github/latest/docs/resources/repository")
end)

test("resolves GitLab resource", function()
  local url, err = tf.resolve_doc_url("gitlab_project", "resource")
  assert_nil(err)
  assert_eq(url, "https://registry.terraform.io/providers/gitlabhq/gitlab/latest/docs/resources/project")
end)

test("resolves Hetzner Cloud resource", function()
  local url, err = tf.resolve_doc_url("hcloud_server", "resource")
  assert_nil(err)
  assert_eq(url, "https://registry.terraform.io/providers/hetznercloud/hcloud/latest/docs/resources/server")
end)

test("resolves Kubernetes resource", function()
  local url, err = tf.resolve_doc_url("kubernetes_deployment", "resource")
  assert_nil(err)
  assert_eq(url, "https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/deployment")
end)

test("resolves Vault resource", function()
  local url, err = tf.resolve_doc_url("vault_generic_secret", "resource")
  assert_nil(err)
  assert_eq(url, "https://registry.terraform.io/providers/hashicorp/vault/latest/docs/resources/generic_secret")
end)

test("resolves Datadog resource", function()
  local url, err = tf.resolve_doc_url("datadog_monitor", "resource")
  assert_nil(err)
  assert_eq(url, "https://registry.terraform.io/providers/DataDog/datadog/latest/docs/resources/monitor")
end)

test("resolves DigitalOcean resource", function()
  local url, err = tf.resolve_doc_url("digitalocean_droplet", "resource")
  assert_nil(err)
  assert_eq(url, "https://registry.terraform.io/providers/digitalocean/digitalocean/latest/docs/resources/droplet")
end)

test("resolves random provider resource", function()
  local url, err = tf.resolve_doc_url("random_password", "resource")
  assert_nil(err)
  assert_eq(url, "https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password")
end)

test("resolves null provider resource", function()
  local url, err = tf.resolve_doc_url("null_resource", "resource")
  assert_nil(err)
  assert_eq(url, "https://registry.terraform.io/providers/hashicorp/null/latest/docs/resources/resource")
end)

test("resolves tls resource", function()
  local url, err = tf.resolve_doc_url("tls_private_key", "resource")
  assert_nil(err)
  assert_eq(url, "https://registry.terraform.io/providers/hashicorp/tls/latest/docs/resources/private_key")
end)

test("resolves multi-underscore resource name", function()
  local url, err = tf.resolve_doc_url("aws_iam_role_policy_attachment", "resource")
  assert_nil(err)
  assert_eq(url, "https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment")
end)

test("defaults to resources when kind is nil", function()
  local url, err = tf.resolve_doc_url("aws_instance", nil)
  assert_nil(err)
  assert_match(url, "/resources/instance$")
end)

test("falls back to hashicorp for unknown provider prefix", function()
  local url, err = tf.resolve_doc_url("someprovider_thing", "resource")
  assert_nil(err)
  assert_eq(url, "https://registry.terraform.io/providers/hashicorp/someprovider/latest/docs/resources/thing")
end)

test("returns error for nil resource type", function()
  local url, err = tf.resolve_doc_url(nil, "resource")
  assert_nil(url)
  assert_eq(err, "No resource type provided")
end)

test("returns error for type without underscore", function()
  local url, err = tf.resolve_doc_url("nounderscore", "resource")
  assert_nil(url)
  assert_match(err, "Cannot determine provider")
end)

test("resolves local_file using local provider map entry", function()
  local url, err = tf.resolve_doc_url("local_file", "resource")
  assert_nil(err)
  assert_eq(url, "https://registry.terraform.io/providers/hashicorp/local/latest/docs/resources/file")
end)

-- ---------------------------------------------------------------------------
-- parse_provider_key tests
-- ---------------------------------------------------------------------------
io.write("\n== parse_provider_key ==\n")

test("parses terraform registry key", function()
  local ns, name = tf.parse_provider_key("registry.terraform.io/hashicorp/aws")
  assert_eq(ns, "hashicorp")
  assert_eq(name, "aws")
end)

test("parses opentofu registry key", function()
  local ns, name = tf.parse_provider_key("registry.opentofu.org/hashicorp/aws")
  assert_eq(ns, "hashicorp")
  assert_eq(name, "aws")
end)

test("parses third-party provider key", function()
  local ns, name = tf.parse_provider_key("registry.terraform.io/cloudflare/cloudflare")
  assert_eq(ns, "cloudflare")
  assert_eq(name, "cloudflare")
end)

test("returns nil for unrecognised key format", function()
  local ns, name = tf.parse_provider_key("some-unknown-format")
  assert_nil(ns)
  assert_nil(name)
end)

-- ---------------------------------------------------------------------------
-- strip_provider_prefix tests
-- ---------------------------------------------------------------------------
io.write("\n== strip_provider_prefix ==\n")

test("strips single-word prefix", function()
  assert_eq(tf.strip_provider_prefix("aws_instance"), "instance")
end)

test("strips prefix from multi-underscore name", function()
  assert_eq(tf.strip_provider_prefix("aws_iam_role_policy_attachment"), "iam_role_policy_attachment")
end)

test("strips prefix from google resource", function()
  assert_eq(tf.strip_provider_prefix("google_compute_instance"), "compute_instance")
end)

test("returns full name if no underscore", function()
  assert_eq(tf.strip_provider_prefix("nounderscore"), "nounderscore")
end)

-- ---------------------------------------------------------------------------
-- parse_attribute tests
-- ---------------------------------------------------------------------------
io.write("\n== parse_attribute ==\n")

test("parses simple attribute assignment", function()
  assert_eq(tf.parse_attribute('  ami = "abc-123"'), "ami")
end)

test("parses attribute with spaces around equals", function()
  assert_eq(tf.parse_attribute('  instance_type   =   "t3.micro"'), "instance_type")
end)

test("parses boolean attribute", function()
  assert_eq(tf.parse_attribute('  associate_public_ip_address = true'), "associate_public_ip_address")
end)

test("parses numeric attribute", function()
  assert_eq(tf.parse_attribute('  count = 3'), "count")
end)

test("parses block opening", function()
  assert_eq(tf.parse_attribute('  ebs_block_device {'), "ebs_block_device")
end)

test("parses block with extra whitespace", function()
  assert_eq(tf.parse_attribute('    root_block_device   {'), "root_block_device")
end)

test("returns nil for resource declaration", function()
  assert_nil(tf.parse_attribute('resource "aws_instance" "web" {'))
end)

test("returns nil for closing brace", function()
  assert_nil(tf.parse_attribute('  }'))
end)

test("returns nil for empty line", function()
  assert_nil(tf.parse_attribute(''))
end)

test("returns nil for comment", function()
  assert_nil(tf.parse_attribute('  # ami = "abc"'))
end)

test("parses attribute with reference value", function()
  assert_eq(tf.parse_attribute('  subnet_id = aws_subnet.main.id'), "subnet_id")
end)

test("parses attribute with list value", function()
  assert_eq(tf.parse_attribute('  security_groups = ["sg-123"]'), "security_groups")
end)

test("parses unindented attribute assignment", function()
  assert_eq(tf.parse_attribute('ami = "abc-123"'), "ami")
end)

test("parses unindented block opening", function()
  assert_eq(tf.parse_attribute('ebs_block_device {'), "ebs_block_device")
end)

-- ---------------------------------------------------------------------------
-- slugify tests
-- ---------------------------------------------------------------------------
io.write("\n== slugify ==\n")

test("lowercases text", function()
  assert_eq(tf.slugify("Argument Reference"), "argument-reference")
end)

test("preserves underscores (code identifiers)", function()
  assert_eq(tf.slugify("ebs_block_device"), "ebs_block_device")
end)

test("converts spaces to hyphens", function()
  assert_eq(tf.slugify("CPU Options"), "cpu-options")
end)

test("strips non-alphanumeric characters except underscores", function()
  assert_eq(tf.slugify("instance_type (Required)"), "instance_type-required")
end)

test("collapses multiple hyphens", function()
  assert_eq(tf.slugify("foo  bar"), "foo-bar")
end)

test("strips leading/trailing hyphens", function()
  assert_eq(tf.slugify("-foo-"), "foo")
end)

test("handles simple attribute name", function()
  assert_eq(tf.slugify("ami"), "ami")
end)

test("handles mixed case with underscores", function()
  assert_eq(tf.slugify("Associate_Public_IP"), "associate_public_ip")
end)

test("strips backticks (code identifiers in headings)", function()
  assert_eq(tf.slugify("`default_action` Block"), "default_action-block")
end)

test("handles backtick-wrapped identifier alone", function()
  assert_eq(tf.slugify("`ebs_block_device`"), "ebs_block_device")
end)

-- ---------------------------------------------------------------------------
-- generate_slug tests
-- ---------------------------------------------------------------------------
io.write("\n== generate_slug ==\n")

test("generates basic slug", function()
  local links = {}
  assert_eq(tf.generate_slug("Argument Reference", links), "argument-reference")
end)

test("preserves underscores", function()
  local links = {}
  assert_eq(tf.generate_slug("user_pool_id", links), "user_pool_id")
end)

test("appends -1 for first duplicate", function()
  local links = {}
  tf.generate_slug("ami", links)
  assert_eq(tf.generate_slug("ami", links), "ami-1")
end)

test("appends -2 for second duplicate", function()
  local links = {}
  tf.generate_slug("ami", links)
  tf.generate_slug("ami", links)
  assert_eq(tf.generate_slug("ami", links), "ami-2")
end)

test("tracks separate slugs independently", function()
  local links = {}
  tf.generate_slug("foo", links)
  tf.generate_slug("bar", links)
  assert_eq(tf.generate_slug("foo", links), "foo-1")
  assert_eq(tf.generate_slug("bar", links), "bar-1")
end)

test("strips HTML tags", function()
  local links = {}
  assert_eq(tf.generate_slug("Resource: <code>aws_instance</code>", links), "resource-aws_instance")
end)

-- ---------------------------------------------------------------------------
-- find_anchor_in_markdown tests
-- ---------------------------------------------------------------------------
io.write("\n== find_anchor_in_markdown ==\n")

test("finds attribute in simple doc (terraform registry)", function()
  local md = [[
# Resource: aws_cognito_identity_provider

## Example Usage

## Argument Reference

* `region` - (Optional) The region
* `user_pool_id` (Required) - The user pool id
* `provider_name` (Required) - The provider name

## Attribute Reference
]]
  -- Terraform: list items always get raw_text-N where N starts at 1
  assert_eq(tf.find_anchor_in_markdown(md, "user_pool_id"), "user_pool_id-1")
  assert_eq(tf.find_anchor_in_markdown(md, "region"), "region-1")
  assert_eq(tf.find_anchor_in_markdown(md, "provider_name"), "provider_name-1")
end)

test("returns nil for missing attribute", function()
  local md = [[
## Argument Reference

* `ami` - The AMI
]]
  assert_nil(tf.find_anchor_in_markdown(md, "nonexistent"))
end)

test("heading does not affect list item counter (terraform registry)", function()
  -- Terraform: heading counter and list item counter are independent.
  -- The heading "ingress" does NOT consume a count for the list item "ingress".
  local md = [[
## Argument Reference

### ingress

* `ingress` - The ingress config

## Attribute Reference
]]
  assert_eq(tf.find_anchor_in_markdown(md, "ingress"), "ingress-1")
end)

test("list item counter starts at 1, not 0 (terraform registry)", function()
  local md = [[
## Argument Reference

* `name` - The name

### Some Block

* `value` - The value
]]
  -- First occurrence of each attribute gets -1
  assert_eq(tf.find_anchor_in_markdown(md, "name"), "name-1")
  assert_eq(tf.find_anchor_in_markdown(md, "value"), "value-1")
end)

test("duplicate list items increment counter (terraform registry)", function()
  local md = [[
## Argument Reference

* `tags` - Tags for the resource

### EBS Block Device

* `tags` - Tags for the device
* `delete_on_termination` - Whether to delete

### Root Block Device

* `tags` - Tags for root device
* `delete_on_termination` - Whether to delete

## Attribute Reference
]]
  -- First tags -> tags-1, second -> tags-2, third -> tags-3
  assert_eq(tf.find_anchor_in_markdown(md, "tags"), "tags-1")
  assert_eq(tf.find_anchor_in_markdown(md, "delete_on_termination"), "delete_on_termination-1")
end)

test("handles attribute appearing after duplicate heading", function()
  local md = [[
## Example Usage

### Spot Options

## Argument Reference

* `ami` - The AMI

### Spot Options

* `spot_price` - The max price

## Attribute Reference
]]
  -- Terraform: list item counter is independent from headings
  assert_eq(tf.find_anchor_in_markdown(md, "ami"), "ami-1")
  assert_eq(tf.find_anchor_in_markdown(md, "spot_price"), "spot_price-1")
end)

test("handles real cognito_identity_provider doc structure", function()
  local md = [[
# Resource: aws_cognito_identity_provider

Provides a Cognito User Identity Provider resource.

## Example Usage

## Argument Reference

This resource supports the following arguments:

* `region` - (Optional) Region
* `user_pool_id` (Required) - The user pool id
* `provider_name` (Required) - The provider name
* `provider_type` (Required) - The provider type
* `attribute_mapping` (Optional) - The map
* `idp_identifiers` (Optional) - The list
* `provider_details` (Optional) - The map

## Attribute Reference

This resource exports no additional attributes.

## Import
]]
  assert_eq(tf.find_anchor_in_markdown(md, "user_pool_id"), "user_pool_id-1")
  assert_eq(tf.find_anchor_in_markdown(md, "attribute_mapping"), "attribute_mapping-1")
end)

test("opentofu returns section heading for attribute", function()
  local md = [[
# Resource: aws_cognito_identity_provider

## Argument Reference

* `region` - (Optional) Region
* `user_pool_id` (Required) - The user pool id

## Attribute Reference

* `id` - The ID
]]
  -- OpenTofu has no list item anchors; falls back to section heading
  assert_eq(tf.find_anchor_in_markdown(md, "region", "opentofu"), "argument-reference")
  assert_eq(tf.find_anchor_in_markdown(md, "user_pool_id", "opentofu"), "argument-reference")
  assert_eq(tf.find_anchor_in_markdown(md, "id", "opentofu"), "attribute-reference")
end)

test("opentofu returns nil for missing attribute", function()
  local md = [[
## Argument Reference

* `ami` - The AMI
]]
  assert_nil(tf.find_anchor_in_markdown(md, "nonexistent", "opentofu"))
end)

-- ---------------------------------------------------------------------------
-- find_enclosing_attribute tests
-- ---------------------------------------------------------------------------
io.write("\n== find_enclosing_attribute ==\n")

-- Helper: mock vim.api.nvim_buf_get_lines to return a slice of the given lines
local function with_buffer_lines(lines, start_line, fn)
  local orig = vim.api.nvim_buf_get_lines
  vim.api.nvim_buf_get_lines = function(_, first, last, _)
    local result = {}
    for i = first + 1, math.min(last, #lines) do
      table.insert(result, lines[i])
    end
    return result
  end
  local ok, err = pcall(fn)
  vim.api.nvim_buf_get_lines = orig
  if not ok then error(err, 2) end
end

test("finds attribute when inside a map value", function()
  local lines = {
    'resource "aws_instance" "web" {',
    '  ami = "abc-123"',
    '  tags = {',
    '    Name = "hello"',
    '    Env  = "prod"',
    '  }',
    '}',
  }
  with_buffer_lines(lines, 3, function() -- cursor on Name = "hello" (0-indexed line 3)
    assert_eq(tf.find_enclosing_attribute(0, 3), "tags")
  end)
  with_buffer_lines(lines, 4, function() -- cursor on Env = "prod"
    assert_eq(tf.find_enclosing_attribute(0, 4), "tags")
  end)
end)

test("finds attribute when inside a list value", function()
  local lines = {
    'resource "aws_instance" "web" {',
    '  security_groups = [',
    '    "sg-123",',
    '    "sg-456",',
    '  ]',
    '}',
  }
  with_buffer_lines(lines, 2, function() -- cursor on "sg-123"
    assert_eq(tf.find_enclosing_attribute(0, 2), "security_groups")
  end)
end)

test("returns nil when on resource declaration line", function()
  local lines = {
    'resource "aws_instance" "web" {',
    '  ami = "abc-123"',
    '}',
  }
  with_buffer_lines(lines, 0, function() -- cursor on resource line
    assert_nil(tf.find_enclosing_attribute(0, 0))
  end)
end)

test("finds attribute in nested map inside list", function()
  local lines = {
    'resource "aws_instance" "web" {',
    '  ingress = [',
    '    {',
    '      from_port = 80',
    '    },',
    '  ]',
    '}',
  }
  with_buffer_lines(lines, 3, function() -- cursor on from_port = 80
    assert_eq(tf.find_enclosing_attribute(0, 3), "ingress")
  end)
end)

test("finds attribute when cursor is on closing delimiter", function()
  local lines = {
    'resource "aws_instance" "web" {',
    '  tags = {',
    '    Name = "hello"',
    '  }',
    '}',
  }
  with_buffer_lines(lines, 3, function() -- cursor on closing }
    assert_eq(tf.find_enclosing_attribute(0, 3), "tags")
  end)
end)

test("finds attribute when cursor is on closing bracket", function()
  local lines = {
    'resource "aws_instance" "web" {',
    '  security_groups = [',
    '    "sg-123",',
    '  ]',
    '}',
  }
  with_buffer_lines(lines, 3, function() -- cursor on closing ]
    assert_eq(tf.find_enclosing_attribute(0, 3), "security_groups")
  end)
end)

-- ---------------------------------------------------------------------------
-- module support tests
-- ---------------------------------------------------------------------------
io.write("\n== is_registry_module ==\n")

test("accepts 3-part registry source", function()
  assert_eq(tf.is_registry_module("terraform-module/github-oidc-provider/aws"), true)
end)

test("accepts hashicorp module source", function()
  assert_eq(tf.is_registry_module("hashicorp/consul/aws"), true)
end)

test("rejects relative path source", function()
  assert_eq(tf.is_registry_module("./modules/vpc"), false)
end)

test("rejects parent path source", function()
  assert_eq(tf.is_registry_module("../shared/modules"), false)
end)

test("rejects git URL source", function()
  assert_eq(tf.is_registry_module("git::https://example.com/module.git"), false)
end)

test("rejects s3 source", function()
  assert_eq(tf.is_registry_module("s3::https://bucket/module.zip"), false)
end)

test("rejects 2-part source", function()
  assert_eq(tf.is_registry_module("hashicorp/consul"), false)
end)

test("rejects nil source", function()
  assert_eq(tf.is_registry_module(nil), false)
end)

io.write("\n== build_module_url ==\n")

test("builds Terraform module URL", function()
  local url = tf.build_module_url("terraform-module/github-oidc-provider/aws", "terraform")
  assert_eq(url, "https://registry.terraform.io/modules/terraform-module/github-oidc-provider/aws/latest")
end)

test("builds OpenTofu module URL", function()
  local url = tf.build_module_url("terraform-module/github-oidc-provider/aws", "opentofu")
  assert_eq(url, "https://search.opentofu.org/module/terraform-module/github-oidc-provider/aws/latest")
end)

test("defaults to terraform registry for module URL", function()
  local url = tf.build_module_url("hashicorp/consul/aws")
  assert_match(url, "^https://registry%.terraform%.io/modules/")
end)

io.write("\n== find_module_source ==\n")

test("finds source in module block", function()
  local lines = {
    'module "github_oidc" {',
    '  source  = "terraform-module/github-oidc-provider/aws"',
    '  version = "= 2.2.1"',
    '',
    '  create_oidc_provider = true',
    '}',
  }
  local orig = vim.api.nvim_buf_get_lines
  local orig_count = vim.api.nvim_buf_line_count
  vim.api.nvim_buf_get_lines = function(_, first, last, _)
    local result = {}
    for i = first + 1, math.min(last, #lines) do
      table.insert(result, lines[i])
    end
    return result
  end
  vim.api.nvim_buf_line_count = function() return #lines end
  local source = tf.find_module_source(0, 0)
  vim.api.nvim_buf_get_lines = orig
  vim.api.nvim_buf_line_count = orig_count
  assert_eq(source, "terraform-module/github-oidc-provider/aws")
end)

test("returns nil for local module source", function()
  local lines = {
    'module "local_mod" {',
    '  source = "./modules/vpc"',
    '}',
  }
  local orig = vim.api.nvim_buf_get_lines
  local orig_count = vim.api.nvim_buf_line_count
  vim.api.nvim_buf_get_lines = function(_, first, last, _)
    local result = {}
    for i = first + 1, math.min(last, #lines) do
      table.insert(result, lines[i])
    end
    return result
  end
  vim.api.nvim_buf_line_count = function() return #lines end
  local source = tf.find_module_source(0, 0)
  vim.api.nvim_buf_get_lines = orig
  vim.api.nvim_buf_line_count = orig_count
  -- find_module_source returns the source string; is_registry_module validates it
  assert_eq(source, "./modules/vpc")
  assert_eq(tf.is_registry_module(source), false)
end)

-- ---------------------------------------------------------------------------
-- resolve_module_browse_url tests
-- ---------------------------------------------------------------------------
io.write("\n== resolve_module_browse_url ==\n")

-- GitHub shorthand
test("github shorthand basic", function()
  assert_eq(
    tf.resolve_module_browse_url("github.com/hashicorp/example"),
    "https://github.com/hashicorp/example"
  )
end)

test("github shorthand with ref", function()
  assert_eq(
    tf.resolve_module_browse_url("github.com/alisonjenkins/terraform-aws-api-gateway-function?ref=v0.0.1"),
    "https://github.com/alisonjenkins/terraform-aws-api-gateway-function/tree/v0.0.1"
  )
end)

test("github shorthand with subdir", function()
  assert_eq(
    tf.resolve_module_browse_url("github.com/hashicorp/example//modules/vpc"),
    "https://github.com/hashicorp/example/tree/HEAD/modules/vpc"
  )
end)

test("github shorthand with ref and subdir", function()
  assert_eq(
    tf.resolve_module_browse_url("github.com/hashicorp/example//modules/vpc?ref=v1.0"),
    "https://github.com/hashicorp/example/tree/v1.0/modules/vpc"
  )
end)

-- Bitbucket shorthand
test("bitbucket shorthand basic", function()
  assert_eq(
    tf.resolve_module_browse_url("bitbucket.org/hashicorp/example"),
    "https://bitbucket.org/hashicorp/example"
  )
end)

test("bitbucket shorthand with ref", function()
  assert_eq(
    tf.resolve_module_browse_url("bitbucket.org/hashicorp/example?ref=main"),
    "https://bitbucket.org/hashicorp/example/src/main"
  )
end)

-- GitLab shorthand
test("gitlab shorthand with ref", function()
  assert_eq(
    tf.resolve_module_browse_url("gitlab.com/org/repo?ref=v2.0"),
    "https://gitlab.com/org/repo/-/tree/v2.0"
  )
end)

-- Generic git:: HTTPS
test("git:: https basic", function()
  assert_eq(
    tf.resolve_module_browse_url("git::https://github.com/org/repo.git"),
    "https://github.com/org/repo"
  )
end)

test("git:: https with ref", function()
  assert_eq(
    tf.resolve_module_browse_url("git::https://github.com/org/repo.git?ref=v1.0"),
    "https://github.com/org/repo/tree/v1.0"
  )
end)

test("git:: https non-github host", function()
  assert_eq(
    tf.resolve_module_browse_url("git::https://example.com/modules/vpc.git?ref=v1"),
    "https://example.com/modules/vpc/tree/v1"
  )
end)

-- git:: SSH (non-browsable)
test("git:: ssh returns nil", function()
  assert_nil(tf.resolve_module_browse_url("git::ssh://git@github.com/org/repo.git"))
end)

test("git:: with git@ returns nil", function()
  assert_nil(tf.resolve_module_browse_url("git::git@github.com:org/repo.git"))
end)

-- HTTPS archive on known host
test("https archive github extracts repo", function()
  assert_eq(
    tf.resolve_module_browse_url("https://github.com/org/repo/archive/refs/tags/v1.0.zip"),
    "https://github.com/org/repo"
  )
end)

test("https archive gitlab extracts repo", function()
  assert_eq(
    tf.resolve_module_browse_url("https://gitlab.com/org/repo/-/archive/main/repo-main.tar.gz"),
    "https://gitlab.com/org/repo"
  )
end)

-- HTTPS archive on unknown host
test("https archive unknown host strips filename for .zip", function()
  assert_eq(
    tf.resolve_module_browse_url("https://example.com/releases/module-v1.0.zip"),
    "https://example.com/releases/"
  )
end)

test("https archive unknown host strips filename for .tar.gz", function()
  assert_eq(
    tf.resolve_module_browse_url("https://example.com/releases/module.tar.gz"),
    "https://example.com/releases/"
  )
end)

-- HTTPS non-archive on unknown host
test("https non-archive unknown host returns URL as-is", function()
  assert_eq(
    tf.resolve_module_browse_url("https://git.example.com/org/repo"),
    "https://git.example.com/org/repo"
  )
end)

-- Non-browsable sources
test("s3 returns nil", function()
  assert_nil(tf.resolve_module_browse_url("s3::https://bucket/module.zip"))
end)

test("gcs returns nil", function()
  assert_nil(tf.resolve_module_browse_url("gcs::https://bucket/module.zip"))
end)

test("relative path returns nil", function()
  assert_nil(tf.resolve_module_browse_url("./modules/vpc"))
end)

test("absolute path returns nil", function()
  assert_nil(tf.resolve_module_browse_url("/opt/modules/vpc"))
end)

test("nil returns nil", function()
  assert_nil(tf.resolve_module_browse_url(nil))
end)

test("registry module returns nil (handled separately)", function()
  assert_nil(tf.resolve_module_browse_url("hashicorp/consul/aws"))
end)

-- ---------------------------------------------------------------------------
-- resolve_doc_url with OpenTofu registry
-- ---------------------------------------------------------------------------
io.write("\n== resolve_doc_url with OpenTofu registry ==\n")

test("resolves OpenTofu resource URL", function()
  local url, err = tf.resolve_doc_url("aws_instance", "resource", nil, "opentofu")
  assert_nil(err)
  assert_eq(url, "https://search.opentofu.org/provider/hashicorp/aws/latest/docs/resources/instance")
end)

test("resolves OpenTofu data source URL", function()
  local url, err = tf.resolve_doc_url("aws_ami", "data", nil, "opentofu")
  assert_nil(err)
  assert_eq(url, "https://search.opentofu.org/provider/hashicorp/aws/latest/docs/datasources/ami")
end)

test("resolves OpenTofu third-party provider", function()
  local url, err = tf.resolve_doc_url("cloudflare_record", "resource", nil, "opentofu")
  assert_nil(err)
  assert_eq(url, "https://search.opentofu.org/provider/cloudflare/cloudflare/latest/docs/resources/record")
end)

-- ---------------------------------------------------------------------------
-- End-to-end: parse_line + parse_attribute -> resolve_doc_url
-- ---------------------------------------------------------------------------
io.write("\n== end-to-end: parse_line -> resolve_doc_url ==\n")

test("resource line -> correct URL", function()
  local kind, rtype = tf.parse_line('resource "aws_s3_bucket" "my_bucket" {')
  local url, err = tf.resolve_doc_url(rtype, kind)
  assert_nil(err)
  assert_eq(url, "https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket")
end)

test("data source line -> correct URL", function()
  local kind, rtype = tf.parse_line('data "google_compute_network" "default" {')
  local url, err = tf.resolve_doc_url(rtype, kind)
  assert_nil(err)
  assert_eq(url, "https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/compute_network")
end)

test("azuread data source line -> correct URL", function()
  local kind, rtype = tf.parse_line('data "azuread_application" "app" {')
  local url, err = tf.resolve_doc_url(rtype, kind)
  assert_nil(err)
  assert_eq(url, "https://registry.terraform.io/providers/hashicorp/azuread/latest/docs/data-sources/application")
end)

test("helm resource line -> correct URL", function()
  local kind, rtype = tf.parse_line('resource "helm_release" "nginx" {')
  local url, err = tf.resolve_doc_url(rtype, kind)
  assert_nil(err)
  assert_eq(url, "https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release")
end)

test("consul resource line -> correct URL", function()
  local kind, rtype = tf.parse_line('resource "consul_keys" "app" {')
  local url, err = tf.resolve_doc_url(rtype, kind)
  assert_nil(err)
  assert_eq(url, "https://registry.terraform.io/providers/hashicorp/consul/latest/docs/resources/keys")
end)

test("attribute parse + resolve gives base URL (anchor resolved at runtime via HTML)", function()
  local attr_line = '  ami = "abc-123"'
  local block_line = 'resource "aws_instance" "web" {'
  local attribute = tf.parse_attribute(attr_line)
  assert_eq(attribute, "ami")
  local kind, rtype = tf.parse_line(block_line)
  local url, err = tf.resolve_doc_url(rtype, kind, nil)
  assert_nil(err)
  assert_eq(url, "https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/instance")
end)

test("block parse + resolve gives base URL", function()
  local attr_line = '  ebs_block_device {'
  local block_line = 'resource "aws_instance" "web" {'
  local attribute = tf.parse_attribute(attr_line)
  assert_eq(attribute, "ebs_block_device")
  local kind, rtype = tf.parse_line(block_line)
  local url, err = tf.resolve_doc_url(rtype, kind, nil)
  assert_nil(err)
  assert_eq(url, "https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/instance")
end)

-- ---------------------------------------------------------------------------
-- provider_map completeness
-- ---------------------------------------------------------------------------
io.write("\n== provider_map ==\n")

test("all known providers are mapped", function()
  local expected_providers = {
    "archive", "aws", "azuread", "azurerm", "cloudflare", "consul",
    "datadog", "digitalocean", "dns", "external", "github", "gitlab",
    "google", "hcloud", "helm", "http", "kubernetes", "linode", "local",
    "nomad", "null", "oci", "random", "template", "tls", "vault", "vsphere",
  }
  for _, prefix in ipairs(expected_providers) do
    assert_eq(tf.provider_map[prefix] ~= nil, true, "Missing provider mapping for: " .. prefix)
  end
end)

test("provider map values contain slash separator", function()
  for prefix, provider in pairs(tf.provider_map) do
    assert_match(provider, "/", "Provider value should contain '/': " .. prefix .. " = " .. provider)
  end
end)

-- ---------------------------------------------------------------------------
-- Results
-- ---------------------------------------------------------------------------
io.write(string.format("\n%d passed, %d failed\n", passed, failed))
if #errors > 0 then
  io.write("\nFailed tests:\n")
  for _, e in ipairs(errors) do
    io.write("  - " .. e.name .. ": " .. tostring(e.err) .. "\n")
  end
end

os.exit(failed == 0 and 0 or 1)
