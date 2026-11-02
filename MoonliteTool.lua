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

-- Stream support is optional. Direct Moonlite documents do not need Stream.lua
-- or the RequestCutsceneChunk RemoteFunction to exist.
local StreamModule = Moonlite:FindFirstChild("Stream")
local Stream = if StreamModule then require(StreamModule) else nil

local CutScenes = RS.Assets.CutScenes

local function getRequestRemote()
    local network = RS:FindFirstChild("Network")
    local cutsceneNetwork = network and network:FindFirstChild("CutScenes")
    local remote = cutsceneNetwork and cutsceneNetwork:FindFirstChild("RF:RequestCutsceneChunk")

    assert(remote, "Stream capture remote is unavailable.")
    assert(remote:IsA("RemoteFunction"), "RequestCutsceneChunk is not a RemoteFunction")

    return remote
end

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

    for _, issue in ipairs(issues or {}) do
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

local function getStreamLayout(document)
    if not Stream or type(Stream.Layout) ~= "function" then
        return nil, nil
    end

    local ok, windowFrames, windowCount = pcall(Stream.Layout, document)

    if not ok then
        return nil, nil
    end

    return windowFrames, windowCount
end

local function inspectMissingChunks(scene)
    local details = {
        Expected = nil,
        Missing = {},
        Invalid = {},
    }

    local metadataOK, metadata = pcall(Container.GetMetadata, scene)
    if metadataOK and type(metadata) == "table" then
        details.Expected = tonumber(metadata.ChunkCount)
    end

    local dataFolder = scene:FindFirstChild("_MoonliteV3Data")

    if not dataFolder then
        if details.Expected and details.Expected > 0 then
            for index = 1, details.Expected do
                table.insert(details.Missing, index)
            end
        end
        return details
    end

    if details.Expected then
        for index = 1, details.Expected do
            local chunk = dataFolder:FindFirstChild(tostring(index))

            if not chunk then
                table.insert(details.Missing, index)
            elseif not chunk:IsA("StringValue") then
                table.insert(details.Invalid, index)
            elseif chunk.Value == "" then
                table.insert(details.Invalid, index)
            end
        end
    end

    return details
end

local function describeContainerFailure(scene, readError)
    local details = inspectMissingChunks(scene)
    local parts = {
        "Container.Read failed: " .. tostring(readError),
    }

    if details.Expected then
        table.insert(parts, "Expected chunks: " .. details.Expected)
    end

    if #details.Missing > 0 then
        local labels = {}
        for _, index in ipairs(details.Missing) do
            table.insert(labels, tostring(index))
        end
        table.insert(parts, "Missing chunk(s): " .. table.concat(labels, ", "))
    end

    if #details.Invalid > 0 then
        local labels = {}
        for _, index in ipairs(details.Invalid) do
            table.insert(labels, tostring(index))
        end
        table.insert(parts, "Empty/invalid chunk(s): " .. table.concat(labels, ", "))
    end

    return table.concat(parts, " | "), details
end

local function classifyScene(scene)
    local readOK, document = pcall(Container.Read, scene)

    if not readOK then
        local reason, chunkDetails = describeContainerFailure(scene, document)
        return {
            Mode = "Incomplete",
            Error = reason,
            ChunkDetails = chunkDetails,
        }
    end

    local windowFrames, windowCount = getStreamLayout(document)

    if windowFrames and windowCount then
        return {
            Mode = "Stream",
            Document = document,
            WindowFrames = windowFrames,
            Count = windowCount,
        }
    end

    local validOK, valid, issues = pcall(Document.Validate, document)

    if validOK and valid then
        if document.Metadata and document.Metadata.Stream ~= nil then
            return {
                Mode = "Invalid",
                Error = "The document has stream metadata, but Stream.Layout could not read its layout.",
            }
        end

        return {
            Mode = "Direct",
            Document = document,
            Count = document.Frames or 0,
        }
    end

    return {
        Mode = "Invalid",
        Error = "Document validation failed: " .. tostring(issues),
    }
end

