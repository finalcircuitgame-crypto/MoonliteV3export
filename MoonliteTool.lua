--[[
    MOONLITE V3 CUTSCENE TOOL
    Executor-side GUI

    Features:
    - Dynamic cutscene discovery
    - RequestCutsceneChunk acquisition
    - Local packet storage
    - Moonlite V3 decoding
    - Stream window verification
    - Timeline reconstruction
    - Duplicate boundary key removal
    - Workspace output
    - SaveInstance export
]]

--==================================================
-- SERVICES AND MODULES
--==================================================

local RS = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

local Moonlite = RS.Client.Modules.MoonliteV3

local Container = require(Moonlite.Container)
local Document = require(Moonlite.Document)
local Stream = require(Moonlite.Stream)

local CutScenes = RS.Assets.CutScenes

local RequestRemote = RS.Network.CutScenes
    :WaitForChild("RF:RequestCutsceneChunk")

assert(
    RequestRemote:IsA("RemoteFunction"),
    "RequestCutsceneChunk is not a RemoteFunction"
)

--==================================================
-- EXECUTOR ENVIRONMENT
--==================================================

local function getEnvironment()
    if type(getgenv) == "function" then
        return getgenv()
    end

    return _G
end

local function getAPI(name)
    local environment = getEnvironment()
    return environment[name] or _G[name]
end

local function requireAPI(name)
    local fn = getAPI(name)

    assert(
        type(fn) == "function",
        "Missing executor API: " .. name
    )

    return fn
end

local function joinPath(a, b)
    local separator = a:find("\\", 1, true) and "\\" or "/"

    if a:sub(-1) == "/" or a:sub(-1) == "\\" then
        return a .. b
    end

    return a .. separator .. b
end

local function ensureFolder(path)
    local isfolder = requireAPI("isfolder")

    if not isfolder(path) then
        requireAPI("makefolder")(path)
    end

    assert(isfolder(path), "Could not create: " .. path)
end

local function validateFilesystem()
    for _, name in ipairs({
        "readfile",
        "writefile",
        "isfile",
        "isfolder",
        "makefolder",
    }) do
        requireAPI(name)
    end
end

--==================================================
-- DOCUMENT VALIDATION
--==================================================

local function validateDocument(document, label)
    local valid, issues = Document.Validate(document)

    if valid then
        return
    end

    local errors = {}

    for _, issue in ipairs(issues) do
        if issue.Severity == "Error" then
            table.insert(
                errors,
                string.format(
                    "%s (%s): %s",
                    tostring(issue.Code),
                    tostring(issue.Path),
                    tostring(issue.Message)
                )
            )
        end
    end

    error(
        label .. " validation failed:\n"
        .. table.concat(errors, "\n")
    )
end

--==================================================
-- PACKET STORAGE
--==================================================

local function savePacket(root, packageName, index, packet)
    local packageFolder = joinPath(root, packageName)

    local windowFolder = joinPath(
        packageFolder,
        "window_" .. string.format("%03d", index)
    )

    ensureFolder(root)
    ensureFolder(packageFolder)
    ensureFolder(windowFolder)

    local writefile = requireAPI("writefile")

    writefile(
        joinPath(windowFolder, "header.bin"),
        packet.Header
    )

    for n, value in ipairs(packet.Values) do
        writefile(
            joinPath(
                windowFolder,
                "value_" .. string.format("%04d", n) .. ".bin"
            ),
            value
        )
    end

    writefile(
        joinPath(windowFolder, "info.txt"),
        string.format(
            "Index=%d\nValues=%d\n",
            index,
            #packet.Values
        )
    )
end

--==================================================
-- MOONLITE PACKET DECODER
--==================================================

local function decodePacket(packet, manifest, index)
    assert(type(packet) == "table", "Invalid packet")

    assert(
        packet.Index == index,
        "Packet index mismatch: " .. tostring(index)
    )

    assert(
        type(packet.Header) == "string",
        "Missing packet Header"
    )

    assert(
        type(packet.Values) == "table" and #packet.Values > 0,
        "Missing packet Values"
    )

    local scene = Stream.SceneFromPacket(packet)

    local ok, result = pcall(function()
        local document = Container.Read(scene)

        Stream.AssertWindow(manifest, document)

        validateDocument(
            document,
            "Window " .. index
        )

        return document
    end)

    scene:Destroy()

    if not ok then
        error(
            string.format(
                "Window %03d failed: %s",
                index,
                tostring(result)
            )
        )
    end

    return result
