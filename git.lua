-- git.lua: Basic Git client for ComputerCraft
-- Supports: clone, pull, push, config
-- Usage: git <command> [args]

local args = { ... }
local GITHUB_API = "https://api.github.com/repos/"

-- Base64 Polyfill (for compatibility)
local b64chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local function encodeBase64(data)
    if textutils.encodeBase64 then return textutils.encodeBase64(data) end
    return ((data:gsub('.', function(x) 
        local r,b='',x:byte()
        for i=8,1,-1 do r=r..(b%2^i-b%2^(i-1)>0 and '1' or '0') end
        return r;
    end)..'0000'):gsub('%d%d%d?%d?%d?%d?', function(x)
        if (#x < 6) then return '' end
        local c=0
        for i=1,6 do c=c+(x:sub(i,i)=='1' and 2^(6-i) or 0) end
        return b64chars:sub(c+1,c+1)
    end)..({ '', '==', '=' })[#data%3+1])
end

-- Configuration logic
local config = {
    username = nil,
    token = nil,
    repo = nil,
    branch = "main"
}

local function findConfig()
    local path = shell.dir()
    while true do
        local check = fs.combine(path, ".git_config")
        if fs.exists(check) then
            return check, path
        end
        if path == "" or path == ".." then break end
        path = fs.getDir(path)
    end
    return nil, nil
end

local function loadConfig(requireRepo)
    local configPath, rootPath = findConfig()
    if configPath then
        local file = fs.open(configPath, "r")
        local data = textutils.unserialize(file.readAll())
        file.close()
        for k, v in pairs(data) do config[k] = v end
        return rootPath
    end
    if requireRepo then
        error("Not a git repository (or any of the parent directories): .git_config not found")
    end
    return shell.dir()
end

local function saveConfig()
    -- Always save to current directory if not found, or update existing?
    -- For 'clone', we create new. For 'config', we probably want to update existing if found.
    local configPath, _ = findConfig()
    if not configPath then configPath = ".git_config" end
    
    local file = fs.open(configPath, "w")
    file.write(textutils.serialize(config))
    file.close()
end

-- Helpers
local function printUsage()
    print("Usage: git <command> [args]")
    print("Commands:")
    print("  config <key> <value>  Set configuration (user, token, branch)")
    print("  clone <user>/<repo> [branch]  Clone to current directory")
    print("  pull                  Update the current repository")
    print("  push <file>           Upload file changes (requires token)")
end

local function request(url, method, body, headers)
    headers = headers or {}
    headers["User-Agent"] = "ComputerCraft-Git"
    headers["Accept"] = "application/vnd.github.v3+json"
    
    if config.token then
        headers["Authorization"] = "token " .. config.token
    end

    print("Requesting: " .. url)
    
    if method == "GET" then
        local response = http.get(url, headers)
        if response then
            local resBody = response.readAll()
            response.close()
            return textutils.unserializeJSON(resBody)
        else
            return nil
        end
    else
        -- ASYNC REQUEST for PUT/POST
        http.request(url, body, headers, method)
        while true do
            local event, rUrl, rHandle = os.pullEvent()
            if event == "http_success" and rUrl == url then
                local resBody = rHandle.readAll()
                rHandle.close()
                return textutils.unserializeJSON(resBody) or { success = true }
            elseif event == "http_failure" and rUrl == url then
                print("Error: " .. (rHandle or "Request failed"))
                return nil
            end
        end
    end
end

-- Recursive function to download contents
local function downloadPath(repoContentsUrl, localPath)
    local items = request(repoContentsUrl, "GET")
    if not items then 
        print("Failed to list contents: " .. repoContentsUrl)
        return 
    end

    if localPath ~= "" and not fs.exists(localPath) then
        fs.makeDir(localPath)
    end

    for _, item in ipairs(items) do
        -- Skip .git_config to avoid overwriting it if it exists in repo (unlikely but safe)
        if item.name ~= ".git_config" then
            if item.type == "file" then
                print("Downloading " .. item.path)
                local rawResponse = http.get(item.download_url)
                if rawResponse then
                    local filePath = fs.combine(localPath, item.name)
                    local file = fs.open(filePath, "w")
                    file.write(rawResponse.readAll())
                    file.close()
                    rawResponse.close()
                else
                    print("Failed to download " .. item.name)
                end
            elseif item.type == "dir" then
                downloadPath(item.url, fs.combine(localPath, item.name))
            end
        end
    end
end

-- Commands
local commands = {}

function commands.config(args)
    if #args < 2 then
        print("Usage: git config <key> <value>")
        return
    end
    loadConfig(false)
    config[args[1]] = args[2]
    saveConfig()
    print("Config updated: " .. args[1] .. " = " .. args[2])
end

function commands.clone(args)
    if #args < 1 then
        print("Usage: git clone <user>/<repo> [branch]")
        return
    end
    
    local repoName = args[1]
    local branch = args[2] or "main"
    
    config.repo = repoName
    config.branch = branch
    
    -- Save config initiates the repo in current dir
    saveConfig()
    
    local url = GITHUB_API .. repoName .. "/contents?ref=" .. branch
    print("Cloning " .. repoName .. " (" .. branch .. ")...")
    downloadPath(url, "")
    print("Clone complete.")
end

function commands.pull(args)
    local root = loadConfig(true)
    
    local url = GITHUB_API .. config.repo .. "/contents?ref=" .. config.branch
    print("Pulling from " .. config.repo .. " (" .. config.branch .. ")...")
    -- Pull always downloads to the root of the repo
    -- We need to change dir to root or handle paths effectively?
    -- downloadPath works with relative paths.
    -- If we are in a subdir, and we run pull, we want to update everything relative to root.
    -- The simplest way is to fetch everything and write it relative to root.
    
    -- But wait, downloadPath(url, "") writes to shell.dir() + "".
    -- We want to write to 'root' path.
    -- We should temporarily change directory or adjust downloadPath.
    
    local currentDir = shell.dir()
    shell.setDir(root)
    downloadPath(url, "")
    shell.setDir(currentDir)
    
    print("Pull complete.")
end

function commands.push(args)
    local root = loadConfig(true)
    if not config.token then
        print("Error: No token configured. Run 'git config token <token>'")
        return
    end
    
    local fileToPush = args[1]
    if not fileToPush then
        print("Usage: git push <filename>")
        return
    end
    
    local absolutePath = fs.combine(shell.dir(), fileToPush)
    if not fs.exists(absolutePath) then
        print("File not found: " .. fileToPush)
        return
    end
    
    -- Calculate repo-relative path
    local relativePath = absolutePath
    if root ~= "" then
        -- Remove root prefix
        -- root is like "disk/gitrepo", abs is "disk/gitrepo/subdir/file"
        -- relative should be "subdir/file"
        if string.sub(absolutePath, 1, #root) == root then
             relativePath = string.sub(absolutePath, #root + 2) -- +2 for slash
        end
    end
    
    print("Pushing " .. relativePath .. "...")
    
    local file = fs.open(absolutePath, "r")
    local content = file.readAll()
    file.close()
    
    -- Get SHA
    local fileUrl = GITHUB_API .. config.repo .. "/contents/" .. relativePath .. "?ref=" .. config.branch
    local existingInfo = request(fileUrl, "GET")
    
    local body = {
        message = "Update " .. relativePath .. " via ComputerCraft",
        content = encodeBase64(content),
        branch = config.branch
    }
    
    if existingInfo and existingInfo.sha then
        body.sha = existingInfo.sha
    end
    
    local jsonBody = textutils.serializeJSON(body)
    local result = request(fileUrl, "PUT", jsonBody)
    
    if result then
        print("Successfully pushed " .. relativePath)
    else
        print("Failed to push.")
    end
end

-- Main
if #args == 0 then
    printUsage()
    return
end

local cmd = args[1]
local cmdArgs = {}
for i = 2, #args do
    table.insert(cmdArgs, args[i])
end

if commands[cmd] then
    local status, err = pcall(function() commands[cmd](cmdArgs) end)
    if not status then
        print("Error: " .. err)
    end
else
    print("Unknown command: " .. cmd)
    printUsage()
end