local function countDocumentKeys(document)
    local total = 0

    for _, track in ipairs(document.Tracks or {}) do
        total += #(track.Keys or {})
    end

    return total
end

local function createWorkspaceOutput(package, document, mode, stats, log)
    validateDocument(document, mode .. " document")

    local outputScene = Container.Create(document)
    outputScene.Name = "Scene"

    local outputName = package.Name .. "_Reconstructed"
    local previous = Workspace:FindFirstChild(outputName)

    if previous then
        previous:Destroy()
    end

    local folder = Instance.new("Folder")
    folder.Name = outputName
    folder:SetAttribute("MoonliteGenerated", true)
    folder:SetAttribute("SourcePackage", package.Name)
    folder:SetAttribute("ReconstructionMode", mode)
    folder.Parent = Workspace
    outputScene.Parent = folder

    log("Created: " .. folder:GetFullName())
    log("Mode: " .. mode)
    log("Frames: " .. tostring(document.Frames))
    log("Tracks: " .. #(document.Tracks or {}))
    log("Keys: " .. tostring(stats.TotalKeys or countDocumentKeys(document)))

    return folder
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
    assert(Stream, "Stream.lua is not available for stream capture.")

    local RequestRemote = getRequestRemote()
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
    assert(Stream, "Stream.lua is not available for stream capture import.")

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

local UserInputService = game:GetService("UserInputService")

local gui = Instance.new("ScreenGui")
gui.Name = "MoonliteCutsceneTool"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.DisplayOrder = 50

local main = Instance.new("Frame")
main.Name = "Window"
main.Size = UDim2.fromOffset(700, 650)
main.Position = UDim2.new(0.5, -350, 0.5, -325)
main.BackgroundColor3 = Color3.fromRGB(16, 19, 27)
main.BorderSizePixel = 0
main.ClipsDescendants = true
main.Parent = gui

local mainCorner = Instance.new("UICorner")
mainCorner.CornerRadius = UDim.new(0, 14)
mainCorner.Parent = main

local mainStroke = Instance.new("UIStroke")
mainStroke.Color = Color3.fromRGB(67, 83, 112)
mainStroke.Transparency = 0.35
mainStroke.Thickness = 1.2
mainStroke.Parent = main

local topBar = Instance.new("Frame")
topBar.Name = "TopBar"
topBar.Size = UDim2.new(1, 0, 0, 66)
topBar.BackgroundColor3 = Color3.fromRGB(29, 40, 61)
topBar.BorderSizePixel = 0
topBar.Parent = main

local topGradient = Instance.new("UIGradient")
topGradient.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0, Color3.fromRGB(37, 62, 98)),
    ColorSequenceKeypoint.new(1, Color3.fromRGB(30, 36, 57)),
})
topGradient.Rotation = 0
topGradient.Parent = topBar

local topCorner = Instance.new("UICorner")
topCorner.CornerRadius = UDim.new(0, 14)
topCorner.Parent = topBar

local topFill = Instance.new("Frame")
topFill.Size = UDim2.new(1, 0, 0, 15)
topFill.Position = UDim2.new(0, 0, 1, -15)
topFill.BackgroundColor3 = Color3.fromRGB(30, 36, 57)
topFill.BorderSizePixel = 0
topFill.Parent = topBar

local brand = Instance.new("TextLabel")
brand.Size = UDim2.new(1, -110, 0, 29)
brand.Position = UDim2.fromOffset(20, 9)
brand.BackgroundTransparency = 1
brand.Text = "MOONLITE  /  V3 CUTSCENE TOOL"
brand.TextColor3 = Color3.fromRGB(245, 248, 255)
brand.TextXAlignment = Enum.TextXAlignment.Left
brand.Font = Enum.Font.GothamBold
brand.TextSize = 18
brand.Parent = topBar

local subtitle = Instance.new("TextLabel")
subtitle.Size = UDim2.new(1, -110, 0, 18)
subtitle.Position = UDim2.fromOffset(21, 37)
subtitle.BackgroundTransparency = 1
subtitle.Text = "DIRECT BUILD     •     STREAM CAPTURE     •     RECONSTRUCT"
subtitle.TextColor3 = Color3.fromRGB(174, 195, 224)
subtitle.TextXAlignment = Enum.TextXAlignment.Left
subtitle.Font = Enum.Font.GothamMedium
subtitle.TextSize = 10
subtitle.Parent = topBar