end

--==================================================
-- CUTSCENE ACQUISITION
--==================================================

local function acquireCutscene(package, manifest, captureRoot, log)
    local streamId = package:GetAttribute("MoonliteStreamId")

    local windowCount =
        package:GetAttribute("MoonliteStreamWindowCount")

    assert(
        type(streamId) == "string" and streamId ~= "",
        "Missing MoonliteStreamId"
    )

    assert(
        type(windowCount) == "number"
            and windowCount > 0
            and windowCount % 1 == 0,
        "Invalid MoonliteStreamWindowCount"
    )

    local windowFrames, manifestCount =
        Stream.Layout(manifest)

    assert(
        windowFrames and manifestCount,
        "Invalid stream manifest"
    )

    assert(
        windowCount == manifestCount,
        string.format(
            "Attribute count (%d) differs from manifest count (%d)",
            windowCount,
            manifestCount
        )
    )

    local windows = table.create(windowCount)

    ensureFolder(captureRoot)
    ensureFolder(joinPath(captureRoot, package.Name))

    for i = 1, windowCount do
        log(string.format(
            "Processing window %d/%d",
            i,
            windowCount
        ))

        local callOK, success, packet = pcall(function()
            return RequestRemote:InvokeServer(
                package.Name,
                streamId,
                i
            )
        end)

        assert(
            callOK,
            "Request failed: " .. tostring(success)
        )

        assert(
            success == true,
            "Server rejected window " .. i .. ": " .. tostring(packet)
        )

        assert(
            type(packet) == "table",
            "Invalid response packet"
        )

        assert(
            packet.Index == i,
            "Unexpected packet index"
        )

        assert(
            type(packet.Header) == "string",
            "Invalid packet header"
        )

        assert(
            type(packet.Values) == "table",
            "Invalid packet values"
        )

        -- Persist the original packet.
        savePacket(
            captureRoot,
            package.Name,
            i,
            packet
        )

        -- Decode and verify.
        windows[i] = decodePacket(
            packet,
            manifest,
            i
        )

        log(string.format(
            "Window %03d saved and verified.",
            i
        ))

        task.wait(1)
    end

    requireAPI("writefile")(
        joinPath(
            joinPath(captureRoot, package.Name),
            "COMPLETE.txt"
        ),
        string.format(
            "Status=COMPLETE\nWindows=%d\n",
            windowCount
        )
    )

    return windows
end

--==================================================
-- EXISTING CAPTURE IMPORT
--==================================================

local function importExisting(package, manifest, captureRoot, log)
    local _, windowCount = Stream.Layout(manifest)

    local readfile = requireAPI("readfile")
    local isfile = requireAPI("isfile")
    local isfolder = requireAPI("isfolder")

    local windows = table.create(windowCount)

    for i = 1, windowCount do
        local folder = joinPath(
            joinPath(captureRoot, package.Name),
            "window_" .. string.format("%03d", i)
        )

        assert(
            isfolder(folder),
            "Missing capture folder: " .. folder
        )

        local headerPath = joinPath(folder, "header.bin")
        local infoPath = joinPath(folder, "info.txt")

        assert(isfile(headerPath), "Missing header.bin")
        assert(isfile(infoPath), "Missing info.txt")

        local header = readfile(headerPath)
        local info = readfile(infoPath)

        local count = tonumber(
            info:match("Values=(%d+)")
        )

        assert(
            count and count > 0,
            "Invalid Values count in " .. infoPath
        )

        local values = table.create(count)

        for n = 1, count do
            local path = joinPath(
                folder,
                "value_" .. string.format("%04d", n) .. ".bin"
            )

            assert(isfile(path), "Missing " .. path)

            values[n] = readfile(path)
        end

        windows[i] = decodePacket({
            Index = i,
            Header = header,
            Values = values,
        }, manifest, i)

        log("Imported window " .. i)
    end

    return windows
end

--==================================================
-- DUPLICATE KEY COMPARISON
--==================================================

