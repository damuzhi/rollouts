# AWS ALB Traffic Routing 配置指南

## 概述

Kruise Rollout 支持通过 AWS Application Load Balancer (ALB) 进行流量路由控制。AWS ALB 使用 `actions` 和 `conditions` annotations 来配置流量分发和条件路由。

## 配置方式

### ⚠️ 重要：必须通过 ConfigMap 配置

**AWS ALB 支持需要通过 ConfigMap 配置 Lua 脚本**。如果使用预编译的镜像，可能不包含 `aws-alb.lua` 文件，必须通过 ConfigMap 提供。

### 步骤一：创建或更新 ConfigMap

创建或更新 `kruise-rollout-configuration` ConfigMap，添加 `aws-alb` 的 Lua 脚本：

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
        if ( obj.matches and next(obj.matches) ~= nil )
        then
            canaryWeight = 100
            stableWeight = 0
        end
    end

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
        if ( obj.weight ~= "-1" and stableWeight > 0 )
        then
            canaryTargetGroup.weight = canaryWeight
        end
        table.insert(action.forwardConfig.targetGroups, canaryTargetGroup)
    end

    -- Add stable target group
    if ( obj.weight ~= "-1" and stableWeight > 0 )
    then
        local stableTargetGroup = {}
        stableTargetGroup.serviceName = stableService
        stableTargetGroup.servicePort = 80
        stableTargetGroup.weight = stableWeight
        table.insert(action.forwardConfig.targetGroups, stableTargetGroup)
    end

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
                local isCookieHeader = (header.name == "cookie" or header.name == "Cookie" or 
                                       string.lower(header.name) == "cookie" or
                                       string.find(string.lower(header.name), "cookie"))
                
                if ( isCookieHeader )
                then
                    condition.field = "http-header"
                    condition.httpHeaderConfig = {}
                    condition.httpHeaderConfig.httpHeaderName = "cookie"
                    local cookieValues = {}
                    if ( header.value )
                    then
                        if ( string.find(header.value, "=") )
                        then
                            table.insert(cookieValues, header.value)
                        else
                            table.insert(cookieValues, header.value .. "=.*")
                        end
                    end
                    condition.httpHeaderConfig.values = cookieValues
                else
                    condition.field = "http-header"
                    condition.httpHeaderConfig = {}
                    condition.httpHeaderConfig.httpHeaderName = header.name
                    local values = {}
                    if ( header.value )
                    then
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
        
        if ( next(conditions) ~= nil )
        then
            annotations[conditionKey] = json.encode(conditions)
        else
            annotations[conditionKey] = nil
        end
    else
        annotations[conditionKey] = nil
    end

    return annotations
```

**应用 ConfigMap：**

```bash
kubectl apply -f rollout-configuration-aws-alb.yaml
```

**重启 Rollout Controller（使配置生效）：**

```bash
kubectl rollout restart deployment kruise-rollout-controller -n kruise-rollout
```

### 步骤二：验证配置

检查 ConfigMap 是否包含 aws-alb 配置：

```bash
kubectl get configmap kruise-rollout-configuration -n kruise-rollout -o jsonpath='{.data}' | jq 'keys'
```

应该看到 `lua.traffic.routing.ingress.aws-alb`。

## Rollout 配置示例

### 基本配置

```yaml
apiVersion: rollouts.kruise.io/v1beta1
kind: Rollout
metadata:
  name: canary-test
  namespace: centersys-release
spec:
  workloadRef:
    apiVersion: apps/v1
    kind: Deployment
    name: canary-test
  strategy:
    canary:
      enableExtraWorkloadForCanary: true
      steps:
        # 第一步：基于 Cookie 的条件路由
        - replicas: 2
          matches:
            - headers:
                - name: "cookie"
                  type: Exact
                  value: "starrycloud-canary=always"
          pause: {}
        # 第二步：10% 流量到 Canary（权重路由）
        - weight: 10
        # 第三步：50% 流量到 Canary
        - weight: 50
        # 第四步：100% 流量到 Canary
        - weight: 100
      patchPodTemplateMetadata:
        labels:
          canary-env: "true"
      trafficRoutings:
        - service: canary-test
          ingress:
            classType: aws-alb
            name: canary-test