local closeButton = Instance.new("TextButton")
closeButton.Size = UDim2.fromOffset(34, 34)
closeButton.Position = UDim2.new(1, -48, 0, 16)
closeButton.BackgroundColor3 = Color3.fromRGB(57, 65, 84)
closeButton.BackgroundTransparency = 0.12
closeButton.Text = "×"
closeButton.TextColor3 = Color3.fromRGB(240, 244, 250)
closeButton.Font = Enum.Font.GothamMedium
closeButton.TextSize = 23
closeButton.Parent = topBar
Instance.new("UICorner", closeButton).CornerRadius = UDim.new(0, 8)
closeButton.MouseButton1Click:Connect(function()
    gui:Destroy()
end)

-- Make the window draggable from its title bar.
do
    local dragging = false
    local dragInput
    local dragStart
    local startPosition

    topBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPosition = main.Position

            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)

    topBar.InputChanged:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch then
            dragInput = input
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if dragging and input == dragInput then
            local delta = input.Position - dragStart
            main.Position = UDim2.new(
                startPosition.X.Scale,
                startPosition.X.Offset + delta.X,
                startPosition.Y.Scale,
                startPosition.Y.Offset + delta.Y
            )
        end
    end)
end

local function makeSection(parent, title, position, size)
    local panel = Instance.new("Frame")
    panel.Position = position
    panel.Size = size
    panel.BackgroundColor3 = Color3.fromRGB(23, 28, 39)
    panel.BorderSizePixel = 0
    panel.Parent = parent
    Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 10)

    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(58, 69, 91)
    stroke.Transparency = 0.55
    stroke.Thickness = 1
    stroke.Parent = panel

    local heading = Instance.new("TextLabel")
    heading.Size = UDim2.new(1, -24, 0, 22)
    heading.Position = UDim2.fromOffset(12, 7)
    heading.BackgroundTransparency = 1
    heading.Text = title
    heading.TextColor3 = Color3.fromRGB(171, 190, 218)
    heading.TextXAlignment = Enum.TextXAlignment.Left
    heading.Font = Enum.Font.GothamBold
    heading.TextSize = 10
    heading.Parent = panel

    return panel
end

local function makeButton(parent, text, position, size, color)
    local button = Instance.new("TextButton")
    button.Position = position
    button.Size = size
    button.BackgroundColor3 = color
    button.TextColor3 = Color3.fromRGB(246, 248, 252)
    button.Text = text
    button.Font = Enum.Font.GothamBold
    button.TextSize = 12
    button.AutoButtonColor = true
    button.Parent = parent
    Instance.new("UICorner", button).CornerRadius = UDim.new(0, 8)

    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(255, 255, 255)
    stroke.Transparency = 0.88
    stroke.Thickness = 1
    stroke.Parent = button

    return button
end

-- Cutscene library panel.
local libraryPanel = makeSection(
    main,
    "CUTSCENE LIBRARY",
    UDim2.fromOffset(14, 80),
    UDim2.new(1, -28, 0, 190)
)

local selectedLabel = Instance.new("TextLabel")
selectedLabel.Size = UDim2.new(1, -130, 0, 22)
selectedLabel.Position = UDim2.fromOffset(13, 31)
selectedLabel.BackgroundTransparency = 1
selectedLabel.Text = "No cutscene selected"
selectedLabel.TextColor3 = Color3.fromRGB(236, 241, 250)
selectedLabel.TextXAlignment = Enum.TextXAlignment.Left
selectedLabel.Font = Enum.Font.GothamSemibold
selectedLabel.TextSize = 12
selectedLabel.TextTruncate = Enum.TextTruncate.AtEnd
selectedLabel.Parent = libraryPanel

local refreshButton = makeButton(
    libraryPanel,
    "↻  REFRESH",
    UDim2.new(1, -112, 0, 27),
    UDim2.fromOffset(98, 28),
    Color3.fromRGB(56, 76, 108)
)

