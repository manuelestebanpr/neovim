local M = {}
local jdtls = require('jdtls')
local utils = require('jdtls.utils')

-- =============================================================================
-- 1. CONFIGURATION
-- =============================================================================

local CONF = {}
local REAL_CUSTOM_PATH = nil

local function init_paths(hybris_root)
  if CONF.HYBRIS_ROOT then return end

  if not hybris_root then
    -- Resolve the authoritative platform root through get_platform_root(), which
    -- validates EVERY candidate ($HYBRIS_HOME_DIR, $PLATFORM_HOME, cwd) by the
    -- presence of bin/platform. This is critical on this machine where
    -- $HYBRIS_HOME_DIR already ends in "/hybris": the old naive
    -- `HYBRIS_HOME_DIR .. "/hybris"` doubled it to a non-existent path, which broke
    -- every arg-less caller (notably restore_backups). get_platform_root() tries
    -- both `$HYBRIS_HOME_DIR/hybris` and the bare `$HYBRIS_HOME_DIR` and keeps the
    -- one that actually contains bin/platform.
    hybris_root = utils.get_platform_root()
    if not hybris_root then
      local _, root = utils.detect_project()
      hybris_root = root
    end
  end

  CONF.HYBRIS_ROOT = hybris_root

  local hybris_dir_name = vim.fn.fnamemodify(CONF.HYBRIS_ROOT, ":h:t")
  if hybris_dir_name == "" or hybris_dir_name == "/" then
    hybris_dir_name = "hybris_project"
  end

  local paths = utils.get_jdtls_paths()

  CONF.JAVA_CMD = utils.get_java_cmd()
  CONF.JAVA_HOME = utils.get_java_home()
  CONF.WORKSPACE_DATA = os.getenv("HOME") .. "/.local/share/nvim/sapcommerce/" .. hybris_dir_name
  CONF.CONFIG_PATH = paths.config
  CONF.JDTLS_JAR = paths.launcher

  local logical_custom = CONF.HYBRIS_ROOT .. "/bin/custom"
  if vim.fn.isdirectory(logical_custom) == 1 then
    local resolved = vim.fn.resolve(logical_custom)
    REAL_CUSTOM_PATH = vim.fn.fnamemodify(resolved, ":p"):gsub("/+$", "")
  else
    REAL_CUSTOM_PATH = nil
  end
end

local STATE = {
  name_to_path = {},
  workspace_folders = {},
  processed_exts = {},
}

