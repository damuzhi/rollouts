function split(input, delimiter)
    local arr = {}
    string.gsub(input, '[^' .. delimiter ..']+', function(w) table.insert(arr, w) end)
    return arr
end

annotations = {}
if ( obj.annotations )
then
    annotations = obj.annotations
end

-- Infer stable service name from canary service name (remove -canary suffix)
local stableService = string.gsub(obj.canaryService, "-canary$", "")

-- AWS ALB uses actions and conditions annotations
-- Format: alb.ingress.kubernetes.io/actions.<action-name>
-- Format: alb.ingress.kubernetes.io/conditions.<action-name>
actionKey = string.format("alb.ingress.kubernetes.io/actions.%s", obj.canaryService)
conditionKey = string.format("alb.ingress.kubernetes.io/conditions.%s", obj.canaryService)

-- Build forward action
local action = {}
action.type = "forward"
action.forwardConfig = {}
action.forwardConfig.targetGroups = {}

-- Calculate weights
local canaryWeight = 0
local stableWeight = 100

if ( obj.weight ~= "-1" )
then
    canaryWeight = tonumber(obj.weight)
    stableWeight = 100 - canaryWeight
else
    -- If no weight specified but has matches, use 100% for canary (condition-based routing)
    if ( obj.matches and next(obj.matches) ~= nil )
    then
        canaryWeight = 100
        stableWeight = 0
    end
end

-- If weight is 0 and no matches, clear the annotations (no canary traffic)
if ( canaryWeight == 0 and (not obj.matches or next(obj.matches) == nil) )
then
    annotations[actionKey] = nil
    annotations[conditionKey] = nil
    return annotations
end

-- Add canary target group
if ( canaryWeight > 0 )
then
    local canaryTargetGroup = {}
    canaryTargetGroup.serviceName = obj.canaryService
    canaryTargetGroup.servicePort = 80
    -- Only add weight if using weighted routing (has weight and stable weight > 0)
    if ( obj.weight ~= "-1" and stableWeight > 0 )
    then
        canaryTargetGroup.weight = canaryWeight
    end
    table.insert(action.forwardConfig.targetGroups, canaryTargetGroup)
end

-- Add stable target group (only when using weighted routing)
if ( obj.weight ~= "-1" and stableWeight > 0 )
then
    local stableTargetGroup = {}
    stableTargetGroup.serviceName = stableService
    stableTargetGroup.servicePort = 80
    stableTargetGroup.weight = stableWeight
    table.insert(action.forwardConfig.targetGroups, stableTargetGroup)
end

-- Set action annotation
annotations[actionKey] = json.encode(action)

-- Build conditions if matches exist
if ( obj.matches and next(obj.matches) ~= nil )
then
    local conditions = {}
    local match = obj.matches[1]
    
    if ( match.headers and next(match.headers) ~= nil )
    then
        for _,header in ipairs(match.headers) do
            local condition = {}
            
            -- Handle cookie header - AWS ALB expects "cookie" as httpHeaderName
            local isCookieHeader = (header.name == "cookie" or header.name == "Cookie" or 
                                   string.lower(header.name) == "cookie" or
                                   string.find(string.lower(header.name), "cookie"))
            
            if ( isCookieHeader )
            then
                condition.field = "http-header"
                condition.httpHeaderConfig = {}
                condition.httpHeaderConfig.httpHeaderName = "cookie"
                
                -- Parse cookie value (format: "cookie-name=value")
                local cookieValues = {}
                if ( header.value )
                then
                    -- If value contains =, it's a cookie name=value pair (e.g., "starrycloud-canary=always")
                    if ( string.find(header.value, "=") )
                    then
                        table.insert(cookieValues, header.value)
                    else
                        -- Otherwise, treat as cookie name and add wildcard pattern
                        table.insert(cookieValues, header.value .. "=.*")
                    end
                end
                condition.httpHeaderConfig.values = cookieValues
            else
                -- Handle other headers
                condition.field = "http-header"
                condition.httpHeaderConfig = {}
                condition.httpHeaderConfig.httpHeaderName = header.name
                
                local values = {}
                if ( header.value )
                then
                    -- Split multiple values by semicolon if needed
                    local vals = split(header.value, ";")
                    for _,val in ipairs(vals) do
                        table.insert(values, val)
                    end
                end
                condition.httpHeaderConfig.values = values
            end
            
            table.insert(conditions, condition)
        end
    end
    
    -- Set condition annotation if conditions exist
    if ( next(conditions) ~= nil )
    then
        annotations[conditionKey] = json.encode(conditions)
    else
        annotations[conditionKey] = nil
    end
else
    -- Clear condition if no matches
    annotations[conditionKey] = nil
end

return annotations