local packageList = Instance.new("ScrollingFrame")
packageList.Name = "PackageList"
packageList.Position = UDim2.fromOffset(12, 62)
packageList.Size = UDim2.new(1, -24, 1, -72)
packageList.BackgroundColor3 = Color3.fromRGB(15, 19, 28)
packageList.BorderSizePixel = 0
packageList.ScrollBarThickness = 4
packageList.ScrollBarImageColor3 = Color3.fromRGB(91, 124, 172)
packageList.CanvasSize = UDim2.fromOffset(0, 0)
packageList.Parent = libraryPanel
Instance.new("UICorner", packageList).CornerRadius = UDim.new(0, 7)

local packageLayout = Instance.new("UIListLayout")
packageLayout.Padding = UDim.new(0, 4)
packageLayout.SortOrder = Enum.SortOrder.LayoutOrder
packageLayout.Parent = packageList

packageLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
    packageList.CanvasSize = UDim2.fromOffset(0, packageLayout.AbsoluteContentSize.Y + 8)
end)

-- Capture folder panel.
local capturePanel = makeSection(
    main,
    "LOCAL CAPTURE STORAGE",
    UDim2.fromOffset(14, 282),
    UDim2.new(1, -28, 0, 79)
)

local pathBox = Instance.new("TextBox")
pathBox.Name = "CaptureRoot"
pathBox.Position = UDim2.fromOffset(12, 34)
pathBox.Size = UDim2.new(1, -24, 0, 32)
pathBox.BackgroundColor3 = Color3.fromRGB(14, 18, 27)
pathBox.TextColor3 = Color3.fromRGB(240, 244, 250)
pathBox.PlaceholderColor3 = Color3.fromRGB(125, 139, 160)
pathBox.PlaceholderText = "MoonliteCapture"
pathBox.Text = "MoonliteCapture"
pathBox.ClearTextOnFocus = false
pathBox.Font = Enum.Font.Code
pathBox.TextSize = 12
pathBox.TextXAlignment = Enum.TextXAlignment.Left
pathBox.Parent = capturePanel
Instance.new("UICorner", pathBox).CornerRadius = UDim.new(0, 7)

local pathPadding = Instance.new("UIPadding")
pathPadding.PaddingLeft = UDim.new(0, 10)
pathPadding.Parent = pathBox

-- Workflow actions.
local acquireButton = makeButton(
    main,
    "ACQUIRE  +  DECODE  +  MERGE",
    UDim2.fromOffset(14, 372),
    UDim2.new(0.5, -21, 0, 42),
    Color3.fromRGB(34, 133, 99)
)

local importButton = makeButton(
    main,
    "IMPORT EXISTING CAPTURE",
    UDim2.new(0.5, 7, 0, 372),
    UDim2.new(0.5, -21, 0, 42),
    Color3.fromRGB(61, 91, 139)
)

local exportButton = makeButton(
    main,
    "⇩   EXPORT RECONSTRUCTED MODEL",
    UDim2.fromOffset(14, 422),
    UDim2.new(1, -28, 0, 34),
    Color3.fromRGB(91, 71, 137)
)

-- Status strip.
local statusPanel = Instance.new("Frame")
statusPanel.Position = UDim2.fromOffset(14, 466)
statusPanel.Size = UDim2.new(1, -28, 0, 27)
statusPanel.BackgroundColor3 = Color3.fromRGB(28, 36, 50)
statusPanel.BorderSizePixel = 0
statusPanel.Parent = main
Instance.new("UICorner", statusPanel).CornerRadius = UDim.new(0, 7)

local statusDot = Instance.new("Frame")
statusDot.Size = UDim2.fromOffset(7, 7)
statusDot.Position = UDim2.fromOffset(10, 10)
statusDot.BackgroundColor3 = Color3.fromRGB(100, 194, 150)
statusDot.BorderSizePixel = 0
statusDot.Parent = statusPanel
Instance.new("UICorner", statusDot).CornerRadius = UDim.new(1, 0)