-- Per-session import guard. The heavy prepare_workspace() (fd scan + metadata
-- synthesis + classpath injection + localextensions parse) runs AT MOST ONCE per
-- resolved hybris root for the life of the nvim session.
--   IMPORTED[root] = nil       -> never imported
--                  = "pending" -> import running (re-entrancy guard so two buffers
--                                 opening at startup don't both scan)
--                  = table     -> done; frozen { cmd, workspace_folders, root_dir,
--                                 java_home } for that root
-- Keyed by the RESOLVED hybris root so the rare multi-root / :cd case is supported
-- without rescanning a root already imported.
local IMPORTED = {}

-- =============================================================================
-- 2. I/O UTILS
-- =============================================================================

local function read_file_content(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

-- Directories that never hold a Hybris extension root but are expensive to walk.
local SKIP_DIRS = {
  ["node_modules"] = true,
  ["bower_components"] = true,
  [".git"] = true,
  [".svn"] = true,
  ["dist"] = true,
  ["build"] = true,
  ["classes"] = true,
  ["testclasses"] = true,
}

-- Pure-Lua recursive fallback, used only when `fd` is unavailable. Collects every
-- extensioninfo.xml under `dir`. Prunes once an extension root is found (Hybris
-- extensions are siblings, never nested inside one another), skips heavy
-- build/vendor directories, and follows symlinks via fs_stat with a depth cap as
-- a loop guard.
local function scan_extensioninfo(dir, acc, depth, seen)
  acc = acc or {}
  depth = depth or 0
  seen = seen or {}
  if depth > 40 then return acc end -- shallow trees in practice; just a backstop

  local uv = vim.uv or vim.loop

  -- Guard against symlink cycles by tracking canonical (resolved) paths.
  local real = uv.fs_realpath(dir)
  if real then
    if seen[real] then return acc end
    seen[real] = true
  end

  local handle = uv.fs_scandir(dir)
  if not handle then return acc end

  local subdirs = {}
  local found_here = false
  while true do
    local name, typ = uv.fs_scandir_next(handle)
    if not name then break end
    local full = dir .. "/" .. name
    if name == "extensioninfo.xml" then
      table.insert(acc, full)
      found_here = true
    elseif not SKIP_DIRS[name] then
      if typ == nil or typ == "link" then
        local st = uv.fs_stat(full)
        typ = st and st.type or nil
      end
      if typ == "directory" then
        table.insert(subdirs, full)
      end
    end
  end

  if not found_here then
    for _, sub in ipairs(subdirs) do
      scan_extensioninfo(sub, acc, depth + 1, seen)
    end
  end
  return acc
end

-- Locate every extensioninfo.xml under <bin_dir>. Prefers `fd` (fast, parallel,
-- symlink-aware) and falls back to the pure-Lua scan above. Returns a list of
-- absolute paths.
local function find_extensioninfo_files(bin_dir)
  if vim.fn.executable("fd") == 1 then
    -- List form => run without a shell: no quoting/word-splitting pitfalls and
    -- no stray extra search path. -L follows symlinks, -a yields absolute paths,
    -- and the regex is anchored to the exact filename.
    local results = vim.fn.systemlist({
      "fd", "-L", "-t", "f", "-a", "--", "^extensioninfo\\.xml$", bin_dir,
    })
    if vim.v.shell_error == 0 and #results > 0 then
      return results
    end
  end
  return scan_extensioninfo(bin_dir)
end

-- Build STATE.name_to_path: every extension directory keyed by its name. Returns
-- the number of extensions discovered.
local function build_extension_map()
  STATE.name_to_path = {}
  local files = find_extensioninfo_files(CONF.HYBRIS_ROOT .. "/bin")
  for _, xml_path in ipairs(files) do
    if xml_path ~= "" and xml_path:match("extensioninfo%.xml$") then
      -- `fd -L` follows the bin/custom symlink but reports the path THROUGH it
      -- (logical, e.g. <root>/bin/custom/rccl/...). nvim, however, ALWAYS resolves
      -- symlinks in buffer names, so an opened custom file's buffer is the REAL path
      -- (.../core-customize/hybris/bin/custom/rccl/...). Register the resolved real
      -- path here so workspace folders match the buffers jdtls actually receives --
      -- otherwise jdtls treats the file as project-less ("not on the classpath") and
      -- cross-extension navigation breaks. Non-symlinked platform/module paths are
      -- unchanged by resolve().
      local ext_path = vim.fn.resolve(vim.fs.dirname(xml_path))
      local ext_name = vim.fn.fnamemodify(ext_path, ":t")
      STATE.name_to_path[ext_name] = ext_path
    end
  end
  return vim.tbl_count(STATE.name_to_path)
end

-- =============================================================================
-- 3. XML PARSING & DEPENDENCIES
-- =============================================================================

-- Parses extensioninfo.xml to find <requires-extension> entries
local function get_dependencies(ext_path)
  local xml_path = ext_path .. "/extensioninfo.xml"
  local content = read_file_content(xml_path)
  if not content then return {} end

  content = content:gsub("<!%-%-(.-)%-%->", "") -- Remove comments safely

  local deps = {}
  for name in content:gmatch('<requires%-extension[^>]-name=["\']([^"\']+)["\']') do
    table.insert(deps, name)
  end

  return deps
end

-- Recursively resolves deps: populates workspace (global) and dependency tree (local)
local function resolve_dependencies_recursive(ext_name, accumulated_deps)
  local ext_path = STATE.name_to_path[ext_name]

  -- Handle platform special case if path not found in map
  if not ext_path and ext_name == "platform" then
    ext_path = CONF.HYBRIS_ROOT .. "/bin/platform"
  end

  if not ext_path then return end

  -- [Requirement 1 & 2] If this ext isn't in workspace yet, add it now
  if not STATE.processed_exts[ext_name] then
    STATE.processed_exts[ext_name] = true
    table.insert(STATE.workspace_folders, "file://" .. ext_path)
  end

  -- Traverse dependencies regardless of workspace state to build full tree
  local immediate_deps = get_dependencies(ext_path)

  for _, dep_name in ipairs(immediate_deps) do
    if not accumulated_deps[dep_name] then
      accumulated_deps[dep_name] = true -- Mark visited for this recursion chain
      resolve_dependencies_recursive(dep_name, accumulated_deps)
    end
  end
end

-- =============================================================================
-- 4. CLASSPATH INJECTION
-- =============================================================================

-- True when an extension lives under the custom directory, whether that is the
-- standard "<root>/bin/custom" or a symlinked physical location (REAL_CUSTOM_PATH).
-- Boundary-aware: a sibling like "<root>/bin/customaddons" must NOT match.
local function is_custom_extension(ext_path)
  if not ext_path then return false end
  if ext_path:find("/bin/custom/", 1, true) then
    return true
  end
  if REAL_CUSTOM_PATH and ext_path:sub(1, #REAL_CUSTOM_PATH + 1) == REAL_CUSTOM_PATH .. "/" then
    return true
  end
  return false
end

local function update_classpath(ext_name, dependencies)
  local ext_path = STATE.name_to_path[ext_name]
  if not ext_path then return end

  if not is_custom_extension(ext_path) then return end

  local classpath_file = ext_path .. "/.classpath"
  if vim.fn.filereadable(classpath_file) == 0 then return end

  -- 1. Create Backup
  local backup_file = ext_path .. "/.classpath.nvim_bak"
  if vim.fn.filereadable(backup_file) == 0 then
    vim.fn.writefile(vim.fn.readfile(classpath_file), backup_file)
    vim.notify("Backed up .classpath for " .. ext_name, vim.log.levels.DEBUG)
  end

  -- 2. Read lines
  local lines = vim.fn.readfile(classpath_file)
  local file_content_str = table.concat(lines, "\n")
  local new_lines = {}
  local injected_count = 0

  -- 3. Prepare entries
  local entries_to_add = {}
  for dep_name, _ in pairs(dependencies) do
    if dep_name ~= ext_name and dep_name ~= "platform" then
      local entry_str = string.format('\t<classpathentry exported="false" kind="src" path="/%s" />', dep_name)
      if not string.find(file_content_str, 'path="/' .. dep_name .. '"', 1, true) then
        table.insert(entries_to_add, entry_str)
      end
    end
  end

  if #entries_to_add == 0 then return end

  -- 4. Inject
  for _, line in ipairs(lines) do
    if string.find(line, "</classpath>") then
      for _, entry in ipairs(entries_to_add) do
        table.insert(new_lines, entry)
        injected_count = injected_count + 1
      end
      table.insert(new_lines, line)
    else
      table.insert(new_lines, line)
    end
  end

  if injected_count > 0 then
    vim.fn.writefile(new_lines, classpath_file)
    vim.notify(string.format("Updated %s: Added %d transitive dependencies.", ext_name, injected_count), vim.log.levels.INFO)
  end
end

-- =============================================================================
-- 4a. LIB IMPORT (lib/*.jar + web WEB-INF/lib/*.jar -> .classpath)
--
-- Make sure EVERY jar physically present in a custom extension's lib/ (and each web
-- context's WEB-INF/lib) is referenced on its .classpath, so third-party jars
-- resolve in jdtls. This is what "import the lib folder properly on each extension"
-- means: a jar dropped into lib/ after the last ant build would otherwise be invisible
-- to the language server.
--
-- Idempotent and additive: only jars NOT already on the classpath are injected
-- (before </classpath>), after the SAME one-time .nvim_bak backup update_classpath
-- uses, so <leader>clr reverts it. A GENERATED .classpath already lists its lib jars
-- (generate_classpath_file), so this is a no-op there; the real win is custom
-- extensions with a pre-existing/ant .classpath that predates a newly-added jar.
--
-- Scope: CUSTOM extensions only. Platform/standard modules ship a correct
-- ant-generated .classpath (their lib is already on it), and we never rewrite those.
-- Every custom extension in the workspace -- i.e. those in localextensions.xml, their
-- transitive requires-extension deps, and all of bin/custom -- is covered by the
-- Pass 1 loop that calls this.
-- =============================================================================
local function ensure_lib_entries(ext_name)
  local ext_path = STATE.name_to_path[ext_name]
  if not ext_path then return end
  if not is_custom_extension(ext_path) then return end

  local classpath_file = ext_path .. "/.classpath"
  if vim.fn.filereadable(classpath_file) == 0 then return end

  local lines = vim.fn.readfile(classpath_file)
  local content = table.concat(lines, "\n")

  -- Every candidate jar as an extension-relative path, matching ant's entry shape
  -- (global lib/ unexported; web WEB-INF/lib unexported -- same as generate_classpath_file).
  local rels = {}
  for _, jar in ipairs(vim.fn.glob(ext_path .. "/lib/*.jar", true, true)) do
    table.insert(rels, "lib/" .. vim.fn.fnamemodify(jar, ":t"))
  end
  for _, wd in ipairs({
    "web/webroot/WEB-INF/lib",
    "acceleratoraddon/web/webroot/WEB-INF/lib",
    "commonweb/webroot/WEB-INF/lib",
  }) do
    for _, jar in ipairs(vim.fn.glob(ext_path .. "/" .. wd .. "/*.jar", true, true)) do
      table.insert(rels, wd .. "/" .. vim.fn.fnamemodify(jar, ":t"))
    end
  end
  table.sort(rels)

  local to_add = {}
  for _, rel in ipairs(rels) do
    -- Dedup against the exact path="..." token already present (kind-agnostic, so a
    -- jar listed as exported lib is still treated as present).
    if not string.find(content, 'path="' .. rel .. '"', 1, true) then
      table.insert(to_add, string.format('\t<classpathentry kind="lib" path="%s"/>', rel))
    end
  end
  if #to_add == 0 then return end

  -- Back up the ORIGINAL once (no-op if update_classpath already created it), so the
  -- backup is always pre-modification and <leader>clr restores it faithfully.
  local backup_file = classpath_file .. ".nvim_bak"
  if vim.fn.filereadable(backup_file) == 0 then
    vim.fn.writefile(lines, backup_file)
  end

  local new_lines = {}
  for _, line in ipairs(lines) do
    if string.find(line, "</classpath>", 1, true) then
      for _, entry in ipairs(to_add) do table.insert(new_lines, entry) end
    end
    table.insert(new_lines, line)
  end
  vim.fn.writefile(new_lines, classpath_file)
  vim.notify(string.format("%s: imported %d lib jar(s) into .classpath.", ext_name, #to_add),
    vim.log.levels.INFO)
end

-- =============================================================================
-- 4b. METADATA SYNTHESIS (generate missing .project / .classpath)
--
-- For CUSTOM extensions that ant never imported into Eclipse, JDT has no project
-- to resolve cross-extension "/DEP" classpath references against. e.g. rcclcore's
-- .classpath has <classpathentry kind="src" path="/travelservices"/> but
-- travelservices ships NO .project/.classpath, so TransportOfferingService is
-- unresolved and RcclTransportOfferingService shows a spurious error even though
-- ant compiles fine. We synthesize minimal, JDT-correct metadata in pure Lua
-- (fast, deterministic, in-editor) instead of running heavyweight `ant eclipse`.
--
-- Every file we create is recorded in a sibling ".nvim_gen" marker so
-- M.restore_backups() can DELETE generated files (vs. restoring ".nvim_bak" for
-- files we merely injected into). We NEVER overwrite an existing file. Files are
-- written to STATE.name_to_path[name], which build_extension_map populated with
-- vim.fn.resolve()'d REAL paths in the extensions repo -- the same paths nvim's
-- symlink-resolved buffers and the workspaceFolders use, so JDT sees them as
-- project roots that match the open buffers.
-- =============================================================================

local function dir_exists(p) return vim.fn.isdirectory(p) == 1 end
local function file_exists(p) return vim.fn.filereadable(p) == 1 end

-- Append a generated basename to the per-extension marker so restore can delete it.
local function record_generated(ext_path, basename)
  local marker = ext_path .. "/.nvim_gen"
  local lines = file_exists(marker) and vim.fn.readfile(marker) or {}
  for _, l in ipairs(lines) do if l == basename then return end end
  table.insert(lines, basename)
  vim.fn.writefile(lines, marker)
end

-- Minimal javanature project. name MUST equal the dir basename so a sibling's
-- "/<name>" classpath ref resolves to it (rcclcore -> /travelservices). Mirrors
-- ant's generated .project (javabuilder buildCommand + javanature) minus optional
-- spring/pmd/external-tool builders, which JDT does not need for type resolution.
local function generate_project_file(ext_path, ext_name)
  local project_file = ext_path .. "/.project"
  if file_exists(project_file) then return false end -- idempotent: never overwrite
  local xml = {
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<projectDescription>',
    '\t<!-- generated by nvim hybris_setup; safe to delete -->',
    '\t<name>' .. ext_name .. '</name>',
    '\t<comment></comment>',
    '\t<projects>',
    '\t</projects>',
    '\t<buildSpec>',
    '\t\t<buildCommand>',
    '\t\t\t<name>org.eclipse.jdt.core.javabuilder</name>',
    '\t\t\t<arguments>',
    '\t\t\t</arguments>',
    '\t\t</buildCommand>',
    '\t</buildSpec>',
    '\t<natures>',
    '\t\t<nature>org.eclipse.jdt.core.javanature</nature>',
    '\t</natures>',
    '</projectDescription>',
  }
  -- writefile returns 0 on success, -1 on failure (and may also raise, which the
  -- caller's pcall catches). Only record a marker for a file that actually landed,
  -- so the "Generated metadata" notify and restore deletion stay truthful.
  if vim.fn.writefile(xml, project_file) ~= 0 then
    vim.notify("Failed to write " .. project_file, vim.log.levels.ERROR)
    return false
  end
  record_generated(ext_path, ".project")
  return true
end

-- Minimal but valid .classpath. Emits ONLY src dirs that exist on disk, all
-- lib/*.jar, resources as exported lib, /platform, and one /DEP per DIRECT
-- requires-extension (from get_dependencies). Transitive deps are left for
-- update_classpath() to inject afterwards. Entry shapes match ant's real
-- generated module .classpath (verified: output="eclipsebin/classes", resources
-- as exported lib, output="eclipsebin/notused").
local function generate_classpath_file(ext_path, ext_name)
  local classpath_file = ext_path .. "/.classpath"
  if file_exists(classpath_file) then return false end -- idempotent

  local lines = {
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<classpath>',
    '\t<!-- generated by nvim hybris_setup; safe to delete -->',
    '\t<classpathentry kind="con" path="org.eclipse.jdt.launching.JRE_CONTAINER"/>',
    '\t<classpathentry kind="src" path="/platform"/>',
  }

  -- (path on disk -> output dir) for every candidate source root, in a stable order.
  local src_specs = {
    { "src",      "eclipsebin/classes" },
    { "gensrc",   "eclipsebin/classes" },
    { "testsrc",  "eclipsebin/classes" },
    { "web/src",                      "eclipsebin/web/classes" },
    { "web/testsrc",                  "eclipsebin/web/classes" },
    { "acceleratoraddon/web/src",     "eclipsebin/web/classes" },
    { "acceleratoraddon/web/testsrc", "eclipsebin/web/classes" },
  }
  for _, spec in ipairs(src_specs) do
    local rel, out = spec[1], spec[2]
    if dir_exists(ext_path .. "/" .. rel) then
      table.insert(lines, string.format(
        '\t<classpathentry kind="src" output="%s" path="%s"/>', out, rel))
    end
  end

  -- resources as an exported library (matches generated output).
  if dir_exists(ext_path .. "/resources") then
    table.insert(lines, '\t<classpathentry exported="true" kind="lib" path="resources"/>')
  end

  -- Each lib/*.jar as kind=lib (path relative to the extension dir).
  local jars = vim.fn.glob(ext_path .. "/lib/*.jar", true, true)
  table.sort(jars)
  for _, jar in ipairs(jars) do
    local rel = vim.fn.fnamemodify(jar, ":t")
    table.insert(lines, string.format('\t<classpathentry kind="lib" path="lib/%s"/>', rel))
  end

  -- WEB CONTEXT libraries: each <web-dir>/webroot/WEB-INF/lib/*.jar as kind=lib,
  -- path RELATIVE to the extension dir, no exported attr -- exactly as ant emits
  -- them. These back the WEB application context (controllers, JSP tag libs) and
  -- are NOT on the global lib/ path, so without them web/src classes importing
  -- jstl/jsoup/wro4j were unresolved. Empty web lib dirs emit nothing (matches ant).
  for _, wd in ipairs({
    "web/webroot/WEB-INF/lib",
    "acceleratoraddon/web/webroot/WEB-INF/lib",
    "commonweb/webroot/WEB-INF/lib",
  }) do
    local wjars = vim.fn.glob(ext_path .. "/" .. wd .. "/*.jar", true, true)
    table.sort(wjars)
    for _, jar in ipairs(wjars) do
      table.insert(lines, string.format('\t<classpathentry kind="lib" path="%s/%s"/>',
        wd, vim.fn.fnamemodify(jar, ":t")))
    end
  end

  -- One /DEP per DIRECT requires-extension (skip platform; it is implicit above).
  -- Same path="/<dep>" token update_classpath's dedup guard checks, so transitive
  -- injection later won't duplicate these.
  for _, dep in ipairs(get_dependencies(ext_path)) do
    if dep ~= "platform" and dep ~= ext_name then
      table.insert(lines, string.format('\t<classpathentry kind="src" path="/%s"/>', dep))
    end
  end

  table.insert(lines, '\t<classpathentry kind="output" path="eclipsebin/notused"/>')
  table.insert(lines, '</classpath>')

  if vim.fn.writefile(lines, classpath_file) ~= 0 then
    vim.notify("Failed to write " .. classpath_file, vim.log.levels.ERROR)
    return false
  end
  record_generated(ext_path, ".classpath")
  return true
end

-- Synthesize whichever of .project/.classpath is missing for one custom extension.
local function synthesize_missing_metadata(ext_name)
  local ext_path = STATE.name_to_path[ext_name]
  if not ext_path or not is_custom_extension(ext_path) then return end
  local made_p = generate_project_file(ext_path, ext_name)
  local made_c = generate_classpath_file(ext_path, ext_name)
  if made_p or made_c then
    vim.notify(string.format("Generated metadata for %s (%s%s).", ext_name,
      made_p and ".project " or "", made_c and ".classpath" or ""),
      vim.log.levels.INFO)
  end
end

-- =============================================================================
-- 4c. MAVEN DEPENDENCIES (external-dependencies.xml -> lib/)
--
-- Hybris extensions with usemaven="true" declare maven deps in
-- external-dependencies.xml (a real POM); the `ant` build resolves them into lib/.
-- We can't re-run ant, but we CAN: (a) verify the declared artifacts are present in
-- lib/, (b) if a real `mvn` exists, resolve the missing ones (copy-dependencies),
-- (c) otherwise report exactly what's missing and how to fix. mvn is absent on this
-- machine and ant already populated lib/, so the common path is a cheap no-op.
-- =============================================================================

-- usemaven flag is an attribute on the <extension> tag of extensioninfo.xml.
local function ext_uses_maven(ext_path)
  local content = read_file_content(ext_path .. "/extensioninfo.xml")
  if not content then return false end
  content = content:gsub("<!%-%-(.-)%-%->", "")
  local tag = content:match("<extension[^>]*>")
  return tag ~= nil and tag:find('usemaven%s*=%s*["\']true["\']') ~= nil
end

-- Declared artifacts from one external-dependencies.xml: only <dependencies>/
-- <dependency> (NOT the POM's own <artifactId>), skips commented-out blocks,
-- resolves ${prop} versions from <properties>.
local function parse_external_deps(xml_path)
  local content = read_file_content(xml_path)
  if not content or content == "" then return {} end
  content = content:gsub("<!%-%-.-%-%->", "")
  local props = {}
  local pblock = content:match("<properties>(.-)</properties>")
  if pblock then for k, v in pblock:gmatch("<([%w%.%-_]+)>%s*([^<]-)%s*</%1>") do props[k] = v end end
  local deps = {}
  local dblock = content:match("<dependencies>(.-)</dependencies>")
  if not dblock then return deps end
  for dep in dblock:gmatch("<dependency>(.-)</dependency>") do
    local aid = dep:match("<artifactId>%s*([^<]-)%s*</artifactId>")
    local ver = dep:match("<version>%s*([^<]-)%s*</version>")
    if ver then ver = ver:gsub("%${([%w%.%-_]+)}", function(p) return props[p] or ("${" .. p .. "}") end) end
    if aid then deps[#deps + 1] = { artifactId = aid, version = ver } end
  end
  return deps
end

-- Completeness of one dep folder (dir holding external-dependencies.xml). Cheap
-- .lastupdate fast-path (the same uptodate guard ant uses), then a jar-name scan
-- honouring unmanaged-dependencies.txt.
local function check_dep_folder(folder)
  local depfile = folder .. "/external-dependencies.xml"
  if not file_exists(depfile) then return nil end
  local libdir = folder .. "/lib"
  local marker = libdir .. "/.lastupdate"
  if file_exists(marker) and vim.fn.getftime(marker) >= vim.fn.getftime(depfile) then
    return { folder = folder, ok = true, uptodate = true, missing = {} }
  end
  local unmanaged = {}
  local uf = folder .. "/unmanaged-dependencies.txt"
  if file_exists(uf) then
    for _, l in ipairs(vim.fn.readfile(uf)) do
      l = vim.trim(l); if l ~= "" and l:sub(1, 1) ~= "#" then unmanaged[l] = true end
    end
  end
  local have = {}
  for _, j in ipairs(vim.fn.glob(libdir .. "/*.jar", true, true)) do
    have[vim.fn.fnamemodify(j, ":t")] = true
  end
  local missing = {}
  for _, d in ipairs(parse_external_deps(depfile)) do
    local prefix = d.artifactId .. "-"
    local found = unmanaged[d.artifactId] ~= nil
    if not found then
      for name in pairs(have) do if name:sub(1, #prefix) == prefix then found = true; break end end
    end
    if not found then missing[#missing + 1] = d.artifactId .. (d.version and (":" .. d.version) or "") end
  end
  return { folder = folder, ok = (#missing == 0), uptodate = false, missing = missing }
end

-- Locate a REAL mvn binary; never trust M2_HOME (it is the local repo ~/.m2 here).
local function find_mvn()
  local p = vim.fn.exepath("mvn")
  if p ~= "" and vim.fn.executable(p) == 1 then return p end
  for _, env in ipairs({ "MAVEN_HOME", "M2_HOME" }) do
    local h = os.getenv(env)
    if h and h ~= "" then
      local mp = h .. "/bin/mvn"
      if vim.fn.executable(mp) == 1 then return mp end
    end
  end
  return nil
end

-- Standalone equivalent of Hybris's copy-dependencies; non-destructive (no
-- deleteJars), writes .lastupdate on success. Only reached when a real mvn exists.
local function run_copy_dependencies(mvn, folder)
  local res = vim.system({
    mvn, "-q", "-B",
    "-f", folder .. "/external-dependencies.xml",
    "org.apache.maven.plugins:maven-dependency-plugin:copy-dependencies",
    "-DoutputDirectory=" .. folder .. "/lib",
    "-DexcludeTransitive=true",
    "-DoverWriteReleases=true", "-DoverWriteSnapshots=true", "-DoverWriteIfNewer=true",
  }, { text = true }):wait()
  if res.code == 0 then pcall(vim.fn.writefile, {}, folder .. "/lib/.lastupdate") end
  return res.code == 0, (res.stderr or "") .. (res.stdout or "")
end

-- =============================================================================
-- 5. ORCHESTRATOR
-- =============================================================================

local function prepare_workspace()
  vim.notify("Building Extension Map & Resolving Workspace...", vim.log.levels.INFO)

  -- Reset State
  STATE.workspace_folders = {}
  STATE.processed_exts = {}
  STATE.name_to_path = {}

  -- 1. Build Global Map: find ALL extensions under /bin (recursively).
  -- This master list lets us resolve any requires-extension dependency by name.
  local ext_count = build_extension_map()
  vim.notify(string.format("Discovered %d extensions under bin/.", ext_count), vim.log.levels.INFO)

  -- 2. PASS 1: Force Load ALL Custom Extensions & Inject Classpaths
  -- We iterate the map first to ensure everything in /custom/ is added to the workspace,
  -- regardless of whether it appears in localextensions.xml.
  vim.notify("Scanning and Injecting Classpaths for ALL Custom Extensions...", vim.log.levels.INFO)

  for name, path in pairs(STATE.name_to_path) do
    if is_custom_extension(path) then
      -- 0. Synthesize missing .project/.classpath FIRST. This makes the extension
      --    a loadable JDT project so OTHER extensions' "/<name>" classpath refs
      --    resolve (e.g. rcclcore -> /travelservices). Must precede update_classpath,
      --    which bails when .classpath is unreadable. Because this runs inside the
      --    once-per-session import (before jdtls.start_or_attach), the generated
      --    files exist on disk at jdtls initialize time -- no workspace refresh
      --    needed.
      synthesize_missing_metadata(name)

      -- 1. Calculate dependencies specifically for this extension
      local custom_deps = {}

      -- 2. Add to workspace (and recursive dependencies) if not already present
      resolve_dependencies_recursive(name, custom_deps)

      -- 3. Update the .classpath (now guaranteed to exist for custom exts).
      --    Generated .classpath already has DIRECT /DEP entries; update_classpath
      --    injects remaining TRANSITIVE deps, skipping any path="/DEP" already
      --    present, so no duplicates.
      update_classpath(name, custom_deps)

      -- 4. Import the lib/ folder: ensure every jar physically in lib/ (and the web
      --    WEB-INF/lib dirs) is on the .classpath so third-party jars resolve.
      ensure_lib_entries(name)
    end
  end

  -- 3. PASS 2: Fill gaps using localextensions.xml
  -- This catches platform extensions or standard modules (like smartedit, solr) 
  -- that are enabled but live outside /custom/.
  resolve_dependencies_recursive("platform", {}) 

  local logical_config = CONF.HYBRIS_ROOT .. "/config"
  local resolved_config = vim.fn.resolve(logical_config)
  local local_ext_path = resolved_config .. "/localextensions.xml"

  local content = read_file_content(local_ext_path)
  if content then
    content = content:gsub("<!%-%-(.-)%-%->", "")
    for ext_name in content:gmatch('<extension[^>]-name=["\']([^"\']+)["\']') do
      -- If the custom extension loop (Pass 1) already added this,
      -- STATE.processed_exts will prevent duplicates efficiently.
      resolve_dependencies_recursive(ext_name, {})
    end
  end
  -- NOTE: maven dependency completeness is NOT auto-checked here -- doing so would
  -- either nag on every startup (deps mvn can't fix when mvn is absent) or block the
  -- import on network calls. Run :HybrisMavenDeps explicitly to check/resolve.
end

-- =============================================================================
-- 6. SETUP
-- =============================================================================

-- Size jdtls to THIS machine (the user runs macOS + CachyOS boxes of different
-- RAM/core counts). Memoised once per session.
--   heap  = ~35% of total RAM, clamped to [4,16] GB. JDT needs >=4G on a Hybris
--           workspace (4G OOMs, jdtls #1469); >16G shows diminishing returns and
--           wastes RAM. -Xms256m means it GROWS lazily, so the ceiling is only hit
--           if indexing actually needs it -- nothing is reserved up front.
--   builds = maxConcurrentBuilds. JDT INDEXING is single-threaded/IO-bound (can't
--           be parallelised, jdtls #3421), but the multi-project BUILD is; use
--           cores-1 (leave one for the UI), capped at 8 (RAM per build).
-- Env overrides for per-machine tuning: NVIM_JDTLS_XMX_GB, NVIM_JDTLS_GC (g1|zgc|parallel).
local _resources
local function compute_resources()
  if _resources then return _resources end
  local uv = vim.uv or vim.loop
  local total_gb = math.floor((uv.get_total_memory() or 8 * 1024 ^ 3) / (1024 ^ 3))
  local cores = (uv.available_parallelism and uv.available_parallelism()) or 4

  -- ~40% of RAM, floor 4 (Hybris OOMs below that), cap 16 (diminishing returns
  -- above, and staying <=16G keeps compressed-oops -> more memory-efficient than
  -- a 32G+ heap). 16GB box -> 6g; 32GB -> 12g; 64GB -> 16g. Bump via env if you
  -- ever see the server die mid-index ("Content-Length" / OOM).
  local xmx = tonumber(vim.env.NVIM_JDTLS_XMX_GB)
  if not xmx or xmx < 1 then
    xmx = math.max(4, math.min(16, math.floor(total_gb * 0.40)))
  end

  -- GC: G1 (low pause, good for an interactive long-lived server) by default;
  -- power users on big-RAM boxes can opt into generational ZGC, or ParallelGC for
  -- pure indexing throughput.
  local gc = (vim.env.NVIM_JDTLS_GC or "g1"):lower()
  local gc_flags
  if gc == "zgc" then
    gc_flags = { "-XX:+UseZGC", "-XX:+ZGenerational" }
  elseif gc == "parallel" then
    gc_flags = { "-XX:+UseParallelGC", "-XX:GCTimeRatio=4", "-XX:AdaptiveSizePolicyWeight=90" }
  else
    -- StringDeduplication is a G1/ZGC feature; only valid with G1 here.
    gc_flags = { "-XX:+UseG1GC", "-XX:+UseStringDeduplication" }
  end

  _resources = {
    total_gb = total_gb,
    cores = cores,
    xmx_gb = xmx,
    builds = math.max(1, math.min(cores - 1, 8)),
    gc = gc,
    gc_flags = gc_flags,
  }
  return _resources
end

-- Public so `:HybrisResources` (and the user) can see what was picked per machine.
function M.resources() return compute_resources() end

-- Build the jdtls launch command array (pure; depends only on CONF, which
-- init_paths has populated). Extracted from the old M.setup so M.import freezes
-- it into the per-root cache once.
local function build_cmd()
  -- JDT shares its LIBRARY (JAR) indexes across projects + restarts when given a
  -- stable shared-index location. On a Hybris workspace the platform/module JARs
  -- are the bulk of indexing; sharing them means switching between SAP Commerce
  -- projects (and cold call-hierarchy/`<leader>ji`) does NOT re-index the same jars.
  -- (eclipse.jdt.ls #3421). Created lazily by jdtls.
  local shared_index = os.getenv("HOME") .. "/.cache/jdtls/shared-index"
  vim.fn.mkdir(shared_index, "p")

  local res = compute_resources()
  local cmd = {
    CONF.JAVA_CMD,
    "-Declipse.application=org.eclipse.jdt.ls.core.id1",
    "-Dosgi.bundles.defaultStartLevel=4",
    "-Declipse.product=org.eclipse.jdt.ls.core.product",
    -- Logging: ALL + protocol writes a torrent into the workspace .log and
    -- measurably slows a busy server. ERROR keeps it quiet. (redhat vscode-java
    -- ships -Xlog:disable by default; ALL was a real perf drag here.)
    "-Dlog.level=ERROR",
    -- Heap sized to the machine (see compute_resources). Grows lazily from -Xms.
    "-Xmx" .. res.xmx_gb .. "g",
    "-Xms256m",
    "-Dsun.zip.disableMemoryMapping=true",
    -- Reuse a cross-project JDT library index (see comment above).
    "-Djdt.core.sharedIndexLocation=" .. shared_index,
    "-Djava.import.generatesMetadataFilesAtProjectRoot=false",
  }
  -- GC flags chosen per machine / NVIM_JDTLS_GC.
  for _, f in ipairs(res.gc_flags) do table.insert(cmd, f) end

  local lombok_jar = utils.get_lombok_jar(CONF.JDTLS_JAR and vim.fn.fnamemodify(CONF.JDTLS_JAR, ":h:h"))
  if lombok_jar then
    table.insert(cmd, "-javaagent:" .. lombok_jar)
  end

  table.insert(cmd, "--add-modules=ALL-SYSTEM")
  table.insert(cmd, "--add-opens")
  table.insert(cmd, "java.base/java.util=ALL-UNNAMED")
  table.insert(cmd, "--add-opens")
  table.insert(cmd, "java.base/java.lang=ALL-UNNAMED")
  table.insert(cmd, "-jar")
  table.insert(cmd, CONF.JDTLS_JAR)
  table.insert(cmd, "-configuration")
  table.insert(cmd, CONF.CONFIG_PATH)
  table.insert(cmd, "-data")
  table.insert(cmd, CONF.WORKSPACE_DATA)
  return cmd
end

-- HEAVY, AT MOST ONCE PER ROOT. Resolves CONF, runs prepare_workspace() (fd scan,
-- metadata synthesis, .classpath injection), builds the cmd, and freezes
-- cmd + workspace_folders into IMPORTED[root]. force=true bypasses the guard
-- (used by :HybrisReimport). Returns the cache table, or nil on invalid root.
function M.import(detected_root, force)
  -- Resolve the authoritative root. init_paths is a one-shot (early-returns once
  -- CONF.HYBRIS_ROOT is set), so we key the guard off the freshly-resolved root.
  local root = detected_root
  if not root then
    local _, r = utils.detect_project()
    root = r
  end
  if root then
    root = vim.fn.fnamemodify(root, ":p"):gsub("/+$", "")
  end

  if root and not force then
    local cached = IMPORTED[root]
    if type(cached) == "table" then
      return cached            -- already imported this session
    end
    if cached == "pending" then
      return nil               -- another buffer is importing it right now
    end
  end

  if root then IMPORTED[root] = "pending" end

  -- init_paths runs its body once per session (CONF guard). On force or a genuinely
  -- different root, reset CONF + REAL_CUSTOM_PATH so paths re-resolve for the new tree.
  if force or (CONF.HYBRIS_ROOT and root and CONF.HYBRIS_ROOT ~= root) then
    CONF = {}
    REAL_CUSTOM_PATH = nil
  end
  init_paths(detected_root or root)

  if not CONF.HYBRIS_ROOT or vim.fn.isdirectory(CONF.HYBRIS_ROOT .. "/bin/platform") == 0 then
    vim.notify("Could not resolve a valid Hybris root directory. Ensure you are in a Hybris project.", vim.log.levels.ERROR, { title = "JDTLS Hybris Setup Error" })
    if root then IMPORTED[root] = nil end
    return nil
  end
  if not CONF.JDTLS_JAR or CONF.JDTLS_JAR == "" then
    vim.notify("JDTLS launcher JAR not found. Please install jdtls via Mason (:MasonInstall jdtls) or check your system installation.", vim.log.levels.ERROR, { title = "JDTLS Setup Error" })
    if root then IMPORTED[root] = nil end
    return nil
  end

  -- The heavy section -- prepare_workspace() (fd scan + .project/.classpath
  -- synthesis + injection, all of which call vim.fn.writefile, which RAISES on an
  -- unwritable/read-only/full-disk target) plus build_cmd()/deepcopy -- runs under
  -- pcall. Without this, a raise here would propagate out leaving IMPORTED[root]
  -- stuck at "pending" for the whole session: every later attach() then sees a
  -- non-table cache, re-enters import(), hits the pending guard, and silently
  -- no-ops -- jdtls would never start for that root. On failure we clear the
  -- sentinel (both keys) so the next FileType event simply retries.
  local ok, cache = pcall(function()
    prepare_workspace()  -- the expensive ~2s fd scan + synthesis + injection, ONCE
    return {
      cmd = build_cmd(),
      -- Snapshot resolved folders so later buffers never depend on STATE being
      -- re-populated (STATE is reset at the top of prepare_workspace).
      workspace_folders = vim.deepcopy(STATE.workspace_folders),
      root_dir = CONF.HYBRIS_ROOT,
      java_home = CONF.JAVA_HOME,
    }
  end)
  if not ok then
    if root then IMPORTED[root] = nil end
    if CONF.HYBRIS_ROOT then IMPORTED[CONF.HYBRIS_ROOT] = nil end
    vim.notify("Hybris import failed: " .. tostring(cache), vim.log.levels.ERROR, { title = "JDTLS Hybris Setup Error" })
    return nil
  end

  -- Key by BOTH the caller-resolved root and the canonical CONF root so a later
  -- detect_project returning the canonical form still hits the cache.
  IMPORTED[CONF.HYBRIS_ROOT] = cache
  if root and root ~= CONF.HYBRIS_ROOT then IMPORTED[root] = cache end
  return cache
end

-- Build the LSP client config shared by M.attach (per-buffer) and M.warm (eager,
-- buffer-less). name="jdtls" + the cached cmd + root_dir are what let vim.lsp reuse
-- ONE client: a buffer opened after M.warm attaches to the already-warming server
-- instead of cold-starting a second JVM.
local function build_lsp_config(cache)
  -- Parallelise the unavoidable initial multi-project build (indexing itself is
  -- single-threaded/IO-bound, but the build is not). Machine-sized, same source
  -- as the heap (compute_resources).
  local res = compute_resources()
  return {
    name = "jdtls",
    cmd = cache.cmd,
    root_dir = cache.root_dir,
    capabilities = utils.make_capabilities(),
    init_options = {
      -- Microsoft java-debug-adapter + java-test JARs so jdtls doubles as a debug
      -- server (nvim-dap attaches to a running Hybris JVM through it). Empty when
      -- the Mason packages aren't installed yet -- the LSP is unaffected.
      bundles = utils.get_dap_bundles(),
      extendedClientCapabilities = jdtls.extendedClientCapabilities,
      workspaceFolders = cache.workspace_folders,
    },
    settings = {
      java = {
        signatureHelp = { enabled = true },
        contentProvider = { preferred = "fernflower" },
        autobuild = { enabled = false },
        -- Parallelise the initial multi-project build.
        maxConcurrentBuilds = res.builds,
        completion = {
          guessMethodArguments = true,
          -- Cap completion results: an unlimited set is expensive in Hybris's huge
          -- symbol space (vscode-java perf guidance).
          maxResults = 50,
          filteredTypes = {
            "com.sun.*", "sun.*", "jdk.*", "org.graalvm.*", "oracle.*",
          },
        },
        -- Inlay hints recompute on every viewport change -> per-switch latency on
        -- big files. Off.
        inlayHints = { parameterNames = { enabled = "none" } },
        -- Code lenses re-query references/implementations on every render. Off.
        referencesCodeLens = { enabled = false },
        implementationsCodeLens = { enabled = false },
        import = {
          gradle = { enabled = false },
          maven = { enabled = false },
          exclusions = {
            "**/node_modules/**", "**/.git/**", "**/bower_components/**", "**/dist/**",
          },
        },
        configuration = {
          runtimes = { { name = "JavaSE-21", path = cache.java_home, default = true } },
        },
      },
    },
    on_attach = function(client, b)
      utils.setup_keymaps(b)

      -- Register the Java dap adapter for this client so you can ATTACH to a running
      -- Hybris JVM (./hybrisserver.sh debug, JDWP :8000). We deliberately do NOT call
      -- setup_dap_main_class_configs() here: resolving main classes across hundreds
      -- of Hybris extensions is an expensive LSP scan, and the Hybris flow is remote
      -- attach, not launch.
      --
      -- Only register if nvim-dap is ALREADY loaded: this on_attach also fires for
      -- Hybris .xml buffers, and we must not let opening an items.xml eagerly pull in
      -- the whole dap stack. Opening a .java file loads nvim-dap (ft=java) which runs
      -- config.dap.setup anyway, so this is idempotent insurance. We delegate to
      -- register_java (not bare setup_dap) so the main-class auto-discovery provider
      -- stays DISABLED -- a bare setup_dap() here would re-register it and bring back
      -- the expensive <leader>dc workspace scan.
      if package.loaded['dap'] then
        pcall(function() require('config.dap').register_java() end)
      end

      client.config.settings = vim.tbl_deep_extend('force', client.config.settings, {
        files = {
          exclude = {
            ["**/.git"] = true,
            ["**/node_modules"] = true,
            ["**/bower_components"] = true,
            ["**/dist"] = true,
            ["**/tmp"] = true,
            ["**/.classpath.nvim_bak"] = true,
            ["**/.nvim_gen"] = true,
          },
        },
      })
    end,
  }
