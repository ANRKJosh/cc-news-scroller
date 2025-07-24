--[[
    PoggishTown Times - Improved Client
    Features:
    - Works with new server message format
    - Heartbeat system for connection monitoring
    - Better error handling and reconnection
    - Persistent article storage
    - Improved synchronization
]]

-- --- Configuration ---
local headlineViewTime = 10      -- Time in seconds to show the headline list
local articleViewTime = 20       -- Time to show a non-scrolling article
local autoScrollSpeed = 2.5      -- Time in seconds between each line scroll
local scrollEndPause = 5         -- Time to pause at the end of a scrolled article
local mainTitle = "PoggishTown Times"
local titleScale = 2.5           -- Scale for the main title (0.5, 1, 1.5, 2, 3, 4, 5)
local titleHeight = 2            -- Number of lines the title bar takes up (adjust based on scale) (default 2)
local headlineScale = 2        -- Scale for headline list text (default 1)
local articleScale = 1.5         -- Scale for article content text (default 1)
local PROTOCOL = "poggish_news"
local HEARTBEAT_INTERVAL = 35    -- Send heartbeat every 35 seconds
local ARTICLES_FILE = "client_articles.txt"

-- Auto-detect peripherals
local function findWirelessModem()
    local sides = {"top", "bottom", "left", "right", "front", "back"}
    
    for _, side in ipairs(sides) do
        if peripheral.getType(side) == "modem" then
            local modem = peripheral.wrap(side)
            if modem.isWireless() then
                print("Wireless modem found on: " .. side)
                return side
            end
        end
    end
    
    error("No wireless modem found! Please attach a wireless modem to the computer.", 0)
end

local function findMonitor()
    local sides = {"top", "bottom", "left", "right", "front", "back"}
    local foundMonitors = {}
    
    for _, side in ipairs(sides) do
        if peripheral.getType(side) == "monitor" then
            table.insert(foundMonitors, side)
        end
    end
    
    if #foundMonitors == 0 then
        error("No monitor found! Please attach a monitor to the computer.", 0)
    elseif #foundMonitors == 1 then
        print("Monitor found on: " .. foundMonitors[1])
        return foundMonitors[1]
    else
        -- Multiple monitors found, let user choose or pick the largest
        print("Multiple monitors found:")
        local bestMonitor = foundMonitors[1]
        local bestSize = 0
        
        for _, side in ipairs(foundMonitors) do
            local monitor = peripheral.wrap(side)
            local width, height = monitor.getSize()
            local size = width * height
            print("  " .. side .. ": " .. width .. "x" .. height .. " (" .. size .. " characters)")
            
            if size > bestSize then
                bestSize = size
                bestMonitor = side
            end
        end
        
        print("Using largest monitor: " .. bestMonitor)
        return bestMonitor
    end
end

-- Detect peripherals
local modemSide = findWirelessModem()
local monitorSide = findMonitor()

-- --- Globals ---
local articles = {}
local currentView = "headlines" -- "headlines" or "article"
local currentArticleIndex = 1
local headlineScroll = 0
local articleScroll = 0
local lastActionTime = os.clock()
local lastScrollTime = os.clock()
local lastHeartbeat = os.clock()
local needsScrolling = false
local serverConnected = false
local heartbeatTimer = nil

-- Get the monitor peripheral
local monitor = peripheral.wrap(monitorSide)
if not monitor then
    error("Monitor not found on side: " .. monitorSide, 0)
end

-- Open rednet to receive messages
rednet.open(modemSide)

-- --- Utility Functions ---

local function saveArticles()
    local file = fs.open(ARTICLES_FILE, "w")
    if file then
        file.write(textutils.serialize(articles))
        file.close()
        print("Articles saved to file")
    end
end