local status = Instance.new("TextLabel")
status.Position = UDim2.fromOffset(25, 0)
status.Size = UDim2.new(1, -35, 1, 0)
status.BackgroundTransparency = 1
status.Text = "Ready — select a direct or stream package"
status.TextColor3 = Color3.fromRGB(207, 218, 234)
status.TextXAlignment = Enum.TextXAlignment.Left
status.Font = Enum.Font.GothamMedium
status.TextSize = 11
status.Parent = statusPanel

-- Live log panel with one UI row per event.
local logPanel = makeSection(
    main,
    "LIVE ACTIVITY",
    UDim2.fromOffset(14, 502),
    UDim2.new(1, -28, 1, -516)
)

local logCount = Instance.new("TextLabel")
logCount.Size = UDim2.fromOffset(90, 20)
logCount.Position = UDim2.new(1, -102, 0, 7)
logCount.BackgroundTransparency = 1
logCount.Text = "0 EVENTS"
logCount.TextColor3 = Color3.fromRGB(126, 147, 178)
logCount.TextXAlignment = Enum.TextXAlignment.Right
logCount.Font = Enum.Font.GothamBold
logCount.TextSize = 9
logCount.Parent = logPanel

local logScroll = Instance.new("ScrollingFrame")
logScroll.Name = "LogFeed"
logScroll.Position = UDim2.fromOffset(10, 32)
logScroll.Size = UDim2.new(1, -20, 1, -42)
logScroll.BackgroundColor3 = Color3.fromRGB(13, 17, 25)
logScroll.BorderSizePixel = 0
logScroll.ScrollBarThickness = 4
logScroll.ScrollBarImageColor3 = Color3.fromRGB(91, 124, 172)
logScroll.CanvasSize = UDim2.fromOffset(0, 0)
logScroll.AutomaticCanvasSize = Enum.AutomaticSize.None
logScroll.Parent = logPanel
Instance.new("UICorner", logScroll).CornerRadius = UDim.new(0, 7)

local logLayout = Instance.new("UIListLayout")
logLayout.Padding = UDim.new(0, 2)
logLayout.SortOrder = Enum.SortOrder.LayoutOrder
logLayout.Parent = logScroll

local logPadding = Instance.new("UIPadding")
logPadding.PaddingTop = UDim.new(0, 5)
logPadding.PaddingBottom = UDim.new(0, 5)
logPadding.PaddingLeft = UDim.new(0, 6)
logPadding.PaddingRight = UDim.new(0, 6)
logPadding.Parent = logScroll

local eventCount = 0
local MAX_LOG_EVENTS = 150

local function scrollLogToBottom()
    task.defer(function()
        local height = logLayout.AbsoluteContentSize.Y + 12
        logScroll.CanvasSize = UDim2.fromOffset(0, height)
        local maxY = math.max(0, height - logScroll.AbsoluteWindowSize.Y)
        logScroll.CanvasPosition = Vector2.new(0, maxY)
    end)
end

logLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(scrollLogToBottom)

