-- git.lua: Basic Git client for ComputerCraft
-- Supports: clone, pull, push, update, daemon, service, config
-- Usage: git <command> [args]

local args = { ... }
local runningProgram = shell.getRunningProgram() or "git.lua"
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

local function loadConfig(targetDir)
    local configPath = fs.combine(targetDir, ".git_config")
    if fs.exists(configPath) then
        local file = fs.open(configPath, "r")
        local data = textutils.unserialize(file.readAll())
        file.close()
        -- Return a new config table for this specific repo
        local repoConfig = {}
        for k, v in pairs(data) do repoConfig[k] = v end
        -- Fallback to global config for auth if missing locally? 
        -- For now, assume each repo config has what it needs or we use global vars.
        -- Actually, user/token might be global preferences.
        -- Let's merge global 'running' config if keys are missing?
        if config.token and not repoConfig.token then repoConfig.token = config.token end
        if config.username and not repoConfig.username then repoConfig.username = config.username end
        return repoConfig
    end
    return nil
end

local function findAllRepos(startDir)
    local repos = {}
    local queue = { startDir }
    
    -- Limit depth to avoid scanning entire drive if started at root?
    -- For now, simple BFS
    while #queue > 0 do
        local current = table.remove(queue, 1)
        if fs.exists(fs.combine(current, ".git_config")) then
            table.insert(repos, current)
        end
        
        local list = fs.list(current)
        for _, item in ipairs(list) do
            local path = fs.combine(current, item)
            if fs.isDir(path) and item ~= ".git_temp_update" and item ~= "rom" then
                 -- Don't recurse INTO a repo (nested repos are tricky/bad practice here)
                 -- but we just found one above. 
                 -- Actually, if current IS a repo, do we look inside?
                 -- Let's say yes, but usually repos are leaves.
                 table.insert(queue, path)
            end
        end
    end
    return repos
end

-- Refactor request to take a specific config
local function request(url, method, body, headers, repoConfig)
    headers = headers or {}
    headers["User-Agent"] = "ComputerCraft-Git"
    headers["Accept"] = "application/vnd.github.v3+json"
    
    local effectiveConfig = repoConfig or config
    
    if effectiveConfig.token then
        headers["Authorization"] = "token " .. effectiveConfig.token
    end

    if not config.quiet then
        print("Requesting: " .. url)
    end
    
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
        http.request(url, body, headers, method)
        while true do
            local event, rUrl, rHandle = os.pullEvent()
            if event == "http_success" and rUrl == url then
                local resBody = rHandle.readAll()
                rHandle.close()
                return textutils.unserializeJSON(resBody) or { success = true }
            elseif event == "http_failure" and rUrl == url then
                if not config.quiet then
                   print("Error: " .. (rHandle or "Request failed"))
                end
                return nil
            end
        end
    end
end

local function downloadPath(repoContentsUrl, localPath, repoConfig)
    local items = request(repoContentsUrl, "GET", nil, nil, repoConfig)
    if not items then 
        if not config.quiet then print("Failed to list contents: " .. repoContentsUrl) end
        return false
    end

    if localPath ~= "" and not fs.exists(localPath) then
        fs.makeDir(localPath)
    end

    local success = true
    for _, item in ipairs(items) do
        if item.name ~= ".git_config" then
            if item.type == "file" then
                if not config.quiet then print("Downloading " .. item.path) end
                local rawResponse = http.get(item.download_url)
                if rawResponse then
                    local filePath = fs.combine(localPath, item.name)
                    local file = fs.open(filePath, "w")
                    file.write(rawResponse.readAll())
                    file.close()
                    rawResponse.close()
                else
                    if not config.quiet then print("Failed to download " .. item.name) end
                    success = false
                end
            elseif item.type == "dir" then
                if not downloadPath(item.url, fs.combine(localPath, item.name), repoConfig) then
                    success = false
                end
            end
        end
    end
    return success
end

-- Internal update logic for a specific path
local function performUpdate(root, repoConfig)
    if not repoConfig then return false, "No config" end
    if not repoConfig.repo then return false, "No repo set" end
    
    local tempDir = fs.combine(root, ".git_temp_update")
    if fs.exists(tempDir) then fs.delete(tempDir) end
    fs.makeDir(tempDir)
    
    local url = GITHUB_API .. repoConfig.repo .. "/contents?ref=" .. (repoConfig.branch or "main")
    if not config.quiet then print("  Downloading " .. repoConfig.repo .. "...") end
    
    local success = downloadPath(url, tempDir, repoConfig)
    
    if success then
        -- Cleanup
        cleanDirectory(root, { ".git_config", ".git_temp_update", "rom", fs.getName(runningProgram) })
        moveContents(tempDir, root)
        fs.delete(tempDir)
        return true
    else
        fs.delete(tempDir)
        return false, "Download failed"
    end
end

-- Commands Update
function commands.update(args)
    -- Single repo update (current dir)
    local root = shell.dir()
    local repoConfig = loadConfig(root)
    if not repoConfig then
        print("Error: Not a git repository (no .git_config found in " .. root .. ")")
        return
    end
    
    print("Updating " .. root .. "...")
    local success, err = performUpdate(root, repoConfig)
    if success then
        print("Update complete.")
    else
        print("Update failed: " .. (err or "Unknown"))
    end
end

function commands.daemon(args)
    local interval = tonumber(args[1]) or 300
    config.quiet = true 
    
    if multishell then
        multishell.setTitle(multishell.getCurrent(), "Git Daemon")
    end
    
    print("Starting background git daemon.")
    print("Scanning for repositories in: " .. shell.dir())
    print("Interval: " .. interval .. " seconds")
    
    while true do
        print("[" .. os.time() .. "] Scanning for updates...")
        local repos = findAllRepos(shell.dir())
        
        if #repos == 0 then
             print("No repositories found.")
        else
            for _, repoRoot in ipairs(repos) do
                -- Check if this repo matches the daemon's own root OR if we are scanning subdirs
                -- Just update everything found.
                print("Checking " .. repoRoot .. "...")
                local repoConfig = loadConfig(repoRoot)
                if repoConfig then
                     local success, err = performUpdate(repoRoot, repoConfig)
                     if success then
                        if not config.quiet then print("  " .. repoRoot .. " Updated.") end
                     else
                        print("  " .. repoRoot .. " Failed: " .. (err or "Unknown"))
                     end
                end
            end
        end
        os.sleep(interval)
    end
end

function commands.service(args)
    local interval = args[1] or "300"
    
    if multishell then
        local tabId = multishell.launch({
            ["shell"] = shell,
            ["multishell"] = multishell,
        }, shell.getRunningProgram(), "daemon", interval)
        
        if tabId then
            print("Git daemon started in background tab (ID: " .. tabId .. ")")
            multishell.setTitle(tabId, "Git Daemon")
            -- Switch focus back to current tab so user stays here
            multishell.setFocus(multishell.getCurrent())
        else
             print("Failed to launch background tab.")
        end
    elseif shell.openTab then
        local tabId = shell.openTab(shell.getRunningProgram(), "daemon", interval)
        if tabId then
             print("Git daemon started in background tab.")
        else
             print("Failed to open tab.")
        end
    else
        print("Error: Multishell/Tab API not available.")
        print("Use 'bg git daemon " .. interval .. "' if using a custom shell supporting bg.")
    end
end

function commands.push(args)
    local root = loadConfig(true)
    if not config.token then
        print("Error: No token configured.")
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
        if string.sub(absolutePath, 1, #root) == root then
             relativePath = string.sub(absolutePath, #root + 2)
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
