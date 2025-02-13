-- // Wait until the game is loaded
repeat task.wait() until game:IsLoaded()

-- // Services
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")

-- // Vars
local LocalPlayer = Players.LocalPlayer
local queue_on_teleport = syn.queue_on_teleport or queue_on_teleport or function(Script) end

-- // Utilities
local Utilities = {}
do
    -- // Combine two tables
    function Utilities.CombineTables(Base, ToAdd)
        -- // Default
        Base = Base or {}
        ToAdd = ToAdd or {}

        -- // Loop through data we want to add
        for i, v in pairs(ToAdd) do
            -- // Recursive
            local BaseValue = Base[i] or false
            if (typeof(v) == "table" and typeof(BaseValue) == "table") then
                Utilities.CombineTables(BaseValue, v)
                continue
            end

            -- // Set
            Base[i] = v
        end

        -- // Return
        return Base
    end

    -- // Deep copying
    function Utilities.DeepCopy(Original)
        -- // Assert
        assert(typeof(Original) == "table", "invalid type for Original (expected table)")

        -- // Vars
        local Copy = {}

        -- // Loop through original
        for i, v in pairs(Original) do
            -- // Recursion if table
            if (typeof(v) == "table") then
                v = Utilities.DeepCopy(v)
            end

            -- // Set
            Copy[i] = v
        end

        -- // Return the copy
        return Copy
    end
end

-- // Hop Manager
local HopManager = {}
HopManager.__index = HopManager
HopManager.__type = "HopManager"
do
    -- // Default data
    HopManager.DefaultData = {
        KickBeforeTeleport = true,
        MinimumPlayers = 1,
        MaximumPlayers = 1/0,
        HopInterval = 300,
        RetryDelay = 1,
        SaveLocation = "recenthops.json",
        ServerFormat = "https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100&cursor=%s",
        RecentHops = {},
        RetrySame = {
            Enum.TeleportResult.Flooded
        }
    }

    -- // Constructor
    function HopManager.new(Data)
        -- // Default and assert
        Data = Data or {}
        assert(typeof(Data) == "table", "invalid type for Data (expected table)")

        -- // Create the object
        local self = setmetatable({}, HopManager)

        -- // Load the defaults
        self.Data = Utilities.CombineTables(Utilities.DeepCopy(HopManager.DefaultData), Data)

        -- // Load the recent hops
        self:LoadFromFile()

        -- // Return the object
        return self
    end

    -- // Load hop data
    function HopManager:LoadFromFile()
        -- // Get the data
        local Data = self.Data
        local RecentHopData = isfile(Data.SaveLocation) and readfile(Data.SaveLocation) or "{}"

        -- // Decode it
        local RecentHops = HttpService:JSONDecode(RecentHopData)
        Data.RecentHops = RecentHops

        -- // Return it
        return RecentHops
    end

    -- // Saves the hop data to to a file
    function HopManager:Save()
        local Data = self.Data
        writefile(Data.SaveLocation, HttpService:JSONEncode(Data.RecentHops))
    end

    -- // Set hop data
    function HopManager:SaveJobId(JobId)
        -- // Assert
        assert(typeof(JobId) == "string", "invalid type for JobId (expected string)")

        -- // Add it and save
        self.Data.RecentHops[JobId] = tick()
        self:Save()

        -- // Return
        return true
    end

    -- // Ensures it's a valid job id
    function HopManager:CheckJobId(JobId)
        -- // Assert
        assert(typeof(JobId) == "string", "invalid type for JobId (expected string)")

        -- // Vars
        local Data = self.Data
        local HopData = Data.RecentHops[JobId]

        -- // Make sure we have the data
        if (not HopData) then
            return self:Set(JobId)
        end

        -- // Check if it has been the interval since
        if ((tick() - HopData) > Data.HopInterval) then
            return self:Set(JobId)
        end

        -- // Return false
        return false
    end

    -- // Gets a server list of valid servers
    function HopManager:GetServerList(PlaceId)
        -- // Default and assert
        PlaceId = PlaceId or game.PlaceId
        assert(typeof(PlaceId) == "number", "invalid type for PlaceId (expected number)")

        -- // Vars
        local Data = self.Data
        local Cursor = ""
        local Servers = {}

        -- // Constant loop
        while (true) do
            -- // Get the servers
            local ServersURL = Data.ServerFormat:format(PlaceId, Cursor)
            local ServerData = HttpService:JSONDecode(game:HttpGet(ServersURL))

            -- // Loop through the server list
            for _, Server in ipairs(ServerData.data) do
                --- // Vars
                local PlayerCount = Server.playing
                local ServerJobId = Server.id

                -- // Check the server is not the current server
                if (game.JobId == ServerJobId) then
                    continue
                end

                -- // Validate player count
                if not (PlayerCount and PlayerCount >= self.MinimumPlayers and PlayerCount <= Server.maxPlayers and PlayerCount <= self.MaximumPlayers) then
                    continue
                end

                -- // Validate the server's id
                if (not self:CheckJobId(ServerJobId)) then
                    continue
                end

                -- // Add server
                table.insert(Servers, Server)
            end

            -- // Ensure we have enough servers
            if (#Servers > 0) then
                break
            end

            -- // Increment cursor
            Cursor = ServerData.nextPageCursor
        end

        -- // Return all of the servers
        return Servers
    end

    -- // Retries teleport (additional args passed to :Hop)
    function HopManager:FailsafeHop(...)
        -- // Vars
        local ExtraArgs = {...}
        local Data = self.Data

        -- // See whenever the teleport failed
        local Connection
        Connection = TeleportService.TeleportInitFailed:Connect(function(Player, TeleportResult, ErrorMessage, PlaceId, TeleportOptions)
            -- // Make sure we failed to teleport
            if (Player ~= LocalPlayer) then
                return
            end

            -- // Set the JobId to hop to
            local JobId = table.find(Data.RetrySame) and TeleportOptions.ServerInstanceId

            -- // Notify then disconnect
            print("Teleport failed, TeleportResult: " .. TeleportResult.Name)
            Connection:Disconnect()

            -- // Retry teleport in time
            task.delay(Data.RetryDelay, function()
                print("Reattempting teleport")
                self:Hop(PlaceId, JobId, unpack(ExtraArgs))
            end)
        end)

        -- // Return
        return Connection
    end

    -- // Hop servers
    function HopManager:Hop(PlaceId, JobId, Script)
        -- // Default and assert
        PlaceId = PlaceId or game.PlaceId
        Script = Script or ""
        assert(typeof(PlaceId) == "number", "invalid type for PlaceId (expected number)")
        assert(typeof(JobId) == "string" or JobId == nil, "invalid type for JobId (expected string or nil)")
        assert(typeof(Script) == "string", "invalid type for Script (expected string)")

        -- // Grab the server if we're not given one
        if (not JobId) then
            local Servers = self:GetServerList(PlaceId)
            local TargetServer = Servers[1]
            JobId = TargetServer.JobId
        end

        -- // Save the Id so we don't come back to it
        self:SaveJobId(JobId)

        -- // Execute script
        queue_on_teleport(Script)

        -- // Kicking
        if (self.KickBeforeTeleport) then
            LocalPlayer:Kick("Teleporting...")
        end

        -- // Teleport to the server
        self:FailsafeHop(Script)
        TeleportService:TeleportToPlaceInstance(PlaceId, JobId)
    end
end

-- // Return
return HopManager, Utilities