local function log(message)
    eventCount += 1
    local text = tostring(message)
    local lower = text:lower()

    local tag = "INFO"
    local color = Color3.fromRGB(196, 210, 230)
    local accent = Color3.fromRGB(104, 153, 216)

    if lower:find("error", 1, true) or lower:find("failed", 1, true)
        or lower:find("conflict", 1, true) then
        tag = "ERROR"
        color = Color3.fromRGB(255, 137, 137)
        accent = Color3.fromRGB(235, 84, 84)
    elseif lower:find("complete", 1, true) or lower:find("passed", 1, true)
        or lower:find("created:", 1, true) or lower:find("exported", 1, true) then
        tag = "DONE"
        color = Color3.fromRGB(133, 225, 178)
        accent = Color3.fromRGB(67, 190, 132)
    elseif lower:find("warning", 1, true) or lower:find("missing", 1, true) then
        tag = "WARN"
        color = Color3.fromRGB(255, 203, 125)
        accent = Color3.fromRGB(230, 164, 67)
    end

    local row = Instance.new("Frame")
    row.Name = "Event_" .. eventCount
    row.Size = UDim2.new(1, -2, 0, 24)
    row.BackgroundColor3 = Color3.fromRGB(20, 25, 35)
    row.BackgroundTransparency = 0.12
    row.BorderSizePixel = 0
    row.LayoutOrder = eventCount
    row.Parent = logScroll
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 4)

    local stripe = Instance.new("Frame")
    stripe.Size = UDim2.new(0, 3, 1, -8)
    stripe.Position = UDim2.fromOffset(4, 4)
    stripe.BackgroundColor3 = accent
    stripe.BorderSizePixel = 0
    stripe.Parent = row
    Instance.new("UICorner", stripe).CornerRadius = UDim.new(1, 0)

    local timeLabel = Instance.new("TextLabel")
    timeLabel.Position = UDim2.fromOffset(13, 0)
    timeLabel.Size = UDim2.fromOffset(62, 24)
    timeLabel.BackgroundTransparency = 1
    timeLabel.Text = os.date("%H:%M:%S")
    timeLabel.TextColor3 = Color3.fromRGB(116, 135, 162)
    timeLabel.Font = Enum.Font.Code
    timeLabel.TextSize = 10
    timeLabel.TextXAlignment = Enum.TextXAlignment.Left
    timeLabel.Parent = row

    local tagLabel = Instance.new("TextLabel")
    tagLabel.Position = UDim2.fromOffset(76, 0)
    tagLabel.Size = UDim2.fromOffset(42, 24)
    tagLabel.BackgroundTransparency = 1
    tagLabel.Text = tag
    tagLabel.TextColor3 = accent
    tagLabel.Font = Enum.Font.GothamBold
    tagLabel.TextSize = 9
    tagLabel.TextXAlignment = Enum.TextXAlignment.Left
    tagLabel.Parent = row

    local messageLabel = Instance.new("TextLabel")
    messageLabel.Position = UDim2.fromOffset(118, 0)
    messageLabel.Size = UDim2.new(1, -126, 1, 0)
    messageLabel.BackgroundTransparency = 1
    messageLabel.Text = text
    messageLabel.TextColor3 = color
    messageLabel.TextXAlignment = Enum.TextXAlignment.Left
    messageLabel.TextYAlignment = Enum.TextYAlignment.Center
    messageLabel.TextWrapped = true
    messageLabel.TextTruncate = Enum.TextTruncate.AtEnd
    messageLabel.Font = Enum.Font.Gotham
    messageLabel.TextSize = 10
    messageLabel.Parent = row

    if eventCount > MAX_LOG_EVENTS then
        local oldest
        for _, child in ipairs(logScroll:GetChildren()) do
            if child:IsA("Frame") and child.Name:match("^Event_") then
                if not oldest or child.LayoutOrder < oldest.LayoutOrder then
                    oldest = child
                end
            end
        end
        if oldest then oldest:Destroy() end
    end

    logCount.Text = tostring(math.min(eventCount, MAX_LOG_EVENTS)) .. " EVENTS"
    scrollLogToBottom()
end

log("Interface initialized.")
--==================================================
-- STATE
--==================================================