```

## Ingress 配置

### 基本 Ingress 配置

AWS ALB Ingress 需要配置以下 annotations：

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: canary-test
  namespace: centersys-release
  annotations:
    # AWS ALB 基本配置
    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:us-west-2:533150811650:certificate/xxx
    alb.ingress.kubernetes.io/group.name: center-release-alb-public-2
    alb.ingress.kubernetes.io/healthcheck-path: /
    alb.ingress.kubernetes.io/healthcheck-protocol: HTTP
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS":443}]'
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/security-groups: sg-xxx
    alb.ingress.kubernetes.io/subnets: subnet-xxx,subnet-yyy
    alb.ingress.kubernetes.io/target-group-attributes: deregistration_delay.timeout_seconds=20
    alb.ingress.kubernetes.io/target-type: ip
    # Rollout 会自动管理以下 annotations：
    # - alb.ingress.kubernetes.io/actions.canary-test-canary
    # - alb.ingress.kubernetes.io/conditions.canary-test-canary
spec:
  ingressClassName: alb
  rules:
    - host: canary-test.center-public-release.staruniongame.com
      http:
        paths:
          - backend:
              service:
                name: canary-test
                port:
                  number: 80
            path: /*
            pathType: ImplementationSpecific
          - backend:
              service:
                name: canary-test-canary
                port:
                  number: 80
            path: /*
            pathType: ImplementationSpecific
```

## 工作原理

### 1. 条件路由（Matches）

当 Rollout step 中配置了 `matches` 时，Rollout 会创建以下 annotations：

**Conditions Annotation:**
```yaml
alb.ingress.kubernetes.io/conditions.canary-test-canary: |
  [{
    "field": "http-header",
    "httpHeaderConfig": {
      "httpHeaderName": "cookie",
      "values": ["starrycloud-canary=always"]
    }
  }]
```

**Actions Annotation:**
```yaml
alb.ingress.kubernetes.io/actions.canary-test-canary: |
  {
    "type": "forward",
    "forwardConfig": {
      "targetGroups": [
        {
          "serviceName": "canary-test-canary",
          "servicePort": 80
        }
      ]
    }
  }
```

**工作原理：**
- 匹配条件的请求会被路由到 canary 服务
- 不匹配条件的请求会走默认的 stable backend（通过 Ingress spec 中的第一个 backend）

### 2. 权重路由（Weight）

当 Rollout step 中配置了 `weight` 时，Rollout 会创建包含加权 target groups 的 action annotation：

```yaml
alb.ingress.kubernetes.io/actions.canary-test-canary: |
  {
    "type": "forward",
    "forwardConfig": {
      "targetGroups": [
        {
          "serviceName": "canary-test-canary",
          "servicePort": 80,
          "weight": 10
        },
        {
          "serviceName": "canary-test",
          "servicePort": 80,
          "weight": 90
        }
      ]
    }
  }
```

**工作原理：**
- 流量会按照权重比例在 stable 和 canary 服务之间分配
- 此时 conditions annotation 会被清除（因为不再需要条件匹配）

### 3. 服务名称推断

- **Canary 服务名**：默认为 `<stable-service-name>-canary`（如 `canary-test-canary`）
- **Stable 服务名**：从 canary 服务名推断（去掉 `-canary` 后缀）

## 配置示例（完整）

### Rollout 配置

```yaml
apiVersion: rollouts.kruise.io/v1beta1
kind: Rollout
metadata:
  name: canary-test
  namespace: centersys-release
spec:
  workloadRef:
    apiVersion: apps/v1
    kind: Deployment
    name: canary-test
  strategy:
    canary:
      enableExtraWorkloadForCanary: true
      steps:
        # 第一步：条件路由 - 只有匹配 cookie 的请求到 Canary
        - replicas: 2
          matches:
            - headers:
                - name: "cookie"
                  type: Exact
                  value: "starrycloud-canary=always"
          pause: {}
        # 第二步：权重路由 - 10% 流量到 Canary
        - weight: 10
        # 第三步：权重路由 - 50% 流量到 Canary
        - weight: 50
        # 第四步：权重路由 - 100% 流量到 Canary
        - weight: 100
      patchPodTemplateMetadata:
        labels:
          canary-env: "true"
      trafficRoutings:
        - service: canary-test
          ingress:
            classType: aws-alb
            name: canary-test
```

