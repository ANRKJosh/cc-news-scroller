--[[
    PoggishTown Times - Improved Server
    Features:
    - Persistent article storage
    - Article management (delete, list)
    - Client synchronization
    - Heartbeat system
    - Better error handling
]]

-- Configuration
local ARTICLES_FILE = "articles.txt"
local HEARTBEAT_INTERVAL = 30 -- seconds
local PROTOCOL = "poggish_news"

-- Auto-detect and open rednet modem
local function findAndOpenModem()
    local sides = {"top", "bottom", "left", "right", "front", "back"}
    
    for _, side in ipairs(sides) do
        if peripheral.getType(side) == "modem" then
            local modem = peripheral.wrap(side)
            if modem.isWireless() then
                rednet.open(side)
                print("Wireless modem found and opened on: " .. side)
                return side
            end
        end
    end
    
    error("No wireless modem found! Please attach a wireless modem to the computer.", 0)
end

local modemSide = findAndOpenModem()

-- Global variables
local articles = {}
local connectedClients = {}
local nextArticleId = 1

-- Utility functions
local function saveArticles()
    local file = fs.open(ARTICLES_FILE, "w")
    if file then
        file.write(textutils.serialize(articles))
        file.close()
        return true
    end
    return false
end

local function loadArticles()
    if fs.exists(ARTICLES_FILE) then
        local file = fs.open(ARTICLES_FILE, "r")
        if file then
            local data = file.readAll()
            file.close()
            articles = textutils.unserialize(data) or {}
            -- Find the next available ID
            for id, _ in pairs(articles) do
                if tonumber(id) >= nextArticleId then
                    nextArticleId = tonumber(id) + 1
                end
            end
        end
    end
end

local function broadcastToClients(message, protocol)
    rednet.broadcast(message, protocol or PROTOCOL)
    print("Broadcasted: " .. (protocol or PROTOCOL))
end

local function getMultilineInput(prompt)
    print(prompt)
    print("Type 'done' on a new line when you are finished.")
    local lines = {}
    while true do
        local line = read()
        if line:lower() == "done" then
            break
        end
        table.insert(lines, line)
    end
    return table.concat(lines, "\n")
end