end

-- =============================================================================
-- SINGLE-JDTLS REAPER. Kill an ORPHANED jdtls from a PRIOR session that still
-- holds THIS project's -data workspace (.metadata/.lock), before we start ours.
-- nvim stops jdtls cleanly on a normal :q, so orphans only arise on SIGKILL /
-- terminal-close / crash (VimLeavePre never runs) -- and a live orphan holding the
-- lock will deadlock the new server. Matched by the FULL CONF.WORKSPACE_DATA path
-- (per-project => never touches a different project). Only kills TRUE orphans
-- (PPID==1) so a deliberately co-running same-project nvim's healthy jdtls is left
-- alone. Default-ON; opt out with $NVIM_HYBRIS_NO_REAP=1. POSIX only.
-- =============================================================================
local REAPED = {}       -- data_dir -> true: reap at most once per session
local SESSION_PIDS = {} -- jdtls pids WE started this session (never reap these)

local function ppid_of(pid)
  local out = vim.fn.systemlist({ "ps", "-o", "ppid=", "-p", tostring(pid) })
  return tonumber((out[1] or ""):match("%d+"))
end

-- A process is OUR project's jdtls iff its cmdline contains org.eclipse.jdt.ls AND
-- the EXACT token `-data <data_dir>` bounded by a space/end. The bound prevents a
-- sibling project whose -data name is a PREFIX (5_2211 vs 5_2211_v2) from matching.
local function cmd_is_our_jdtls(cmd, data_dir)
  if not cmd or not cmd:find("org.eclipse.jdt.ls", 1, true) then return false end
  local needle = "-data " .. data_dir
  local _, e = cmd:find(needle, 1, true)
  if not e then return false end
  local after = cmd:sub(e + 1, e + 1)
  return after == "" or after:match("%s") ~= nil
