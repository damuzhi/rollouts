# 应用 CRD 更新

## 步骤

### 1. 应用更新后的 CRD

```bash
# 应用更新后的 Rollout CRD
kubectl apply -f config/crd/bases/rollouts.kruise.io_rollouts.yaml
```

### 2. 验证 CRD 更新

```bash
# 检查 CRD 是否包含 groupOrder 字段
kubectl get crd rollouts.rollouts.kruise.io -o yaml | grep -A 10 "groupOrder"
```

应该能看到 `groupOrder` 字段的定义。

### 3. 应用 Rollout 配置

```bash
# 现在可以应用包含 groupOrder 的 Rollout 配置
kubectl apply -f canary-test-alb.yaml
```

## 如果遇到问题

如果 CRD 更新失败，可能需要：

1. **删除并重新创建 CRD**（谨慎操作）：
   ```bash
   kubectl delete crd rollouts.rollouts.kruise.io
   kubectl apply -f config/crd/bases/rollouts.kruise.io_rollouts.yaml
   ```

2. **或者使用 kubectl replace**：
   ```bash
   kubectl replace -f config/crd/bases/rollouts.kruise.io_rollouts.yaml
   ```

## 验证配置

应用 Rollout 后，验证 Canary Ingress 是否包含优先级注解：

```bash
# 检查 Canary Ingress 的 annotations
kubectl get ingress canary-test-canary -n centersys-release -o jsonpath='{.metadata.annotations}' | jq

# 应该能看到：
# "alb.ingress.kubernetes.io/group.order": "1"
```