local function loadArticles()
    if fs.exists(ARTICLES_FILE) then
        local file = fs.open(ARTICLES_FILE, "r")
        if file then
            local data = file.readAll()
            file.close()
            articles = textutils.unserialize(data) or {}
            print("Loaded " .. #articles .. " articles from file")
        end
    end
end

local function sendHeartbeat()
    print("Sending heartbeat...")
    rednet.broadcast({
        type = "heartbeat",
        clientId = os.getComputerID()
    }, PROTOCOL)
    lastHeartbeat = os.clock()
    print("Heartbeat sent")
end

local function requestSync()
    print("Sending sync request...")
    rednet.broadcast({
        type = "request_sync",
        clientId = os.getComputerID()
    }, PROTOCOL)
    print("Sync request sent")
end

-- --- Drawing Functions ---

-- Function to wrap text to fit the monitor width
local function wrapText(text, width)
    local lines = {}
    if not text then return lines end
    
    -- Handle both string and table input
    local textStr = type(text) == "table" and table.concat(text, " ") or tostring(text)
    
    for line in textStr:gmatch("[^\n]+") do
        local currentLine = ""
        for word in line:gmatch("%S+") do
            if #currentLine == 0 then
                currentLine = word
            elseif #(currentLine .. " " .. word) <= width then
                currentLine = currentLine .. " " .. word
            else
                table.insert(lines, currentLine)
                currentLine = word
            end
        end
        if #currentLine > 0 then
            table.insert(lines, currentLine)
        end
    end
    return lines
end

-- Function to draw the main title bar with connection status
local function drawTitleBar(title, useMainTitle)
    local width, height = monitor.getSize()
    
    -- Always start with normal scale and black background
    monitor.setTextScale(1)
    monitor.setBackgroundColor(colors.black)
    monitor.setTextColor(colors.white)
    
    if useMainTitle then
        -- Draw the title bar area with gray background
        monitor.setBackgroundColor(colors.gray)
        monitor.setTextColor(colors.white)
        
        -- Clear the title lines
        for i = 1, titleHeight do
            monitor.setCursorPos(1, i)
            monitor.clearLine()
        end
        
        -- Set title scale and draw title
        monitor.setTextScale(titleScale)
        local scaledWidth = math.floor(width / titleScale)
        local titlePadding = math.max(1, math.floor((scaledWidth - #title) / 2))
        monitor.setCursorPos(titlePadding, 1)
        monitor.write(title)
        
        -- Reset to normal scale for status
        monitor.setTextScale(1)
        monitor.setBackgroundColor(colors.gray)
        
        -- Draw connection status
        local statusText = serverConnected and "LIVE" or "OFFLINE"
        local statusColor = serverConnected and colors.green or colors.red
        monitor.setTextColor(statusColor)
        monitor.setCursorPos(width - #statusText + 1, 1)
        monitor.write(statusText)
        
    else
        -- Simple title bar for articles
        monitor.setBackgroundColor(colors.gray)
        monitor.setTextColor(colors.white)
        monitor.setCursorPos(1, 1)
        monitor.clearLine()
        
        local displayTitle = title
        if #displayTitle > width - 10 then
            displayTitle = string.sub(displayTitle, 1, width - 13) .. "..."
        end
        
        local titlePadding = math.floor((width - #displayTitle) / 2)
        monitor.setCursorPos(titlePadding > 0 and titlePadding or 1, 1)
        monitor.write(displayTitle)
        
        local statusText = serverConnected and "LIVE" or "OFFLINE"
        local statusColor = serverConnected and colors.green or colors.red
        monitor.setTextColor(statusColor)
        monitor.setCursorPos(width - #statusText + 1, 1)
        monitor.write(statusText)
    end
    
    -- Always reset to black background and white text
    monitor.setTextScale(1)
    monitor.setBackgroundColor(colors.black)
    monitor.setTextColor(colors.white)
end

-- Function to draw the list of headlines
local function drawHeadlines()
    -- Start fresh
    monitor.setTextScale(1)
    monitor.setBackgroundColor(colors.black)
    monitor.clear()
    
    -- Draw title bar
    drawTitleBar(mainTitle, true)
    
    -- Ensure we're back to normal settings
    monitor.setTextScale(headlineScale)
    monitor.setBackgroundColor(colors.black)
    monitor.setTextColor(colors.white)

    local width, height = monitor.getSize()
    -- Adjust for scaling
    if headlineScale ~= 1 then
        width = math.floor(width / headlineScale)
        height = math.floor(height / headlineScale)
    end
    
    local y = titleHeight + 1 -- Start drawing below the title bar

    if #articles == 0 then
        monitor.setCursorPos(2, y)
        monitor.setTextColor(colors.gray)
        monitor.write("No articles available")
        monitor.setCursorPos(2, y + 1)
        monitor.write("Waiting for news...")
        monitor.setTextScale(1)
        return
    end

    -- Draw headlines with wrapping
    local articleIndex = headlineScroll + 1
    while articleIndex <= #articles and y <= height do
        local article = articles[articleIndex]
        if not article then break end
        
        -- Create headline text with number and timestamp
        local headlineText = tostring(articleIndex) .. ". " .. (article.headline or "No headline")
        if article.timestamp then
            local timeStr = string.sub(article.timestamp, 12, 16)
            headlineText = headlineText .. " (" .. timeStr .. ")"
        end
        
        -- Wrap the headline text
        local wrappedLines = wrapText(headlineText, width - 2)
        
        -- Draw each line of the wrapped headline
        for _, line in ipairs(wrappedLines) do
            if y > height then break end
            monitor.setCursorPos(2, y)
            monitor.setTextColor(colors.white)
            monitor.setBackgroundColor(colors.black)
            monitor.write(line)
            y = y + 1
        end
        
        -- Add a small gap between headlines if there's room
        if y <= height then
            y = y + 1
        end
        
        articleIndex = articleIndex + 1
    end
    
    -- Show scroll indicator if needed
    if headlineScroll > 0 or articleIndex <= #articles then
        monitor.setCursorPos(width - 1, height)
        monitor.setTextColor(colors.yellow)
        monitor.setBackgroundColor(colors.black)
        monitor.write("^")
    end
    
    -- Reset scale
    monitor.setTextScale(1)
end

-- Function to draw a single article
local function drawArticle()
    local article = articles[currentArticleIndex]
    if not article then 
        changeView("headlines")
        return 
    end

    local width, height = monitor.getSize()
    monitor.setBackgroundColor(colors.black)
    monitor.clear()

    -- Draw headline as title (simple style for articles)
    local headline = article.headline or "No headline"
    drawTitleBar(headline, false) -- Use simple title styling
    
    -- Set scale for article content
    monitor.setTextScale(articleScale)
    monitor.setBackgroundColor(colors.black)
    monitor.setTextColor(colors.white)
    
    -- Adjust dimensions for scaling
    if articleScale ~= 1 then
        width = math.floor(width / articleScale)
        height = math.floor(height / articleScale)
    end

    -- Show article info
    local y = 2
    if article.timestamp then
        monitor.setCursorPos(1, y)
        monitor.setTextColor(colors.gray)
        monitor.write("Published: " .. article.timestamp)
        y = y + 1
    end

    -- Draw content
    local contentYStart = y + 1
    local content = article.content or "No content available"
    local wrappedContent = wrapText(content, width)
    local contentHeight = height - contentYStart + 1

    -- Check if scrolling is needed for this article
    needsScrolling = #wrappedContent > contentHeight

    for i = articleScroll + 1, #wrappedContent do
        local lineY = contentYStart + (i - (articleScroll + 1))
        if lineY > height then break end
        monitor.setCursorPos(1, lineY)
        monitor.setTextColor(colors.white)
        monitor.write(wrappedContent[i])
    end
    
    -- Show scroll indicator
    if needsScrolling then
        monitor.setCursorPos(width, height)
        monitor.setTextColor(colors.yellow)
        if articleScroll < (#wrappedContent - contentHeight) then
            monitor.write("v")
        else
            monitor.write("*")
        end
    end
    
    -- Reset scale
    monitor.setTextScale(1)
end

-- --- Message Handling ---

local function handleServerMessage(senderId, message, protocol)
    print("Received message from " .. senderId .. " on protocol: " .. (protocol or "nil"))
    print("Message type: " .. type(message))
    
    if protocol ~= PROTOCOL then 
        print("Wrong protocol, ignoring")
        return 
    end
    
    serverConnected = true
    
    if type(message) ~= "table" then
        print("Non-table message: " .. tostring(message))
        -- Handle old-style message (direct article)
        if message.headline and message.content then
            table.insert(articles, 1, message)
            saveArticles()
            print("Added old-style article: " .. message.headline)
            if currentView == "headlines" then
                drawHeadlines()
            end
        end
        return
    end
    
    print("Message type field: " .. (message.type or "nil"))
    
    -- Handle new-style structured messages
    if message.type == "new_article" and message.article then
        -- New article received
        table.insert(articles, 1, message.article)
        saveArticles()
        print("New article received: " .. (message.article.headline or "Unknown"))
        if currentView == "headlines" then
            drawHeadlines()
        end
        
    elseif message.type == "full_sync" and message.articles then
        -- Full synchronization
        print("Received full_sync with " .. (#message.articles or "unknown") .. " articles")
        articles = {}
        for id, article in pairs(message.articles) do
            table.insert(articles, article)
        end
        -- Sort by ID (newest first)
        table.sort(articles, function(a, b)
            return tonumber(a.id or 0) > tonumber(b.id or 0)
        end)
        saveArticles()
        print("Processed full sync: " .. #articles .. " articles")
        if currentView == "headlines" then
            drawHeadlines()
        elseif currentView == "article" and currentArticleIndex > #articles then
            changeView("headlines")
        end
        
    elseif message.type == "delete" and message.articleId then
        -- Article deletion
        for i = #articles, 1, -1 do
            if articles[i].id == message.articleId then
                table.remove(articles, i)
                print("Article deleted: " .. message.articleId)
                break
            end
        end
        saveArticles()
        if currentView == "headlines" then
            drawHeadlines()
        elseif currentView == "article" and currentArticleIndex > #articles then
            changeView("headlines")
        end
        
    elseif message.type == "server_heartbeat" then
        -- Server heartbeat received
        print("Server heartbeat received")
        serverConnected = true
        
    elseif message.type == "heartbeat_response" then
        -- Server responded to our heartbeat
        print("Heartbeat response received")
        serverConnected = true
    else
        print("Unknown message type: " .. (message.type or "nil"))
    end
end

-- --- Main Logic ---

local function changeView(newView, newIndex)
    currentView = newView
    currentArticleIndex = newIndex or currentArticleIndex
    headlineScroll = 0
    articleScroll = 0
    lastActionTime = os.clock()
    lastScrollTime = os.clock()

    -- Ensure valid article index
    if currentArticleIndex > #articles then
        currentArticleIndex = 1
    end
    if currentArticleIndex < 1 then
        currentArticleIndex = 1
    end

    if currentView == "headlines" then
        drawHeadlines()
    elseif currentView == "article" and #articles > 0 then
        drawArticle()
    else
        changeView("headlines")
    end
end

local function cycleArticle()
    if #articles == 0 then 
        changeView("headlines")
        return 
    end

    local nextIndex = currentArticleIndex + 1
    if nextIndex > #articles then
        changeView("headlines", 1) -- Cycle back to headlines
    else
        changeView("article", nextIndex)
    end
end

-- Main program loop
local function run()
    -- Load saved articles
    loadArticles()
    
    -- Start with the headline view
    changeView("headlines")
    
    -- Send initial heartbeat and request sync
    print("Sending initial heartbeat...")
    sendHeartbeat()
    sleep(1)
    print("Requesting initial sync...")
    requestSync()
    
    heartbeatTimer = os.startTimer(HEARTBEAT_INTERVAL)
    print("Heartbeat timer started, entering main loop...")

    while true do
        local eventData = {os.pullEvent()} -- REMOVED the timeout - this was the issue!
        local event = eventData[1]

        -- Handle rednet messages
        if event == "rednet_message" then
            print("*** REDNET MESSAGE RECEIVED ***")
            local senderId, message, protocol = eventData[2], eventData[3], eventData[4]
            handleServerMessage(senderId, message, protocol)
            
        -- Handle heartbeat timer
        elseif event == "timer" and eventData[2] == heartbeatTimer then
            sendHeartbeat()
            heartbeatTimer = os.startTimer(HEARTBEAT_INTERVAL)
            
            -- Check connection status
            if os.clock() - lastHeartbeat > HEARTBEAT_INTERVAL + 10 then
                serverConnected = false
                if currentView == "headlines" then
                    drawHeadlines() -- Update connection status display
                end
            end

        -- Handle monitor scroll
        elseif event == "monitor_scroll" and eventData[2] == monitorSide then
            local direction = eventData[5]
            if currentView == "headlines" then
                headlineScroll = headlineScroll - direction
                if headlineScroll < 0 then headlineScroll = 0 end
                drawHeadlines()
            elseif currentView == "article" then
                articleScroll = articleScroll - direction
                if articleScroll < 0 then articleScroll = 0 end
                drawArticle()
                lastScrollTime = os.clock() -- Reset auto-scroll timer on manual scroll
            end

        -- Handle monitor touch (for manual navigation)
        elseif event == "monitor_touch" and eventData[2] == monitorSide then
            if currentView == "headlines" and #articles > 0 then
                changeView("article", 1)
            elseif currentView == "article" then
                cycleArticle()
            end
        end

        -- Handle automatic view changes and scrolling
        if #articles > 0 then
            local currentTime = os.clock()
            
            if currentView == "headlines" then
                if currentTime - lastActionTime >= headlineViewTime then
                    changeView("article", 1) -- Start cycle with the first article
                end
            elseif currentView == "article" then
                if needsScrolling then
                    local article = articles[currentArticleIndex]
                    if article then
                        local wrappedContent = wrapText(article.content, monitor.getSize())
                        local _, height = monitor.getSize()
                        local contentHeight = height - 3

                        if articleScroll < (#wrappedContent - contentHeight) then
                            -- We can still scroll down
                            if currentTime - lastScrollTime >= autoScrollSpeed then
                                articleScroll = articleScroll + 1
                                drawArticle()
                                lastScrollTime = currentTime
                            end
                        else
                            -- We have reached the end of the scroll
                            if currentTime - lastActionTime >= scrollEndPause then
                                cycleArticle()
                            end
                        end
                    end
                else
                    -- Article fits, no scrolling needed, just wait
                    if currentTime - lastActionTime >= articleViewTime then
                        cycleArticle()
                    end
                end
            end
        end
    end
end

-- --- Program Start ---
print("Starting PoggishTown Times Client...")
print("Monitor: " .. monitorSide .. ", Modem: " .. modemSide)
print("Computer ID: " .. os.getComputerID())
print("Protocol: " .. PROTOCOL)

run()

-- Close rednet when the program exits
rednet.close(modemSide)
