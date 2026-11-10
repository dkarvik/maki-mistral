local librarian_ok, librarian = pcall(require, "librarian.init")
local ToolView = require("maki.tool_view")
local truncate = require("maki.truncate")
local MISTRAL_BASE = "https://api.mistral.ai/v1"
local DEFAULT_MODEL = "mistral-medium-latest"

local function credentials()
  local state_dir = maki.env.state_dir()
  if not state_dir then return nil, "could not determine Maki state directory" end
  local text, err = maki.fs.read(maki.fs.joinpath(state_dir, "auth", "mistral.json"))
  if not text then return nil, "could not read Mistral authentication: " .. err end
  local auth, decode_err = maki.json.decode(text)
  if not auth or not auth.api_key then
    return nil, "Mistral authentication is unavailable: " .. (decode_err or "missing api_key")
  end
  return auth
end

local function describe_http_error(status, body)
  local decoded = maki.json.decode(body or "")
  if type(decoded) == "table" then
    local message = decoded.message or decoded.detail
    if type(message) == "table" then
      local parts = {}
      for _, item in ipairs(message) do
        if type(item) == "table" then
          local loc = type(item.loc) == "table" and table.concat(item.loc, ".") or ""
          parts[#parts + 1] = (loc ~= "" and (loc .. ": ") or "") .. tostring(item.msg or item.type or "invalid request")
        end
      end
      message = #parts > 0 and table.concat(parts, "; ") or nil
    end
    if type(message) == "string" and message ~= "" then
      local kind = type(decoded.type) == "string" and (decoded.type .. ": ") or ""
      return "Mistral request failed (HTTP " .. status .. "): " .. kind .. message
    end
  end
  return "Mistral request failed (HTTP " .. status .. ")"
end

local function post(path, payload, timeout)
  local auth, auth_err = credentials()
  if not auth then return nil, auth_err end
  local encoded, encode_err = maki.json.encode(payload)
  if not encoded then return nil, encode_err end
  local response, err = maki.net.request(MISTRAL_BASE .. path, {
    method = "POST",
    timeout = timeout or 120,
    headers = {
      ["Authorization"] = "Bearer " .. auth.api_key,
      ["content-type"] = "application/json",
      ["accept"] = "application/json",
    },
    body = encoded,
  })
  if not response then return nil, err end
  if response.status < 200 or response.status >= 300 then
    return nil, describe_http_error(response.status, response.body)
  end
  local decoded, decode_err = maki.json.decode(response.body)
  if not decoded then return nil, "could not parse Mistral response: " .. tostring(decode_err) end
  return decoded
end

local function http_download(url, with_auth)
  local headers = {}
  if with_auth then
    local auth, auth_err = credentials()
    if not auth then return nil, auth_err end
    headers["Authorization"] = "Bearer " .. auth.api_key
  end
  local response, err = maki.net.request(url, {
    headers = headers,
    timeout = 110,
    max_bytes = 512 * 1024 * 1024,
  })
  if not response then return nil, err end
  if response.status < 200 or response.status >= 300 then
    return nil, "download failed (HTTP " .. tostring(response.status) .. ")"
  end
  return response.body
end

local function compact(value, maximum)
  if type(value) ~= "string" then return nil end
  value = value:gsub("%s+", " "):match("^%s*(.-)%s*$")
  if #value <= maximum then return value end
  return value:sub(1, maximum - 1) .. "…"
end

local function web_view_opts(ctx)
  local lines = ctx:tool_output_lines()
  return { max_lines = (lines and lines.web) or 3, keep = "head" }
end

local function mistral_search_header(input)
  local queries = type(input) == "table" and input.queries or nil
  if type(queries) ~= "table" or #queries == 0 then return "web search" end
  if #queries == 1 and type(queries[1]) == "string" and queries[1] ~= "" then return queries[1] end
  return tostring(#queries) .. " web searches"
end

local function query_label(query)
  return compact(query, 240) or "web search"
end

local function append_sources(lines, heading, sources, include_snippets)
  if #sources == 0 then return end
  lines[#lines + 1] = ""
  lines[#lines + 1] = heading
  for index, source in ipairs(sources) do
    lines[#lines + 1] = tostring(index) .. ". " .. source.title
    lines[#lines + 1] = "   " .. source.url
    if include_snippets and source.snippet then lines[#lines + 1] = "   " .. source.snippet end
  end
end

local function output_text(output)
  local content = output.content
  if type(content) == "string" then return content end
  if type(content) ~= "table" then return "" end
  local parts = {}
  for _, chunk in ipairs(content) do
    if type(chunk) == "table" and chunk.type == "text" and type(chunk.text) == "string" then
      parts[#parts + 1] = chunk.text
    end
  end
  return table.concat(parts)
end

local function collect_sources(outputs)
  local sources, seen = {}, {}
  for _, output in ipairs(outputs or {}) do
    local content = output.content
    if type(content) == "table" then
      for _, chunk in ipairs(content) do
        if type(chunk) == "table" and chunk.type == "tool_reference" and type(chunk.url) == "string" and chunk.url ~= "" then
          if not seen[chunk.url] then
            seen[chunk.url] = true
            sources[#sources + 1] = {
              title = compact(chunk.title, 240) or chunk.url,
              url = chunk.url,
              snippet = compact(chunk.description, 360),
            }
          end
        end
      end
    end
  end
  return sources
end

local function run_search(query, tool_type, model)
  local function once(user_content)
    return post("/conversations", {
      model = model,
      store = false,
      instructions = "You are a concise web search assistant. Search the web, answer the query, and cite the sources you used.",
      inputs = { { role = "user", content = user_content } },
      tools = { { type = tool_type } },
      completion_args = { temperature = 0.2 },
    })
  end
  local function extract(result)
    local text_parts = {}
    for _, output in ipairs(result.outputs or {}) do
      local text = output_text(output)
      if text ~= "" then text_parts[#text_parts + 1] = text end
    end
    if #text_parts == 0 then return nil end
    return { text = table.concat(text_parts, "\n\n"), sources = collect_sources(result.outputs) }
  end
  local result, request_err = once(query)
  if not result then return nil, request_err end
  local extracted = extract(result)
  if extracted then return extracted end
  local retry = once("Use the web search tool to search the web for this query, then answer concisely with citations: " .. query)
  if retry then
    local retry_extracted = extract(retry)
    if retry_extracted then return retry_extracted end
  end
  return nil, "Mistral returned no search answer"
end

maki.api.register_tool({
  name = "mistral_search",
  kind = "web",
  description = "Search the web using the Mistral API (Vibe subscription). Returns a concise answer plus numbered sources.",
  schema = {
    type = "object",
    properties = {
      queries = { type = "array", items = { type = "string" }, description = "One or more web-search queries." },
      premium = { type = "boolean", description = "Use web_search_premium (search engine plus verified news sources). Defaults to false." },
      model = { type = "string", description = "Optional Mistral model; defaults to mistral-medium-latest." },
    },
    required = { "queries" },
  },
  timeout = 120,
  header = mistral_search_header,
  restore = function(_input, output, _is_error, ctx)
    return ToolView.restore(output, web_view_opts(ctx))
  end,
  handler = function(input, ctx)
    if type(input.queries) ~= "table" or #input.queries == 0 then
      return { llm_output = "error: queries is required", is_error = true }
    end
    if #input.queries > 5 then
      return { llm_output = "error: at most 5 queries are allowed", is_error = true }
    end
    for index, query in ipairs(input.queries) do
      if type(query) ~= "string" or query:match("^%s*$") then
        return { llm_output = "error: query " .. tostring(index) .. " must be a nonempty string", is_error = true }
      end
    end

    local tool_type = input.premium and "web_search_premium" or "web_search"
    local model = input.model or DEFAULT_MODEL
    local sections, failures = {}, 0
    for _, query in ipairs(input.queries) do
      local result, result_err = run_search(query, tool_type, model)
      if not result then
        failures = failures + 1
        sections[#sections + 1] = "Search failed: " .. query_label(query) .. "\nerror: " .. tostring(result_err)
      else
        local lines = { result.text }
        append_sources(lines, "Sources:", result.sources, true)
        local heading = #input.queries > 1 and ("Search: " .. query_label(query) .. "\n\n") or ""
        sections[#sections + 1] = heading .. table.concat(lines, "\n")
      end
    end

    local output = table.concat(sections, "\n\n")
    if failures == #input.queries then return { llm_output = "error: " .. output, is_error = true } end
    local max_lines = tonumber(ctx:config("max_output_lines", 2000)) or 2000
    local max_bytes = tonumber(ctx:config("max_output_bytes", 50 * 1024)) or 50 * 1024
    return {
      llm_output = truncate(output, max_lines, max_bytes),
      body = ToolView.restore(output, web_view_opts(ctx)),
    }
  end,
})

if librarian_ok then librarian.register_extension("mistral_search") end

local function image_header(input)
  return compact(type(input) == "table" and input.prompt or nil, 240) or "generate image"
end

local function image_format_info(bytes)
  local ok, info, err = pcall(maki.image.probe, bytes)
  if not ok then return nil, "could not inspect generated image: " .. tostring(info) end
  if not info then return nil, "generated payload is not a recognized image: " .. tostring(err) end
  local format = type(info.format) == "string" and info.format:lower() or nil
  local media_types = { png = "image/png", jpeg = "image/jpeg", jpg = "image/jpeg", webp = "image/webp", gif = "image/gif" }
  local extensions = { png = "png", jpeg = "jpg", jpg = "jpg", webp = "webp", gif = "gif" }
  if not media_types[format] then return nil, "generated payload has unsupported image format: " .. tostring(info.format) end
  return { format = format, media_type = media_types[format], extension = extensions[format], width = info.width, height = info.height }
end

local function input_image_type(bytes)
  local info, err = image_format_info(bytes)
  if not info then return nil, err end
  return info.media_type
end

local function ensure_directory(path)
  local meta, metadata_err = maki.fs.metadata(path)
  if metadata_err then return nil, "could not stat output directory: " .. metadata_err end
  if meta then
    if not meta.is_dir then return nil, "output path is not a directory: " .. path end
    return true
  end
  local ok, mkdir_err = maki.fs.mkdir(path, { parents = true })
  if not ok then return nil, "could not create output directory: " .. mkdir_err end
  return true
end

local function image_directory()
  return maki.fs.joinpath(maki.env.state_dir(), "generated_images", "mistral")
end

local function prompt_slug(prompt)
  local slug = prompt:lower():gsub("[^%w]+", "-"):gsub("%-+", "-"):gsub("^%-+", ""):gsub("%-+$", ""):sub(1, 48):gsub("%-+$", "")
  return slug ~= "" and slug or "image"
end

local function safe_image_id(value)
  local id = tostring(value or "image"):gsub("[^%w%-%_]", "_")
  return id ~= "" and id or "image"
end

local function output_path(directory, id, extension)
  for suffix = 0, 999 do
    local name = id .. (suffix == 0 and "" or "-" .. tostring(suffix)) .. "." .. extension
    local path = maki.fs.joinpath(directory, name)
    local meta, metadata_err = maki.fs.metadata(path)
    if metadata_err then return nil, "could not stat output path: " .. metadata_err end
    if not meta then return path end
  end
  return nil, "could not choose an unused output path"
end

local function collect_tool_files(outputs)
  local files, visited = {}, {}
  local function inspect(value)
    if type(value) ~= "table" or visited[value] then return end
    visited[value] = true
    if value.type == "tool_file" and type(value.file_id) == "string" and value.file_id ~= "" then
      files[#files + 1] = value
    end
    for _, child in pairs(value) do inspect(child) end
  end
  for _, output in ipairs(outputs or {}) do inspect(output) end
  return files
end

local function collect_image_urls(outputs)
  local urls, seen = {}, {}
  for _, output in ipairs(outputs or {}) do
    local text = output_text(output)
    for url in text:gmatch("!%[[^%]]*%]%((https?://[^)%s]+)%)") do
      if not seen[url] then
        seen[url] = true
        urls[#urls + 1] = url
      end
    end
  end
  return urls
end

maki.api.register_tool({
  name = "mistral_image_generation",
  kind = "image",
  description = "Generate or edit raster images through the Mistral API (Vibe subscription). Saves the completed image under the Maki state directory (generated_images/mistral/).",
  schema = {
    type = "object",
    properties = {
      prompt = { type = "string", description = "Image generation or editing prompt." },
      images = { type = "array", items = { type = "string" }, description = "Optional local image paths to edit or use as references." },
      model = { type = "string", description = "Optional Mistral model; defaults to mistral-medium-latest." },
    },
    required = { "prompt" },
  },
  timeout = 120,
  header = image_header,
  handler = function(input)
    if type(input.prompt) ~= "string" or input.prompt:match("^%s*$") then
      return { llm_output = "error: prompt must be a nonempty string", is_error = true }
    end
    if type(input.images) == "table" and #input.images > 8 then
      return { llm_output = "error: at most 8 reference images are allowed", is_error = true }
    end

    local content = input.prompt
    if type(input.images) == "table" and #input.images > 0 then
      content = { { type = "text", text = input.prompt } }
      for _, path in ipairs(input.images) do
        if type(path) ~= "string" or path == "" then
          return { llm_output = "error: image paths must be nonempty strings", is_error = true }
        end
        local bytes, read_err = maki.fs.read_bytes(path)
        if not bytes then return { llm_output = "error: could not read image " .. path .. ": " .. read_err, is_error = true } end
        local media_type, type_err = input_image_type(bytes)
        if not media_type then return { llm_output = "error: could not use image " .. path .. ": " .. type_err, is_error = true } end
        content[#content + 1] = { type = "image_url", image_url = "data:" .. media_type .. ";base64," .. maki.base64.encode(bytes) }
      end
    end

    local result, request_err = post("/conversations", {
      model = input.model or DEFAULT_MODEL,
      store = false,
      inputs = { { role = "user", content = content } },
      tools = { { type = "image_generation" } },
    })
    if not result then return { llm_output = "error: " .. request_err, is_error = true } end

    local outputs = result.outputs or {}
    local tool_files = collect_tool_files(outputs)
    local image_urls = collect_image_urls(outputs)

    local directory = image_directory()
    local directory_ok, directory_err = ensure_directory(directory)
    if not directory_ok then return { llm_output = "error: " .. directory_err, is_error = true } end

    local origin, bytes, download_err
    if #tool_files > 0 then
      origin = "file " .. tool_files[1].file_id
      bytes, download_err = http_download(MISTRAL_BASE .. "/files/" .. tool_files[1].file_id .. "/content", true)
    elseif #image_urls > 0 then
      origin = "signed url"
      bytes, download_err = http_download(image_urls[1], false)
    else
      return { llm_output = "error: Mistral did not return an image", is_error = true }
    end
    if not bytes then return { llm_output = "error: could not download generated image: " .. tostring(download_err), is_error = true } end

    local info, info_err = image_format_info(bytes)
    if not info then return { llm_output = "error: " .. info_err, is_error = true } end

    local path, path_err = output_path(directory, safe_image_id(prompt_slug(input.prompt)), info.extension)
    if not path then return { llm_output = "error: " .. path_err, is_error = true } end
    local write_ok, write_err = maki.fs.write(path, bytes)
    if not write_ok then return { llm_output = "error: could not save image: " .. write_err, is_error = true } end

    local dimensions = info.width and info.height and (tostring(info.width) .. "×" .. tostring(info.height)) or "unknown dimensions"
    local extra_count = math.max(#tool_files, #image_urls) - 1
    local extras = extra_count > 0 and ("; " .. tostring(extra_count) .. " additional image" .. (extra_count == 1 and " was" or "s were") .. " returned but not saved") or ""
    return {
      llm_output = "Generated " .. info.media_type .. " image (" .. dimensions .. ", from " .. origin .. ") saved to: " .. path .. extras,
      written_path = path,
      image = { media_type = info.media_type, data = maki.base64.encode(bytes) },
    }
  end,
})