local function deepEqual(a, b, seen)
    if typeof(a) ~= typeof(b) then
        return false
    end

    if type(a) ~= "table" then
        return a == b
    end

    seen = seen or {}

    if seen[a] ~= nil then
        return seen[a] == b
    end

    seen[a] = b

    for key, value in pairs(a) do
        if not deepEqual(value, b[key], seen) then
            return false
        end
    end

    for key in pairs(b) do
        if a[key] == nil then
            return false
        end
    end

    return true
end

--==================================================
-- STREAM MERGER
--==================================================

local function mergeWindows(manifest, windows)
    local windowFrames, windowCount =
        Stream.Layout(manifest)

    assert(windowFrames and windowCount, "Invalid stream layout")
    assert(#windows == windowCount, "Window count mismatch")

    local merged = Document.Clone(manifest)

    local totalKeys = 0
    local duplicateKeys = 0

    for trackIndex, targetTrack in ipairs(merged.Tracks) do
        if targetTrack.Kind ~= "Action" then
            local byFrame = {}

            local function addKey(key, source)
                local existing = byFrame[key.Frame]

                if existing then
                    assert(
                        deepEqual(existing, key),
                        string.format(
                            "Conflicting key: track %s, frame %s, source %s",
                            tostring(targetTrack.Id),
                            tostring(key.Frame),
                            tostring(source)
                        )
                    )

                    duplicateKeys += 1
                else
                    byFrame[key.Frame] = Document.Clone(key)
                end
            end

            -- Preserve any manifest keys.
            for _, key in ipairs(targetTrack.Keys) do
                addKey(key, "manifest")
            end

            -- Collect all window keys.
            for windowIndex, window in ipairs(windows) do
                local sourceTrack = window.Tracks[trackIndex]

                assert(
                    sourceTrack
                        and sourceTrack.Id == targetTrack.Id,
                    "Track mismatch in window " .. windowIndex
                )

                for _, key in ipairs(sourceTrack.Keys) do
                    addKey(key, windowIndex)
                end
            end

            -- Restore chronological order.
            local frames = {}

            for frame in pairs(byFrame) do
                table.insert(frames, frame)
            end

            table.sort(frames)

            targetTrack.Keys = {}

            for _, frame in ipairs(frames) do
                table.insert(
                    targetTrack.Keys,
                    byFrame[frame]
                )
            end
        end

        totalKeys += #targetTrack.Keys
    end

    -- This is now a complete document.
    merged.Metadata.Stream = nil

    validateDocument(merged, "Merged document")

    return merged, {
        WindowFrames = windowFrames,
        WindowCount = windowCount,
        TotalKeys = totalKeys,
        DuplicateKeys = duplicateKeys,
    }
end

--==================================================
-- GUI
--==================================================

local gui = Instance.new("ScreenGui")
gui.Name = "MoonliteCutsceneTool"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

local main = Instance.new("Frame")
main.Size = UDim2.fromOffset(550, 535)
main.Position = UDim2.new(0.5, -275, 0.5, -267)
main.BackgroundColor3 = Color3.fromRGB(25, 28, 35)
main.BorderSizePixel = 0
main.Parent = gui

Instance.new("UICorner", main).CornerRadius =
    UDim.new(0, 10)

local function makeLabel(text, y, height, size, bold)
    local label = Instance.new("TextLabel")

    label.Size = UDim2.new(1, -24, 0, height)
    label.Position = UDim2.fromOffset(12, y)

    label.BackgroundTransparency = 1
    label.Text = text
    label.TextColor3 = Color3.fromRGB(235, 238, 245)

    label.TextXAlignment = Enum.TextXAlignment.Left
    label.TextYAlignment = Enum.TextYAlignment.Center

    label.Font = bold
        and Enum.Font.GothamBold
        or Enum.Font.Gotham

    label.TextSize = size or 12
    label.Parent = main

    return label
end

local function makeButton(text, position, size, color)
    local button = Instance.new("TextButton")

    button.Position = position
    button.Size = size

    button.BackgroundColor3 = color
    button.TextColor3 = Color3.new(1, 1, 1)

    button.Text = text
    button.Font = Enum.Font.GothamBold
    button.TextSize = 12

    button.Parent = main

    Instance.new("UICorner", button).CornerRadius =
        UDim.new(0, 6)

    return button
end

makeLabel(
    "MOONLITE V3 CUTSCENE TOOL",
    10,
    28,
    16,
    true
)

local selectedLabel = makeLabel(
    "Selected: None",
    40,
    22,
    12,
    true
)

local status = makeLabel(
    "Ready.",
    396,
    22,
    11,
    true
)

--==================================================
-- PACKAGE LIST
--==================================================

local packageList = Instance.new("ScrollingFrame")

packageList.Position = UDim2.fromOffset(12, 72)
packageList.Size = UDim2.new(1, -24, 0, 125)

packageList.BackgroundColor3 = Color3.fromRGB(17, 19, 25)
packageList.BorderSizePixel = 0
packageList.ScrollBarThickness = 5

packageList.Parent = main

local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 3)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = packageList

layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
    packageList.CanvasSize = UDim2.fromOffset(
        0,
        layout.AbsoluteContentSize.Y + 6
    )
end)

--==================================================
-- CAPTURE ROOT
--==================================================

makeLabel(
    "Local capture folder",
    205,
    20,
    11,
    false
)

local pathBox = Instance.new("TextBox")

pathBox.Position = UDim2.fromOffset(12, 227)
pathBox.Size = UDim2.new(1, -24, 0, 32)

pathBox.BackgroundColor3 = Color3.fromRGB(42, 46, 56)
pathBox.TextColor3 = Color3.new(1, 1, 1)

pathBox.Text = "MoonliteCapture"
pathBox.PlaceholderText = "MoonliteCapture"
pathBox.ClearTextOnFocus = false

pathBox.Font = Enum.Font.Code
pathBox.TextSize = 13
pathBox.Parent = main

Instance.new("UICorner", pathBox).CornerRadius =
    UDim.new(0, 6)

--==================================================
-- LOG
--==================================================

local logBox = Instance.new("TextLabel")

logBox.Position = UDim2.fromOffset(12, 434)
logBox.Size = UDim2.new(1, -24, 0, 88)

logBox.BackgroundColor3 = Color3.fromRGB(15, 17, 22)
logBox.TextColor3 = Color3.fromRGB(215, 220, 230)

logBox.TextXAlignment = Enum.TextXAlignment.Left
logBox.TextYAlignment = Enum.TextYAlignment.Top
logBox.TextWrapped = true

logBox.Font = Enum.Font.Code
logBox.TextSize = 10
logBox.Text = "Log:\nSelect a cutscene."

logBox.Parent = main

Instance.new("UICorner", logBox).CornerRadius =
    UDim.new(0, 6)

local function log(message)
    logBox.Text ..= "\n" .. tostring(message)
end

--==================================================
-- STATE
--==================================================

local selectedPackage = nil
local outputFolder = nil
local busy = false

--==================================================
-- DYNAMIC CUTSCENE DISCOVERY
--==================================================

local function refreshPackages()
    for _, child in ipairs(packageList:GetChildren()) do
        if child:IsA("TextButton") then
            child:Destroy()
        end
    end

    local found = {}

    for _, package in ipairs(CutScenes:GetChildren()) do
        local scene = package:FindFirstChild("Scene")

        if scene and Container.IsContainer(scene) then
            local ok, manifest = pcall(function()
                return Container.Read(scene)
            end)

            if ok then
                local frames, count = Stream.Layout(manifest)

                if frames and count then
                    table.insert(found, {
                        Package = package,
                        Count = count,
                    })
                end
            end
        end
    end

    table.sort(found, function(a, b)
        return a.Package.Name:lower()
            < b.Package.Name:lower()
    end)

    for index, entry in ipairs(found) do
        local button = Instance.new("TextButton")

        button.Size = UDim2.new(1, -8, 0, 27)
        button.BackgroundColor3 = Color3.fromRGB(47, 52, 64)

        button.TextColor3 = Color3.new(1, 1, 1)
        button.Text = string.format(
            "%s  [%d windows]",
            entry.Package.Name,
            entry.Count
        )

        button.Font = Enum.Font.Gotham
        button.TextSize = 12
        button.LayoutOrder = index
        button.Parent = packageList

        button.MouseButton1Click:Connect(function()
            selectedPackage = entry.Package

            selectedLabel.Text =
                "Selected: " .. entry.Package.Name

            status.Text = "Ready."
        end)
    end

    status.Text = "Found " .. #found .. " stream package(s)."