local selectedPackage = nil
local selectedPackageInfo = nil
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
            local info = classifyScene(scene)
            info.Package = package
            info.Scene = scene
            table.insert(found, info)
        end
    end

    table.sort(found, function(a, b)
        return a.Package.Name:lower()
            < b.Package.Name:lower()
    end)

    for index, entry in ipairs(found) do
        local button = Instance.new("TextButton")

        button.Size = UDim2.new(1, -8, 0, 30)
        button.BackgroundColor3 = Color3.fromRGB(35, 43, 58)

        button.TextColor3 = Color3.fromRGB(226, 235, 248)
        button.TextXAlignment = Enum.TextXAlignment.Left
        local modeLabel = if entry.Mode == "Stream" then
            string.format("STREAM • %d windows", entry.Count)
            elseif entry.Mode == "Direct" then
                string.format("DIRECT • %d frames", entry.Count)
            elseif entry.Mode == "Incomplete" then
                "INCOMPLETE • chunk data missing"
            else
                "INVALID • document check failed"

        button.Text = string.format(
            "   %s       •       %s",
            entry.Package.Name,
            modeLabel
        )

        button.Font = Enum.Font.Gotham
        button.TextSize = 12
        button.LayoutOrder = index
        button.Parent = packageList

        button.MouseButton1Click:Connect(function()
            selectedPackage = entry.Package
            selectedPackageInfo = entry

            for _, sibling in ipairs(packageList:GetChildren()) do
                if sibling:IsA("TextButton") then
                    sibling.BackgroundColor3 = Color3.fromRGB(35, 43, 58)
                end
            end
            button.BackgroundColor3 = if entry.Mode == "Incomplete" or entry.Mode == "Invalid"
                then Color3.fromRGB(108, 57, 62)
                else Color3.fromRGB(47, 91, 134)

            selectedLabel.Text = "SELECTED  /  " .. entry.Package.Name
            status.Text = entry.Mode .. " — " .. entry.Package.Name
            statusDot.BackgroundColor3 = if entry.Mode == "Incomplete" or entry.Mode == "Invalid"
                then Color3.fromRGB(235, 91, 91)
                else Color3.fromRGB(100, 194, 150)

            if entry.Mode == "Stream" then
                acquireButton.Text = "ACQUIRE + DECODE + MERGE"
                importButton.Visible = true
                log("Selected stream package: " .. entry.Package.Name)
            elseif entry.Mode == "Direct" then
                acquireButton.Text = "REBUILD DIRECT SCENE"
                importButton.Visible = false
                log("Selected direct package: " .. entry.Package.Name)
                log("No stream windows or chunk requests are required.")
            else
                acquireButton.Text = "INSPECT CONTAINER"
                importButton.Visible = false
                log(entry.Error or "Package is not readable.")
            end
        end)
    end

    local streamCount, directCount, incompleteCount = 0, 0, 0
    for _, entry in ipairs(found) do
        if entry.Mode == "Stream" then
            streamCount += 1
        elseif entry.Mode == "Direct" then
            directCount += 1
        elseif entry.Mode == "Incomplete" then
            incompleteCount += 1
        end
    end

    status.Text = string.format(
        "Found %d packages • %d stream • %d direct • %d incomplete",
        #found,
        streamCount,
        directCount,
        incompleteCount
    )
end

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
            local package = selectedPackage
            local manifestScene = package:FindFirstChild("Scene")

            assert(
                manifestScene and Container.IsContainer(manifestScene),
                "Original Scene container missing"
            )

            local readOK, manifestOrError = pcall(Container.Read, manifestScene)

            if not readOK then
                local reason = describeContainerFailure(manifestScene, manifestOrError)
                log(reason)
                error(reason)
            end

            local manifest = manifestOrError
            local windowFrames, windowCount = getStreamLayout(manifest)

            if (not windowFrames or not windowCount)
                and manifest.Metadata
                and manifest.Metadata.Stream ~= nil
            then
                error("Stream metadata exists, but its layout is invalid. Refusing to rebuild it as a Direct document.")
            end

            if not windowFrames or not windowCount then
                -- A non-stream cutscene already contains its complete timeline.
                -- Re-encode it into a fresh Moonlite container without window
                -- requests, packet import, or boundary-key merging.
                log("Direct mode: complete document found; no stream acquisition needed.")
                status.Text = "Rebuilding direct Scene..."
                statusDot.BackgroundColor3 = Color3.fromRGB(232, 177, 84)

                local directDocument = Document.Clone(manifest)
                directDocument.Metadata = directDocument.Metadata or {}
                directDocument.Metadata.Stream = nil

                validateDocument(directDocument, "Direct document")

                local stats = {
                    TotalKeys = countDocumentKeys(directDocument),
                    DuplicateKeys = 0,
                }

                outputFolder = createWorkspaceOutput(
                    package,
                    directDocument,
                    "Direct",
                    stats,
                    log
                )

                status.Text = "Complete — direct Scene rebuilt in Workspace."
                statusDot.BackgroundColor3 = Color3.fromRGB(83, 204, 145)
                return
            end

            -- Stream packages keep the original acquisition/import/merge path.
            validateFilesystem()

            local captureRoot = pathBox.Text
            assert(captureRoot ~= "", "Capture folder is empty")

            local windows

            if useAcquisition then
                log("Starting stream acquisition...")

                windows = acquireCutscene(
                    package,
                    manifest,
                    captureRoot,
                    log
                )
            else
                log("Importing existing stream captures...")

                windows = importExisting(
                    package,
                    manifest,
                    captureRoot,
                    log
                )
            end

            status.Text = "Merging windows..."
            statusDot.BackgroundColor3 = Color3.fromRGB(232, 177, 84)

            local merged, stats = mergeWindows(manifest, windows)

            log("Document validation passed.")
            log("Unique keys: " .. stats.TotalKeys)
            log("Duplicate boundary keys: " .. stats.DuplicateKeys)

            status.Text = "Creating final Scene..."
            statusDot.BackgroundColor3 = Color3.fromRGB(232, 177, 84)

            outputFolder = createWorkspaceOutput(
                package,
                merged,
                "Stream",
                stats,
                log
            )

            status.Text = "Complete — reconstructed Scene is in Workspace."
            statusDot.BackgroundColor3 = Color3.fromRGB(83, 204, 145)
        end)

        if not ok then
            status.Text = "Processing failed."
            statusDot.BackgroundColor3 = Color3.fromRGB(235, 91, 91)
            log("ERROR: " .. tostring(err))
            warn("[Moonlite Tool]", err)
        end

        busy = false
    end)
