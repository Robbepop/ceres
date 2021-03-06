-- Build script utilities for Ceres

ceres.compiletime = true

function log(...)
    local args = { ... }
    for k, v in pairs(args) do
        args[k] = tostring(v)
    end
    io.stderr:write("> " .. table.concat(args, " ") .. "\n")
end

-- macro support
function define(id, value)
    _G.id = function() end

    if type(value) == "function" then
        ceres.registerMacro(id, value)
    else
        ceres.registerMacro(id, function()
            return value
        end)
    end
end

ceres.registerMacro("macro_define", define)

ceres.registerMacro("include", function(path)
    local content, err = fs.readFile(path)

    if not content then
        log("Failed to run include macro: ", err)
        error(err)
    end

    return content
end)

function macro_define() end
function compiletime() end

-- hooks

local preScriptBuildHooks = {}
local postScriptBuildHooks = {}
local postMapBuildHooks = {}
local postRunHooks = {}

local function callHooks(t, ...)
    for _, v in ipairs(t) do
        local r = v.callback(...)
        if r ~= nil then
            return r
        end
    end
end

local function addHook(hookTable, hookName, callback)
    for _, v in ipairs(hookTable) do
        if v.name == hookName then
            v.callback = callback
            return
        end
    end
    table.insert(hookTable, {name = hookName, callback = callback})
end

function ceres.addPreScriptBuildHook(name, callback)
    addHook(preScriptBuildHooks, name, callback)
end

function ceres.addPostScriptBuildHook(name, callback)
    addHook(postScriptBuildHooks, name, callback)
end

function ceres.addPostMapBuildHook(name, callback)
    addHook(postMapBuildHooks, name, callback)
end

function ceres.addPostRunHook(name, callback)
    addHook(postRunHooks, name, callback)
end

-- map library

local mapMeta = {}
mapMeta.__index = mapMeta

-- Reads a file from the map and returns its contents as a string if successful
function mapMeta:readFile(path)
    local added = self.added[path]

    if added then
        if added.kind == "string" then
            return added.contents
        elseif added.kind == "file" then
            return fs.readFile(added.path)
        end
    end

    if self.kind == "mpq" then
        return self.archive:readFile(path)
    elseif self.kind == "dir" then
        return fs.readFile(self.path .. path)
    end
end