end

local function reap_stale_jdtls(data_dir)
  if not data_dir or data_dir == "" then return end
  if vim.env.NVIM_HYBRIS_NO_REAP == "1" then return end
  if vim.fn.has("win32") == 1 then return end

  local self_pid = tostring(vim.fn.getpid())
  local mine = {}
  for _, p in ipairs(SESSION_PIDS) do mine[tostring(p)] = true end

  -- One ps scan; precise per-process cmdline match; keep ONLY true orphans (PPID==1),
  -- never our own nvim or a server we started this session.
  local victims = {}
  for _, l in ipairs(vim.fn.systemlist({ "ps", "-A", "-o", "pid=", "-o", "command=" })) do
    local pid, cmd = l:match("^%s*(%d+)%s+(.*)$")
    if pid and cmd and pid ~= self_pid and not mine[pid] and cmd_is_our_jdtls(cmd, data_dir) then
      if ppid_of(pid) == 1 then victims[#victims + 1] = tonumber(pid) end
    end
  end
  if #victims == 0 then return end

  -- 3) SIGTERM now (mirrors nvim's own stop), SIGKILL survivors after a grace window
  for _, p in ipairs(victims) do pcall(vim.uv.kill, p, 15) end
  vim.defer_fn(function()
    for _, p in ipairs(victims) do
      local ok, alive = pcall(vim.uv.kill, p, 0)
      if ok and alive == 0 then pcall(vim.uv.kill, p, 9) end
    end
  end, 1500)
  vim.notify(("Hybris: reaped %d orphaned jdtls holding this project workspace"):format(#victims),
    vim.log.levels.INFO)
end

-- Record the pid of a client we just started so the reaper never targets it.
local function record_session_pid(client_id)
  if not client_id then return end
  local c = vim.lsp.get_client_by_id(client_id)
  local pid = c and c.rpc and c.rpc.pid
  if pid then table.insert(SESSION_PIDS, pid) end
end

-- Reap once per workspace, strictly BEFORE we start our own server (so the orphan
-- releases the .metadata/.lock first).
local function reap_once(data_dir)
  if data_dir and not REAPED[data_dir] then
    REAPED[data_dir] = true
    reap_stale_jdtls(data_dir)
  end
end

-- Exposed for testing / a manual cleanup; pass an explicit -data dir.
M.reap_stale_jdtls = reap_stale_jdtls

-- True if a jdtls client is already running for `root_dir`.
local function client_for_root(root_dir)
  for _, c in ipairs(vim.lsp.get_clients({ name = "jdtls" })) do
    if c.config.root_dir == root_dir then return c end
  end
  return nil
end

-- CHEAP, PER BUFFER. Attaches `bufnr` to the (already-running or to-be-started)
-- jdtls client for `root` using the cached cmd + workspace_folders. Does NO
-- scanning. vim.lsp.start (inside jdtls.start_or_attach) dedupes by
-- {name, root_dir}: the first call starts the server, every later call just
-- attaches the buffer. Safe to call on every FileType event.
function M.attach(bufnr, root)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if root then
    root = vim.fn.fnamemodify(root, ":p"):gsub("/+$", "")
  end
  local cache = root and IMPORTED[root]
  if type(cache) ~= "table" then
    -- Not imported yet, or a stale "pending" left by a failed import. A bare
    -- import() would early-return nil on a "pending" sentinel and attach would
    -- silently never fire; force=true past a stranded "pending" so the root
    -- self-heals on the next buffer open. (import is fully synchronous, so a
    -- "pending" value here is never a live concurrent import -- only a leftover.)
    cache = M.import(root, cache == "pending" or nil)
    if not cache then return end
  end

  -- Reap a prior-session orphan before starting (covers opening a java file
  -- directly, with no VimEnter warm). REAPED guard makes this a no-op after the
  -- first start this session.
  reap_once(CONF.WORKSPACE_DATA)
  local id = jdtls.start_or_attach(build_lsp_config(cache), nil, { bufnr = bufnr })
  record_session_pid(id)
end

-- EAGER, BUFFER-LESS. Boot jdtls for `root` at startup (VimEnter) with no file
-- open, so the JVM + project import + indexing run in the BACKGROUND while you
-- browse (fzf, reading). The first java file you then open reuses this warm client
-- (vim.lsp reuse by name+root_dir) and attaches near-instantly. vim.lsp.start with
-- {attach=false} starts a client without attaching any buffer. Returns the client
-- id, or nil if the root is invalid.
function M.warm(root)
  local cache = M.import(root)
  if not cache then return nil end
  local existing = client_for_root(cache.root_dir)
  if existing then return existing.id end   -- already warm/running
  -- Reap a prior-session orphan BEFORE starting ours so it frees the workspace lock.
  reap_once(CONF.WORKSPACE_DATA)
  local id = vim.lsp.start(build_lsp_config(cache), { attach = false })
  record_session_pid(id)
  return id
end

-- Back-compat shim: the old single entry point. Now thin -- import (guarded) then
-- attach the current buffer. Existing callers (tests, manual :lua) keep working.
function M.setup(detected_root)
  M.import(detected_root)
  M.attach(vim.api.nvim_get_current_buf(), detected_root)
end

-- Force a fresh import (e.g. after editing extensioninfo.xml / localextensions.xml).
-- Clears the guard, re-scans, re-attaches the current buffer. The running jdtls
-- client keeps its old workspaceFolders until restarted (LSP sends them at init).
function M.reimport(detected_root)
  local cache = M.import(detected_root, true)
  if cache then
    vim.notify("Hybris workspace re-imported (" .. #cache.workspace_folders .. " folders). Restart jdtls (:LspRestart) to apply new folders.", vim.log.levels.INFO)
    M.attach(vim.api.nvim_get_current_buf(), cache.root_dir)
  end
end

-- Check (and, when a real mvn exists, resolve) external-dependencies.xml into lib/
-- for every CUSTOM maven-managed extension, across the four Hybris dep-file
-- locations (root + war web modules). opts.fix=false never spawns mvn (report-only);
-- opts.quiet suppresses the success notification (used by the import-time auto-check).
function M.maven_deps(opts)
  opts = opts or {}
  init_paths()
  if vim.tbl_isempty(STATE.name_to_path) then prepare_workspace() end
  local mvn = find_mvn()
  -- root dep file + the three war web-module dep-file locations.
  local sublocs = { "", "/web/webroot/WEB-INF", "/acceleratoraddon/web/webroot/WEB-INF", "/commonweb/webroot/WEB-INF" }
  local incomplete, fixed, checked = {}, 0, 0
  for name, ext_path in pairs(STATE.name_to_path) do
    if is_custom_extension(ext_path) then
      local root_is_maven = ext_uses_maven(ext_path)
      for _, sub in ipairs(sublocs) do
        -- root dep file counts only when usemaven=true (avoid false-missing on
        -- usemaven=false roots like rcclcore); web dep files are always managed.
        if sub ~= "" or root_is_maven then
          local r = check_dep_folder(ext_path .. sub)
          if r then
            checked = checked + 1
            if not r.ok then
              if mvn and opts.fix ~= false then
                local good = run_copy_dependencies(mvn, r.folder)
                if good then fixed = fixed + 1
                else incomplete[#incomplete + 1] = { name = name, folder = r.folder, missing = r.missing } end
              else
                incomplete[#incomplete + 1] = { name = name, folder = r.folder, missing = r.missing }
              end
            end
          end
        end
      end
    end
  end
  if #incomplete == 0 then
    if not opts.quiet then
      vim.notify(string.format("HybrisMavenDeps: %d dependency set(s) OK%s.", checked,
        (fixed > 0 and (", " .. fixed .. " resolved") or "")), vim.log.levels.INFO)
    end
  else
    local lines = { string.format("HybrisMavenDeps: %d incomplete:", #incomplete) }
    for _, m in ipairs(incomplete) do
      lines[#lines + 1] = "  " .. m.name .. " (" .. vim.fn.fnamemodify(m.folder, ":t") .. "): missing " .. table.concat(m.missing, ", ")
    end
    if not mvn then
      lines[#lines + 1] = "No mvn on PATH/MAVEN_HOME. Fix by either:"
      lines[#lines + 1] = "  (1) run the Hybris ant build (ant all) to populate lib/, or"
      lines[#lines + 1] = "  (2) install maven (brew/pacman install maven), then :HybrisMavenDeps."
    end
    vim.notify(table.concat(lines, "\n"), vim.log.levels.WARN)
  end
  return { checked = checked, fixed = fixed, incomplete = incomplete, mvn = mvn }
end

-- =============================================================================
-- <leader>clr -- revert the tree to its PRE-jdtls state.
--
-- Every .project/.classpath we add or touch lives in a CUSTOM extension. We undo
-- our footprint by going DIRECTLY to the real custom-extension dirs (never an
-- ignore-blind fd tree-walk, which silently missed gitignored markers and let
-- generated .project files survive -- the bug this rewrite fixes), and applying a
-- single, git-aware rule per file:
--
--   * file is git-TRACKED (committed)  -> it existed before us. NEVER delete it; if
--     we injected into it, restore the .nvim_bak (un-inject) so `git status` is clean.
--   * file is UNTRACKED                -> it is a tooling artifact (generated by us,
--     or an ant/Eclipse leftover -- a fresh checkout has none, .classpath is even
--     gitignored). DELETE it for a pristine tree.
--
-- Candidate dirs come from three deduped sources so nothing is missed: the IMPORTED
-- workspace folders, a fresh ignore-safe extensioninfo.xml scan of bin/custom, and a
-- defense-in-depth `fd -I` (no-ignore) sweep for our markers/backups. Scoped to
-- custom only -- platform/module .project/.classpath are SAP's and never touched.
-- =============================================================================
function M.restore_backups()
  -- Roots touched this session (IMPORTED), or a freshly-resolved one for a cold
  -- <leader>clr. Keyed by resolved root.
  local roots, seen_root = {}, {}
  for root, cache in pairs(IMPORTED) do
    if type(cache) == "table" and not seen_root[root] then
      seen_root[root] = true
      table.insert(roots, root)
    end
  end
  if #roots == 0 then
    local _, dr = utils.detect_project()
    local r = utils.get_platform_root() or dr
    if r then table.insert(roots, r) end
  end

  local valid_roots = {}
  for _, r in ipairs(roots) do
    if vim.fn.isdirectory(r .. "/bin/platform") == 1 then table.insert(valid_roots, r) end
  end
  if #valid_roots == 0 then
    vim.notify("Could not resolve Hybris root directory. Ensure you are in a Hybris project.", vim.log.levels.ERROR)
    return
  end

  local function resolved(p) return (vim.fn.resolve(p):gsub("/+$", "")) end

  -- git-tracked .project/.classpath, resolved-absolute, memoised per repo toplevel.
  -- Returns (set, ok). ok=false means git could NOT be queried (git absent, or
  -- rev-parse/ls-files failed -- e.g. "dubious ownership", which the bin/custom ->
  -- external-repo symlink makes likely). On ok=false we must FAIL CLOSED: a file is
  -- only ever deleted on POSITIVE proof we created it (a .nvim_gen marker or our
  -- signature), never merely because git couldn't confirm it as tracked. `-c
  -- safe.directory=*` defuses the dubious-ownership case.
  local GIT = { "git", "-c", "safe.directory=*" }
  local tracked_cache = {}
  local function tracked_info(dir)
    if vim.fn.executable("git") == 0 then return {}, false end
    local top = vim.fn.systemlist(vim.list_extend(vim.deepcopy(GIT),
      { "-C", dir, "rev-parse", "--show-toplevel" }))
    if vim.v.shell_error ~= 0 or not top[1] or top[1] == "" then return {}, false end
    top = top[1]
    if tracked_cache[top] then return tracked_cache[top].set, tracked_cache[top].ok end
    local files = vim.fn.systemlist(vim.list_extend(vim.deepcopy(GIT),
      { "-C", top, "ls-files", "--", "*.project", "*.classpath" }))
    if vim.v.shell_error ~= 0 then
      tracked_cache[top] = { set = {}, ok = false }
      return {}, false
    end
    local set = {}
    for _, rel in ipairs(files) do
      if rel ~= "" then set[resolved(top .. "/" .. rel)] = true end
    end
    tracked_cache[top] = { set = set, ok = true }
    return set, true
  end

  -- Ignore-SAFE marker/backup sweep (fd -I bypasses .gitignore/.fdignore/global
  -- excludes; the no-ignore flag is the actual fix). Glob fallback when fd is absent.
  local function sweep(dir, pat, glob)
    if vim.fn.executable("fd") == 1 then
      local r = vim.fn.systemlist({ "fd", "-L", "-H", "-I", "-t", "f", "-a", "--", pat, dir })
      if vim.v.shell_error == 0 and #r > 0 then return r end
    end
    return vim.fn.glob(dir .. glob, true, true)
  end

  -- Basenames a sibling .nvim_gen marker records as GENERATED-from-scratch by us.
  local function generated_set(dir)
    local marker = dir .. "/.nvim_gen"
    local set = {}
    if vim.fn.filereadable(marker) == 1 then
      for _, b in ipairs(vim.fn.readfile(marker)) do set[b] = true end
    end
    return set
  end

  -- Does a file carry our generation signature? (orphan recovery when a marker was
  -- lost). Only the first lines matter (the comment sits at line 3).
  local function has_signature(path)
    if vim.fn.filereadable(path) == 0 then return false end
    for _, l in ipairs(vim.fn.readfile(path, "", 6)) do
      if l:find("generated by nvim hybris_setup", 1, true) then return true end
    end
    return false
  end

  -- Undo our footprint in ONE custom-extension dir. Decision per file, in priority
  -- order, so a file is removed ONLY on positive proof it is ours:
  --   tracked (committed)        -> never delete; un-inject .nvim_bak if present.
  --   generated (.nvim_gen lists)-> WE created it from scratch: delete it + backup.
  --   has .nvim_bak              -> WE injected into a pre-existing file: restore it
  --                                 (un-inject), preserving the original (ant/user).
  --   carries our signature      -> our generated orphan (marker lost): delete.
  --   else                       -> no evidence it is ours: LEAVE it (fail-safe; this
  --                                 is what protects committed files when git is down).
  local function clean_dir(dir, tracked, git_ok, counts)
    local gen = generated_set(dir)
    for _, base in ipairs({ ".classpath", ".project" }) do
      local f = dir .. "/" .. base
      local bak = f .. ".nvim_bak"
      local is_tracked = git_ok and tracked[resolved(f)] == true
      if is_tracked then
        if vim.fn.filereadable(bak) == 1 then
          vim.fn.rename(bak, f)
          counts.restored = counts.restored + 1
        end
      elseif gen[base] then
        if vim.fn.filereadable(f) == 1 then
          vim.fn.delete(f)
          counts.deleted = counts.deleted + 1
        end
        vim.fn.delete(bak)
      elseif vim.fn.filereadable(bak) == 1 then
        vim.fn.rename(bak, f)
        counts.restored = counts.restored + 1
      elseif has_signature(f) then
        vim.fn.delete(f)
        counts.deleted = counts.deleted + 1
        vim.fn.delete(bak)
      end
      -- else: leave it (no proof it is ours).
    end
    vim.fn.delete(dir .. "/.nvim_gen")
  end

  local counts = { restored = 0, deleted = 0 }
  local processed = {}

  for _, root in ipairs(valid_roots) do
    local custom_real = resolved(root .. "/bin/custom")
    local has_custom = vim.fn.isdirectory(custom_real) == 1
    local function under_custom(dir)
      if not has_custom then return false end
      local rd = resolved(dir)
      return rd == custom_real or rd:sub(1, #custom_real + 1) == custom_real .. "/"
    end

    local tracked, git_ok = {}, true
    if has_custom then tracked, git_ok = tracked_info(custom_real) end

    -- Collect candidate custom dirs (resolved-real, deduped).
    local candidates = {}
    local function add(dir)
      if not dir or dir == "" then return end
      local rd = resolved(dir)
      if processed[rd] then return end
      if not under_custom(rd) then return end
      processed[rd] = true
      candidates[#candidates + 1] = rd
    end

    -- (a) the exact dirs we imported (workspace folders, file:// real paths).
    for r, cache in pairs(IMPORTED) do
      if type(cache) == "table" and resolved(r) == resolved(root) then
        for _, wf in ipairs(cache.workspace_folders or {}) do
          add((wf:gsub("^file://", "")))
        end
      end
    end
    -- (b) fresh, ignore-safe scan of every custom extension (extensioninfo.xml is a
    --     tracked file, so it is never hidden by ignore rules) -- covers a cold session.
    if has_custom then
      for _, xml in ipairs(find_extensioninfo_files(custom_real)) do
        add(vim.fs.dirname(xml))
      end
    end
    -- (c) defense-in-depth: dirs that still hold one of our markers/backups but are
    --     no longer in the extension map (renamed/removed extensions).
    for _, m in ipairs(sweep(root .. "/bin", "^\\.nvim_gen$", "/**/.nvim_gen")) do
      add(vim.fs.dirname(m))
    end
    for _, b in ipairs(sweep(root .. "/bin", "\\.classpath\\.nvim_bak$", "/**/.classpath.nvim_bak")) do
      add(vim.fs.dirname(b))
    end

    for _, dir in ipairs(candidates) do
      clean_dir(dir, tracked, git_ok, counts)
    end
  end

  -- Final pass: committed .project/.classpath can be left DIRTY even after the above:
  --   * the JDT server injects a <filteredResources> block (tagged
  --     __CREATED_BY_JAVA_LANGUAGE_SERVER__) into .project on import, and
  --   * our read/modify/write (and the un-inject restore) normalises the trailing
  --     newline of a .classpath the file may not have had.
  -- clean_dir never deletes a committed file, so these linger in `git status` -- the
  -- exact leftover the user wants gone. Restore them to HEAD with `git checkout`, but
  -- ONLY when the file is one we are responsible for: it sits in a custom-extension
  -- dir WE processed this run, or it carries the jdtls signature. That keeps a
  -- committed file in an extension we never touched (or a genuine hand-edit elsewhere)
  -- safe. Runs once per repo toplevel we already queried (tracked_cache).
  for top, info in pairs(tracked_cache) do
    if info.ok then
      local dirty = vim.fn.systemlist(vim.list_extend(vim.deepcopy(GIT),
        { "-C", top, "diff", "--name-only", "--", "*.project", "*.classpath" }))
      if vim.v.shell_error == 0 then
        local revert = {}
        for _, rel in ipairs(dirty) do
          if rel ~= "" then
            local abs = top .. "/" .. rel
            local ours = processed[resolved(vim.fs.dirname(abs))] == true
            if not ours then
              local f = io.open(abs, "r")
              if f then
                local content = f:read("*a") or ""
                f:close()
                ours = content:find("__CREATED_BY_JAVA_LANGUAGE_SERVER__", 1, true) ~= nil
              end
            end
            if ours then table.insert(revert, rel) end
          end
        end
        if #revert > 0 then
          local cmd = vim.list_extend(vim.deepcopy(GIT), { "-C", top, "checkout", "--" })
          vim.list_extend(cmd, revert)
          vim.fn.system(cmd)
          if vim.v.shell_error == 0 then counts.reverted = (counts.reverted or 0) + #revert end
        end
      end
    end
  end

  local reverted = counts.reverted or 0
  if counts.restored == 0 and counts.deleted == 0 and reverted == 0 then
    vim.notify("Hybris cleanup: nothing to revert (tree already pristine).", vim.log.levels.INFO)
  else
    vim.notify(string.format(
      "Hybris cleanup: deleted %d generated, restored %d injected, reverted %d jdtls-touched committed file(s).",
      counts.deleted, counts.restored, reverted), vim.log.levels.INFO)
  end
end

return M