end

--==================================================
-- ACTION BUTTONS
--==================================================

acquireButton.MouseButton1Click:Connect(function()
    process(true)
end)

importButton.MouseButton1Click:Connect(function()
    process(false)
end)

-- Universal Syn Save Instance engine, loaded only when export is requested.
-- Credit: UniversalSynSaveInstance https://discord.gg/wx4ThpAsmw
local universalSaveInstance

exportButton.MouseButton1Click:Connect(function()
    if not outputFolder or not outputFolder.Parent then
        status.Text = "Nothing to export."
        return
    end

    status.Text = "Preparing Universal Syn Save Instance..."
    statusDot.BackgroundColor3 = Color3.fromRGB(232, 177, 84)

    local ok, err = pcall(function()
        if not universalSaveInstance then
            local HttpService = game:GetService("HttpService")
            local cacheToken = HttpService:GenerateGUID(false)

            local sourceUrl =
                "https://raw.githubusercontent.com/finalcircuitgame-crypto/UniversalSynSaveInstance/main/saveinstance.luau"
                .. "?_ussi_nocache="
                .. cacheToken

            log("Downloading Universal Syn Save Instance engine...")
            local source = game:HttpGet(sourceUrl, true)

            assert(
                type(source) == "string" and #source > 1000,
                "Universal Syn Save Instance download was empty or incomplete."
            )

            local compiler, compileError = loadstring(source, "@UniversalSynSaveInstance")
            assert(
                type(compiler) == "function",
                "Universal Syn Save Instance compile failed: " .. tostring(compileError)
            )

            local engine = compiler()
            assert(
                type(engine) == "function",
                "Universal Syn Save Instance did not return its save function."
            )

            universalSaveInstance = engine
            log("Universal Syn Save Instance loaded.")
        end

        status.Text = "Exporting reconstructed model..."
        -- Passing an Instance directly sets Object and exports only that model.
        universalSaveInstance(outputFolder)
    end)

    if ok then
        status.Text = "Export completed. Check the executor's output location."
        statusDot.BackgroundColor3 = Color3.fromRGB(83, 204, 145)
        log("USSI exported " .. outputFolder.Name)
    else
        status.Text = "Export failed."
        statusDot.BackgroundColor3 = Color3.fromRGB(235, 91, 91)
        log("USSI ERROR: " .. tostring(err))
        warn("[Moonlite Tool / USSI]", err)
    end
end)

--==================================================
-- STARTUP
--==================================================

gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

refreshPackages()

print("[Moonlite Cutscene Tool] Loaded.")