### Ingress 配置

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: canary-test
  namespace: centersys-release
  annotations:
    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:us-west-2:533150811650:certificate/xxx
    alb.ingress.kubernetes.io/group.name: center-release-alb-public-2
    alb.ingress.kubernetes.io/healthcheck-path: /
    alb.ingress.kubernetes.io/healthcheck-protocol: HTTP
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS":443}]'
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/security-groups: sg-xxx
    alb.ingress.kubernetes.io/subnets: subnet-xxx,subnet-yyy
    alb.ingress.kubernetes.io/target-group-attributes: deregistration_delay.timeout_seconds=20
    alb.ingress.kubernetes.io/target-type: ip
spec:
  ingressClassName: alb
  rules:
    - host: canary-test.center-public-release.staruniongame.com
      http:
        paths:
          - backend:
              service:
                name: canary-test
                port:
                  number: 80
            path: /*
            pathType: ImplementationSpecific
          - backend:
              service:
                name: canary-test-canary
                port:
                  number: 80
            path: /*
            pathType: ImplementationSpecific
```

## 注意事项

1. **Ingress Backend 配置**：
   - 你的配置使用 `port.number: 80`，这是可以的
   - 如果使用 `port.name: use-annotation`，AWS ALB Controller 会优先使用 actions annotation

2. **服务名称**：
   - 确保 stable 服务名和 canary 服务名符合命名规范
   - Canary 服务名 = Stable 服务名 + "-canary"

3. **AWS Load Balancer Controller 版本**：
   - 确保使用的 AWS Load Balancer Controller 版本支持 actions 和 conditions 功能

4. **条件路由 vs 权重路由**：
   - 使用 `matches` 时，会创建 condition annotation，实现条件路由
   - 使用 `weight` 时，会创建包含权重的 action annotation，实现权重路由
   - 两者可以结合使用：先条件路由，后权重路由

5. **Cookie 值格式**：
   - Cookie 值应该是完整格式，如 `"starrycloud-canary=always"`
   - Header name 可以是 `"cookie"` 或 `"canary-by-cookie"`，脚本会自动识别

6. **权重为 0 的情况**：
   - 当 weight 为 0 且没有 matches 时，会清除所有相关 annotations（表示没有 canary 流量）

## 故障排查

### 问题：流量没有按预期路由

1. 检查 Ingress annotations 是否正确创建：
   ```bash
   kubectl get ingress canary-test -n centersys-release -o yaml
   ```

2. 检查 Rollout 状态：
   ```bash
   kubectl get rollout canary-test -n centersys-release -o yaml
   ```

3. 检查 AWS Load Balancer Controller 日志：
   ```bash
   kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
   ```

### 问题：Action annotation 未生效

- 检查 Ingress backend 配置是否正确
- 确认 AWS Load Balancer Controller 版本是否支持 actions 功能
- 检查 ALB target groups 是否正确创建

### 问题：Condition 匹配不工作

- 检查 cookie 值格式是否正确（应该是 `"cookie-name=value"` 格式）
- 确认请求中是否包含匹配的 cookie
- 检查 conditions annotation 的 JSON 格式是否正确

### 问题：权重路由不工作

- 确保 Rollout step 中配置了 `weight`（不是 `matches`）
- 检查 actions annotation 中是否包含两个 targetGroups（stable 和 canary）
- 确认每个 targetGroup 都有 `weight` 字段

## 技术细节

### Lua 脚本处理逻辑

1. **条件路由模式**（有 matches，无 weight）：
   - 创建 conditions annotation（包含匹配条件）
   - 创建 actions annotation（只包含 canary targetGroup，无 weight）

2. **权重路由模式**（有 weight）：
   - 创建 actions annotation（包含 stable 和 canary 两个 targetGroups，每个都有 weight）
   - 清除 conditions annotation

3. **无流量模式**（weight = 0 且无 matches）：
   - 清除所有相关 annotations

### Annotation 命名规则

- Action key: `alb.ingress.kubernetes.io/actions.<canary-service-name>`
- Condition key: `alb.ingress.kubernetes.io/conditions.<canary-service-name>`

其中 `<canary-service-name>` 默认为 `<stable-service-name>-canary`。