end

local refreshButton = makeButton(
    "Refresh",
    UDim2.new(1, -102, 0, 40),
    UDim2.fromOffset(90, 26),
    Color3.fromRGB(75, 82, 98)
)

refreshButton.MouseButton1Click:Connect(refreshPackages)

--==================================================
-- PROCESSING
--==================================================

local function process(useAcquisition)
    if busy then
        return
    end

    if not selectedPackage then
        status.Text = "Select a cutscene first."
        return
    end

    busy = true
    outputFolder = nil

    task.spawn(function()
        local ok, err = pcall(function()
            validateFilesystem()

            local package = selectedPackage
            local manifestScene = package:FindFirstChild("Scene")

            assert(
                manifestScene and Container.IsContainer(manifestScene),
                "Original Scene manifest missing"
            )

            local manifest = Container.Read(manifestScene)

            local captureRoot = pathBox.Text
            assert(captureRoot ~= "", "Capture folder is empty")

            local windows

            if useAcquisition then
                log("Starting cutscene acquisition...")

                windows = acquireCutscene(
                    package,
                    manifest,
                    captureRoot,
                    log
                )
            else
                log("Importing existing captures...")

                windows = importExisting(
                    package,
                    manifest,
                    captureRoot,
                    log
                )
            end

            status.Text = "Merging windows..."

            local merged, stats = mergeWindows(
                manifest,
                windows
            )

            log("Document validation passed.")
            log("Unique keys: " .. stats.TotalKeys)
            log("Duplicate boundary keys: " .. stats.DuplicateKeys)

            status.Text = "Creating final Scene..."

            local outputScene = Container.Create(merged)
            outputScene.Name = "Scene"

            local outputName =
                package.Name .. "_Reconstructed"

            local previous = Workspace:FindFirstChild(outputName)

            if previous then
                previous:Destroy()
            end

            local folder = Instance.new("Folder")
            folder.Name = outputName

            folder:SetAttribute("MoonliteGenerated", true)
            folder:SetAttribute("SourcePackage", package.Name)

            folder.Parent = Workspace
            outputScene.Parent = folder

            outputFolder = folder

            log("Created: " .. folder:GetFullName())
            log("Frames: " .. tostring(merged.Frames))
            log("Tracks: " .. #merged.Tracks)

            status.Text = "Complete! Scene is in Workspace."
        end)

        if not ok then
            status.Text = "Processing failed."
            log("ERROR: " .. tostring(err))
            warn("[Moonlite Tool]", err)
        end

        busy = false
    end)
end

--==================================================
-- ACTION BUTTONS
--==================================================

local acquireButton = makeButton(
    "Acquire + Decode + Merge",
    UDim2.fromOffset(12, 276),
    UDim2.new(1, -24, 0, 38),
    Color3.fromRGB(43, 126, 91)
)

local importButton = makeButton(
    "Import Existing Capture",
    UDim2.fromOffset(12, 322),
    UDim2.new(0.5, -18, 0, 34),
    Color3.fromRGB(69, 91, 128)
)

local exportButton = makeButton(
    "Export with SaveInstance",
    UDim2.new(0.5, 6, 0, 322),
    UDim2.new(0.5, -18, 0, 34),
    Color3.fromRGB(112, 79, 145)
)

acquireButton.MouseButton1Click:Connect(function()
    process(true)
end)

importButton.MouseButton1Click:Connect(function()
    process(false)
end)

exportButton.MouseButton1Click:Connect(function()
    if not outputFolder or not outputFolder.Parent then
        status.Text = "Nothing to export."
        return
    end

    local saveinstance = getAPI("saveinstance")

    if type(saveinstance) ~= "function" then
        status.Text = "saveinstance() unavailable."
        return
    end

    status.Text = "Exporting Workspace folder..."

    local ok, err = pcall(function()
        saveinstance({
            Object = outputFolder,
        })
    end)

    if ok then
        status.Text = "SaveInstance completed. Check its output location."
        log("Exported " .. outputFolder.Name)
    else
        status.Text = "SaveInstance failed."
        log(tostring(err))
    end
end)

--==================================================
-- STARTUP
--==================================================

gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

refreshPackages()

print("[Moonlite Cutscene Tool] Loaded.")
