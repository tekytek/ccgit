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
    print("  config <key> <value>  Set configuration")
    print("  clone <user>/<repo>   Clone a repository")
    print("  pull                  Merge remote into local (additive)")
    print("  update                Clean install (wipes local, installs remote)")
    print("  push <file>           Upload file changes")
    print("  daemon [interval]     Run 'update' periodically (foreground)")
    print("  service [interval]    Run 'daemon' in a new background tab")
end

local function request(url, method, body, headers)
    headers = headers or {}
    headers["User-Agent"] = "ComputerCraft-Git"
    headers["Accept"] = "application/vnd.github.v3+json"
    
    if config.token then
        headers["Authorization"] = "token " .. config.token
    end

    -- Quiet log for daemon
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
        -- ASYNC REQUEST for PUT/POST
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

-- Recursive function to download contents
local function downloadPath(repoContentsUrl, localPath)
    local items = request(repoContentsUrl, "GET")
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
                if not downloadPath(item.url, fs.combine(localPath, item.name)) then
                    success = false
                end
            end
        end
    end
    return success
end

local function cleanDirectory(dir, excludeList)
    local list = fs.list(dir)
    for _, file in ipairs(list) do
        local skip = false
        for _, exclude in ipairs(excludeList) do
            if file == exclude then skip = true break end
        end
        if not skip then
            fs.delete(fs.combine(dir, file))
        end
    end
end

local function moveContents(source, dest)
    local list = fs.list(source)
    for _, file in ipairs(list) do
        local srcPath = fs.combine(source, file)
        local destPath = fs.combine(dest, file)
        if fs.exists(destPath) then
            fs.delete(destPath)
        end
        fs.move(srcPath, destPath)
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
    saveConfig()
    
    local url = GITHUB_API .. repoName .. "/contents?ref=" .. branch
    print("Cloning " .. repoName .. " (" .. branch .. ")...")
    if downloadPath(url, "") then
        print("Clone complete.")
    else
        print("Clone failed (incomplete).")
    end
end

function commands.pull(args)
    local root = loadConfig(true)
    local url = GITHUB_API .. config.repo .. "/contents?ref=" .. config.branch
    print("Pulling from " .. config.repo .. " (" .. config.branch .. ")...")
    
    local currentDir = shell.dir()
    shell.setDir(root)
    if downloadPath(url, "") then
        print("Pull complete.")
    else
        print("Pull failed.")
    end
    shell.setDir(currentDir)
end

function commands.update(args)
    local root = loadConfig(true)
    local tempDir = fs.combine(root, ".git_temp_update")
    
    if fs.exists(tempDir) then
        fs.delete(tempDir)
    end
    fs.makeDir(tempDir)
    
    local url = GITHUB_API .. config.repo .. "/contents?ref=" .. config.branch
    if not config.quiet then print("Updating from " .. config.repo .. " (" .. config.branch .. ")...") end
    
    -- Download to temp
    local success = downloadPath(url, tempDir)
    
    if success then
        if not config.quiet then print("Download success. Applying update...") end
        -- Clean root
        print("DEBUG: Root="..tostring(root).." Prog="..tostring(runningProgram))
        cleanDirectory(root, { ".git_config", ".git_temp_update", "rom", fs.getName(runningProgram) })
        -- Move files
        moveContents(tempDir, root)
        -- Cleanup
        fs.delete(tempDir)
        if not config.quiet then print("Update complete.") end
    else
        if not config.quiet then print("Update failed during download. Reverting...") end
        fs.delete(tempDir)
    end
end

function commands.daemon(args)
    loadConfig(true)
    local interval = tonumber(args[1]) or 300
    config.quiet = true -- Suppress detailed logs in daemon mode
    
    -- Set Multishell Title if available
    if multishell then
        multishell.setTitle(multishell.getCurrent(), "Git Daemon")
    end
    
    print("Starting background git daemon.")
    print("Repo: " .. config.repo)
    print("Interval: " .. interval .. " seconds")
    
    while true do
        print("[" .. os.time() .. "] Checking for updates...")
        local status, err = pcall(function() commands.update({}) end)
        if not status then
            print("Update failed: " .. err)
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