local function displayMenu()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== PoggishTown Times Server ===")
    print("1. Write new article")
    print("2. List all articles")
    print("3. Delete article")
    print("4. Sync all clients")
    print("5. Show connected clients")
    print("6. Quit")
    print("Connected clients: " .. #connectedClients)
    term.write("Choose an option (1-6): ")
end

local function listArticles()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== All Articles ===")
    if next(articles) == nil then
        print("No articles found.")
    else
        for id, article in pairs(articles) do
            print("ID: " .. id)
            print("Headline: " .. article.headline)
            print("Content preview: " .. string.sub(article.content, 1, 50) .. "...")
            print("Timestamp: " .. (article.timestamp or "Unknown"))
            print("---")
        end
    end
    print("Press any key to continue...")
    read()
end

local function deleteArticle()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== Delete Article ===")
    listArticles()
    term.write("Enter article ID to delete (or 'cancel'): ")
    local input = read()
    
    if input:lower() == "cancel" then
        return
    end
    
    local id = input
    if articles[id] then
        articles[id] = nil
        saveArticles()
        -- Notify clients about deletion
        broadcastToClients({
            type = "delete",
            articleId = id
        }, PROTOCOL)
        print("Article deleted and clients notified.")
    else
        print("Article not found.")
    end
    print("Press any key to continue...")
    read()
end

local function writeNewArticle()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== Write New Article ===")
    
    term.write("Enter the headline: ")
    local headline = read()
    
    if headline:lower() == "cancel" then
        return
    end
    
    local content = getMultilineInput("Enter the content:")
    
    -- Create article with metadata
    local article = {
        id = tostring(nextArticleId),
        headline = headline,
        content = content,
        timestamp = os.date("%Y-%m-%d %H:%M:%S")
    }
    
    -- Store article
    articles[article.id] = article
    nextArticleId = nextArticleId + 1
    
    -- Save to file
    if saveArticles() then
        print("Article saved to file.")
    else
        print("Warning: Could not save to file!")
    end
    
    -- Broadcast to clients
    broadcastToClients({
        type = "new_article",
        article = article
    }, PROTOCOL)
    
    print("Article sent to all clients!")
    sleep(2)
end

local function syncAllClients()
    print("Syncing all articles to clients...")
    broadcastToClients({
        type = "full_sync",
        articles = articles
    }, PROTOCOL)
    print("Full sync sent to all clients.")
    sleep(2)
end

local function handleClientMessage(senderId, message)
    print("Received message from client " .. senderId .. ": " .. type(message))
    
    if type(message) == "table" then
        print("Message type: " .. (message.type or "nil"))
        
        if message.type == "heartbeat" then
            -- Update client list
            local found = false
            for i, clientId in ipairs(connectedClients) do
                if clientId == senderId then
                    found = true
                    break
                end
            end
            if not found then
                table.insert(connectedClients, senderId)
                print("New client connected: " .. senderId)
            end
            
            -- Send heartbeat response
            rednet.send(senderId, {type = "heartbeat_response"}, PROTOCOL)
            print("Sent heartbeat response to " .. senderId)
            
        elseif message.type == "request_sync" then
            -- Client requesting full sync
            local articleCount = 0
            for _ in pairs(articles) do articleCount = articleCount + 1 end
            print("Sending full sync to client " .. senderId .. " with " .. articleCount .. " articles")
            rednet.send(senderId, {
                type = "full_sync",
                articles = articles
            }, PROTOCOL)
            print("Sent full sync to client " .. senderId)
        else
            print("Unknown message type from client: " .. (message.type or "nil"))
        end
    else
        print("Non-table message from client: " .. tostring(message))
    end
end

-- Heartbeat function
local function sendHeartbeat()
    broadcastToClients({type = "server_heartbeat"}, PROTOCOL)
    -- Clean up disconnected clients (simplified)
    -- In a real implementation, you'd track response times
end

-- Load existing articles
loadArticles()
print("Loaded " .. #articles .. " articles from file.")

-- Start heartbeat timer
local heartbeatTimer = os.startTimer(HEARTBEAT_INTERVAL)

-- Main program loop
while true do
    displayMenu()
    
    -- Handle both user input and network messages
    local event, param1, param2, param3 = os.pullEvent()
    
    if event == "char" then
        local choice = param1
        
        if choice == "1" then
            writeNewArticle()
        elseif choice == "2" then
            listArticles()
        elseif choice == "3" then
            deleteArticle()
        elseif choice == "4" then
            syncAllClients()
        elseif choice == "5" then
            term.clear()
            term.setCursorPos(1, 1)
            print("=== Connected Clients ===")
            if #connectedClients == 0 then
                print("No clients connected.")
            else
                for i, clientId in ipairs(connectedClients) do
                    print("Client ID: " .. clientId)
                end
            end
            print("Press any key to continue...")
            read()
        elseif choice == "6" then
            print("Shutting down server...")
            break
        end
        
    elseif event == "rednet_message" then
        local senderId, message, protocol = param1, param2, param3
        print("Rednet message received - Sender: " .. senderId .. ", Protocol: " .. (protocol or "nil"))
        if protocol == PROTOCOL then
            handleClientMessage(senderId, message)
        else
            print("Wrong protocol, expected: " .. PROTOCOL)
        end
        
    elseif event == "timer" and param1 == heartbeatTimer then
        sendHeartbeat()
        heartbeatTimer = os.startTimer(HEARTBEAT_INTERVAL)
    end
end

-- Cleanup
rednet.close(modemSide)
print("Server shutdown complete.")
