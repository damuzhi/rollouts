# AWS ALB Traffic Routing 故障排查

## 问题：配置 aws-alb 后 ALB 没有任何反应

### 可能原因

1. **Lua 脚本未找到**
   - Rollout controller 无法加载 `aws-alb.lua` 脚本
   - 导致 ingress traffic routing 初始化失败

2. **Lua 脚本未打包到镜像中**
   - 如果使用预编译的镜像，可能不包含 `aws-alb.lua` 文件
   - 需要重新构建镜像或通过 ConfigMap 配置

### 解决方案

#### 方案一：通过 ConfigMap 配置（推荐）

创建或更新 `kruise-rollout-configuration` ConfigMap：

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: kruise-rollout-configuration
  namespace: kruise-rollout  # 根据实际 namespace 调整
data:
  "lua.traffic.routing.ingress.aws-alb": |
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
```

#### 方案二：检查 Rollout Controller 日志

查看 Rollout controller 的日志，确认是否有错误：

```bash
# 查找 Rollout controller pod
kubectl get pods -n kruise-rollout -l app=kruise-rollout

# 查看日志
kubectl logs -n kruise-rollout -l app=kruise-rollout --tail=100 | grep -i "aws-alb\|lua\|ingress"
```

常见错误信息：
- `aws-alb lua script is not found` - Lua 脚本未找到
- `execute lua failed` - Lua 脚本执行失败

#### 方案三：检查 Rollout 状态

```bash
# 查看 Rollout 状态
kubectl get rollout canary-test -n centersys-release -o yaml

# 查看 Rollout 事件
kubectl describe rollout canary-test -n centersys-release
```

#### 方案四：检查 Canary Ingress

Rollout 会自动创建一个 canary ingress（名称格式：`<ingress-name>-canary`）：

```bash
# 查看 canary ingress
kubectl get ingress canary-test-canary -n centersys-release -o yaml

# 检查 annotations
kubectl get ingress canary-test-canary -n centersys-release -o jsonpath='{.metadata.annotations}' | jq
```

应该看到以下 annotations：
- `alb.ingress.kubernetes.io/actions.canary-test-canary`
- `alb.ingress.kubernetes.io/conditions.canary-test-canary`

### 验证步骤

1. **确认 ConfigMap 存在**：
   ```bash
   kubectl get configmap kruise-rollout-configuration -n kruise-rollout
   ```

2. **确认 ConfigMap 包含 aws-alb 配置**：
   ```bash
   kubectl get configmap kruise-rollout-configuration -n kruise-rollout -o jsonpath='{.data}' | jq 'keys'
   ```
   应该包含 `lua.traffic.routing.ingress.aws-alb`

3. **重启 Rollout Controller**（如果修改了 ConfigMap）：
   ```bash
   kubectl rollout restart deployment kruise-rollout-controller -n kruise-rollout
   ```

4. **检查 Rollout 是否开始工作**：
   ```bash
   kubectl get rollout canary-test -n centersys-release -w
   ```

### 常见问题

#### Q: 为什么需要 ConfigMap？

A: 如果使用的是预编译的镜像（如官方镜像），可能不包含 `aws-alb.lua` 文件。通过 ConfigMap 可以动态配置 Lua 脚本，无需重新构建镜像。

#### Q: 如何确认 Lua 脚本是否加载成功？

A: 查看 Rollout controller 日志，如果看到类似 `Init Lua Configuration` 的日志，说明脚本已加载。如果看到 `aws-alb lua script is not found`，说明脚本未找到。

#### Q: ConfigMap 修改后需要重启吗？

A: 是的，修改 ConfigMap 后需要重启 Rollout controller 才能生效。