local addDirRecursive
local function addDirRecursive(self, path, basePath)
    local files, dirs = fs.readDir(path)

    for _, file in pairs(files) do
        local relativePath = file:sub(#basePath + 2)
        self:addFileDisk(relativePath, file)
    end

    for _, dir in pairs(dirs) do
        addDirRecursive(self, dir, basePath)
    end
end

function mapMeta:addDir(path)
    addDirRecursive(self, path, fs.absolutize(path))
end

-- Adds a file to the map, as a lua string
-- This doesn't modify the map in any way, it only adds the file to be written when either
-- map:writeToDir() or map:writeToMpq() is called
function mapMeta:addFileString(path, contents)
    self.added[path] = {
        kind = "string",
        contents = contents
    }
end

-- Adds a file to the map, reading the contents from another file on the disk
-- This doesn't modify the map in any way, it only adds the file to be written when either
-- map:writeToDir() or map:writeToMpq() is called
function mapMeta:addFileDisk(archivePath, filePath)
    self.added[archivePath] = {
        kind = "file",
        path = filePath
    }
end

-- Writes the map to a directory
-- Any files added to the map via map:addFileString() or map:addFileDisk() will be
-- written at this stage
function mapMeta:writeToDir(path)
    if self.kind == "dir" then
        fs.copyDir(self.path, path)
    elseif self.kind == "mpq" then
        self.archive:extractTo(path)
    end

    for _, v in ipairs(self.addedDirs) do
        fs.copyDir(v, path)
    end

    for k, v in pairs(self.added) do
        if v.kind == "string" then
            fs.writeFile(path .. k:gsub("%\\", "/"), v.contents)
        elseif v.kind == "file" then
            fs.copyFile(v.path, path .. k:gsub("%\\", "/"))
        end
    end
end

-- Writes the map to an mpq archive
-- Any files added to the map via map:addFileString() or map:addFileDisk() will be
-- written at this stage
function mapMeta:writeToMpq(path)
    local creator = mpq.create()

    if self.kind == "dir" then
        local success, errorMsg = creator:addFromDir(self.path)
        if not success then
            log("Couldn't add directory " .. self.path .. " to archive: " .. errorMsg)
        end
    elseif self.kind == "mpq" then
        local success, errorMsg = creator:addFromMpq(self.archive)
        if not success then
            log("Couldn't add files from another archive: " .. errorMsg)
        end
    end

    for _, v in ipairs(self.addedDirs) do
        creator:addFromDir(v)
    end

    for k, v in pairs(self.added) do
        if v.kind == "string" then
            creator:add(k, v.contents)
        elseif v.kind == "file" then
            local success, errorMsg = creator:addFromFile(k, v.path)
            if not success then
                log("Couldn't add file " .. k .. " to archive: " .. errorMsg)
            end
        end
    end

    return creator:write(path)
end

local objectExtensions = {
    "w3a", "w3t", "w3u", "w3b", "w3d", "w3h", "w3q"
}

function mapMeta:initObjectStorage(ext)
    local result = self:readFile("war3map." .. ext)
    local storage = objdata.newStore(ext)

    if result then
        storage:readFromString(result)
    end

    return storage
end

-- Initializes object storages for the map
function mapMeta:initObjects()
    local objects = {}
    self.objects = objects

    for _, v in pairs(objectExtensions) do
        local data = self:initObjectStorage(v)
        objects[data.typestr] = data
    end
end

function mapMeta:commitObjectStorage(storage)
    local data = storage:writeToString()
    self:addFileString("war3map." .. storage.ext, data)
end

function mapMeta:commitObjects()
    for _, v in pairs(self.objects) do
        self:commitObjectStorage(v)
    end
end

function ceres.openMap(name)
    local map = {
        added = {},
        addedDirs = {}
    }
    local mapPath = name

    if not fs.exists(mapPath) then
        return false, "map does not exist"
    end

    if fs.isDir(mapPath) then
        map.kind = "dir"

        map.path = mapPath .. "/"
    elseif fs.isFile(mapPath) then
        map.kind = "mpq"

        local archive, errorMsg = mpq.open(mapPath)

        if not archive then
            return false, errorMsg
        end

        map.archive = archive
    else
        return false, "map path is not a file or directory"
    end

    setmetatable(map, mapMeta)

    map:initObjects()

    return map
end

-- default build functionality

-- Describes the folder layout used by Ceres.
-- Can be changed on a per-project basis.
ceres.layout = {
    mapsDirectory = "maps/",
    srcDirectories = {"src/", "lib/"},
    targetDirectory = "target/"
}

-- This is the default map build procedure
-- Takes a single "build command" specifying
-- what and how to build.
function ceres.buildMap(buildCommand)
    _G.lastBuildCommand = buildCommand

    local map, mapScript
    local mapName = buildCommand.input
    local outputType = buildCommand.output

    if not (outputType == "script" or outputType == "mpq" or outputType == "dir") then
        log("ERR: Output type must be one of 'mpq', 'dir' or 'script'")
        return false
    end

    if mapName == nil and (outputType == "mpq" or outputType == "dir") then
        log("ERR: Output type " .. outputType .. " requires an input map, but none was specified")
        return false
    end

    log("Received build command");
    log("    Input: " .. tostring(mapName))
    log("    Retain map script: " .. tostring(buildCommand.retainMapScript))
    log("    Output type: " .. buildCommand.output)

    if mapName ~= nil then
        local loadedMap, errorMsg = ceres.openMap(ceres.layout.mapsDirectory .. mapName)
        if errorMsg ~= nil then
            log("ERR: Could not load map " .. mapName .. ": " .. errorMsg)
            return false
        end
        log("Loaded map " .. mapName)

        if buildCommand.retainMapScript then
            local loadedScript, errorMsg = loadedMap:readFile("war3map.lua")
            if errorMsg ~= nil then
                log("WARN: Could not extract script from map " .. mapName .. ": " .. errorMsg)
                log("WARN: Map script won't be included in the final artifact")
            else
                log("Loaded map script from " .. mapName)
                mapScript = loadedScript
            end
        end

        map = loadedMap
    end

    if map == nil then
        log("Building in script-only mode")
    end

    if mapScript == nil then
        log("Building without including original map script")
    end

    _G.currentMap = map

    mapScript = callHooks(preScriptBuildHooks, map, mapScript) or mapScript

    local script, errorMsg = ceres.compileScript {
        srcDirectories = ceres.layout.srcDirectories,
        mapScript = mapScript or ""
    }

    if errorMsg ~= nil then
        log("ERR: Map build failed:")
        log(errorMsg)
        return false
    end

    script = callHooks(postScriptBuildHooks, map, script) or script

    if map ~= nil then
        map:addFileString("war3map.lua", script)
        map:commitObjects()
    end

    callHooks(postMapBuildHooks, map)

    log("Successfuly built the map")

    local artifact = {}

    local result, errorMsg
    if outputType == "script" then
        log("Writing artifact [script] to " .. ceres.layout.targetDirectory .. "war3map.lua")
        artifact.type = "script"
        artifact.path = ceres.layout.targetDirectory .. "war3map.lua"
        artifact.content = script
        result, errorMsg = fs.writeFile(ceres.layout.targetDirectory .. "war3map.lua", script)
    elseif outputType == "mpq" then
        artifact.type = "mpq"
        artifact.path = ceres.layout.targetDirectory .. mapName
        log("Writing artifact [mpq] to " .. artifact.path)
        result, errorMsg = map:writeToMpq(artifact.path)
    elseif outputType == "dir" then
        artifact.type = "dir"
        artifact.path = ceres.layout.targetDirectory .. mapName .. ".dir/"
        log("Writing artifact [dir] to " .. artifact.path)
        result, errorMsg = map:writeToDir(artifact.path)
    end

    if errorMsg then
        log("ERR: Saving the artifact failed: " .. errorMsg)
        return false
    else
        log("Build complete!")
        return artifact
    end
end

-- arg parsing
local args = ceres.getScriptArgs()

arg = {
    exists = function(arg_name)
        for _, v in pairs(args) do
            if v == arg_name then
                return true
            end
        end
        return false
    end,
    value = function(arg_name)
        local arg_pos
        for i, v in ipairs(args) do
            if v == arg_name then
                arg_pos = i
                break
            end
        end

        if arg_pos ~= nil and #args > arg_pos then
            return args[arg_pos + 1]
        end
    end
}

-- default handler

local handlerSuppressed = false

function ceres.suppressDefaultHandler()
    handlerSuppressed = true
end

-- The default handler for "build" and "run" commands in Ceres
-- Will parse the arguments and invoke ceres.buildMap()
function ceres.defaultHandler()
    if handlerSuppressed then
        return
    end

    local mapArg = arg.value("--map") or arg.value("-m")
    local outputType = arg.value("--output") or arg.value("-o") or "mpq"
    local noKeepScript = arg.exists("--no-map-script") or false

    for _, v in pairs(ceres.layout.srcDirectories) do
        package.path = package.path .. ";./" .. v .. "/?.lua"
    end

    local artifact = ceres.buildMap {
        input = mapArg,
        output = outputType,
        retainMapScript = not noKeepScript
    }

    if ceres.runMode() == "run" then
        if not artifact or artifact.type == "script" then
            log("WARN: Runmap was requested, but the current build did not produce a runnable artifact...")
        elseif ceres.runConfig == nil then
            log("WARN: Runmap was requested, but ceres.runConfig is nil!")
        else
            log("Runmap was requested, running the map...")
            ceres.runMap(artifact.path)
        end
    end
end

function ceres.runMap(path)
    local _, errorMsg = ceres.runWarcraft(path, ceres.runConfig)
    if errorMsg ~= nil then
        log("WARN: Running the map failed.")
        log(errorMsg)
        return
    end

    callHooks(postRunHooks)
end