---
weight: 51
title: "K8S HPA 源码解析"
date: 2024-12-15T01:57:40+08:00
lastmod: 2024-12-15T02:45:40+08:00
draft: false
author: "孙峰"
resources:
- name: "featured-image"
  src: "k8s-dev.jpg"

tags: ["Kubernetes-Dev"]
categories: ["Kubernetes-Dev"]

lightgallery: true
---

上一篇 <<[K8S HPA 内置指标使用详解及原理](https://sfeng1996.github.io/k8s-hpa/)>> 详细讲解了 HPA 的原理以及使用过程。本篇从源码角度分析 HPA 的工作原理。

## 周期性计算 metric

Kube-controller-manager 中 HorizontalPodAutoscaler 是一个 controller，通过 Watch/List HPA 资源对象，对该 HPA 关联的工作负载进行 Pod 扩缩容。

针对于每个 HPA 对象， HorizontalPodAutoscaler 会周期性去获取指标 metric 并计算副本数，判断是否需要扩缩容，这个周期默认是 15s，可以通过调整 Kube-controller-manager 的 `--horizontal-pod-autoscaler-sync-period` 参数设置，这块是在 Kube-controller-manager 启动 HorizontalPodAutoscaler  controller 时初始化 Workqueue 传入自定义队列限速器。

hpa controller 自身实现了 `FixedItemIntervalRateLimiter` 队列限速器，用于定期将元素返回至 workqueue 中

```go
// pkg/controller/podautoscaler/rate_limiters.go:39

// 获取 item 元素应该等待 interval 时间
func (r *FixedItemIntervalRateLimiter) When(item interface{}) time.Duration {
		return r.interval
}

// 返回元素失败的次数（也就是放入队列的次数）
// 这里始终返回 1
func (r *FixedItemIntervalRateLimiter) NumRequeues(item interface{}) int {
		return 1
}

// 表示元素已经完成了重试，不管是成功还是失败都会停止跟踪，也就是抛弃该元素
// 这里没有具体实现，因为对于 hpa controller 不能忘记元素, 需要周期性去处理元素
func (r *FixedItemIntervalRateLimiter) Forget(item interface{}) {
}
```

上面的 `r.interval` 就是 通过 `--horizontal-pod-autoscaler-sync-period` 传入的。这样即使 HPA 对象没有被更新，也可以周期性去获取元素处理了。

后续逻辑处理都是在 reconcileAutoscaler 函数里，分析下该函数里主要逻辑实现

```go
// pkg/controller/podautoscaler/horizontal.go:574
func (a *HorizontalController) reconcileAutoscaler(hpav1Shared *autoscalingv1.HorizontalPodAutoscaler, key string) error {
		......
		// 获取工作负载 scale 子资源
		scale, targetGR, err := a.scaleForResourceMappings(hpa.Namespace, hpa.Spec.ScaleTargetRef.Name, mappings)
		if err != nil {
			a.eventRecorder.Event(hpa, v1.EventTypeWarning, "FailedGetScale", err.Error())
			setCondition(hpa, autoscalingv2.AbleToScale, v1.ConditionFalse, "FailedGetScale", "the HPA controller was unable to get the target's current scale: %v", err)
			a.updateStatusIfNeeded(hpaStatusOriginal, hpa)
			return fmt.Errorf("failed to query scale subresource for %s: %v", reference, err)
		}
		
		......
		
		desiredReplicas := int32(0)
		rescaleReason := ""
	
		var minReplicas int32
		// 如果 HPA 对象没有设置 minReplicas, 则默认设置为 1
		if hpa.Spec.MinReplicas != nil {
			minReplicas = *hpa.Spec.MinReplicas
		} else {
			// Default value
			minReplicas = 1
		}
	
		rescale := true
		
		// 对于副本数是 0 的工作负载, HPA 不生效
		if scale.Spec.Replicas == 0 && minReplicas != 0 {
				// Autoscaling is disabled for this resource
				desiredReplicas = 0
				rescale = false
				setCondition(hpa, autoscalingv2.ScalingActive, v1.ConditionFalse, "ScalingDisabled", "scaling is disabled since the replica count of the target is zero")
		// 当前副本数大于 maxReplicas, 则将期望副本数设置为 maxReplicas, 也就是重置副本数
		} else if currentReplicas > hpa.Spec.MaxReplicas {
				rescaleReason = "Current number of replicas above Spec.MaxReplicas"
				desiredReplicas = hpa.Spec.MaxReplicas
		// 当前副本数小于 minReplicas, 则将副本数设置为 minReplicas
		} else if currentReplicas < minReplicas {
				rescaleReason = "Current number of replicas below Spec.MinReplicas"
				desiredReplicas = minReplicas
		// 其他情况就可以正常走 HPA 逻辑了
		} else {
				var metricTimestamp time.Time
				// 通过指标数据计算期望副本数
				metricDesiredReplicas, metricName, metricStatuses, metricTimestamp, err = a.computeReplicasForMetrics(hpa, scale, hpa.Spec.Metrics)
				if err != nil {
					a.setCurrentReplicasInStatus(hpa, currentReplicas)
					if err := a.updateStatusIfNeeded(hpaStatusOriginal, hpa); err != nil {
						utilruntime.HandleError(err)
					}
					a.eventRecorder.Event(hpa, v1.EventTypeWarning, "FailedComputeMetricsReplicas", err.Error())
					return fmt.Errorf("failed to compute desired number of replicas based on listed metrics for %s: %v", reference, err)
				}
		
				klog.V(4).Infof("proposing %v desired replicas (based on %s from %s) for %s", metricDesiredReplicas, metricName, metricTimestamp, reference)
	
				rescaleMetric := ""
				// 将期望副本数设置为计算出来的副本数
				if metricDesiredReplicas > desiredReplicas {
						desiredReplicas = metricDesiredReplicas
						rescaleMetric = metricName
				}
				if desiredReplicas > currentReplicas {
						rescaleReason = fmt.Sprintf("%s above target", rescaleMetric)
				}
				if desiredReplicas < currentReplicas {
						rescaleReason = "All metrics below target"
				}
				// HPA 不定义自定义 behavior, 使用默认的扩缩容行为, 并确定最终的期望副本数
				if hpa.Spec.Behavior == nil {
						desiredReplicas = a.normalizeDesiredReplicas(hpa, key, currentReplicas, desiredReplicas, minReplicas)
				} else {
						desiredReplicas = a.normalizeDesiredReplicasWithBehaviors(hpa, key, currentReplicas, desiredReplicas, minReplicas)
				}
				rescale = desiredReplicas != currentReplicas
		}
		
		// 更新副本数
		if rescale {
				scale.Spec.Replicas = desiredReplicas
				_, err = a.scaleNamespacer.Scales(hpa.Namespace).Update(context.TODO(), targetGR, scale, metav1.UpdateOptions{})
				if err != nil {
						a.eventRecorder.Eventf(hpa, v1.EventTypeWarning, "FailedRescale", "New size: %d; reason: %s; error: %v", desiredReplicas, rescaleReason, err.Error())
						setCondition(hpa, autoscalingv2.AbleToScale, v1.ConditionFalse, "FailedUpdateScale", "the HPA controller was unable to update the target scale: %v", err)
						a.setCurrentReplicasInStatus(hpa, currentReplicas)
						if err := a.updateStatusIfNeeded(hpaStatusOriginal, hpa); err != nil {
								utilruntime.HandleError(err)
						}
						return fmt.Errorf("failed to rescale %s: %v", reference, err)
				}
				......
		}
		......
}
```

可以看出 reconcileAutoscaler 主要是实现如下逻辑：

1、通过 `computeReplicasForMetrics()` 函数计算出期望的副本数

2、通过 `normalizeDesiredReplicas()` 函数得到稳行的副本数，通过该函数得出的副本数不会出现剧烈波动。该方法通常会平滑化副本数的变化，例如避免过快的扩容或缩容操作。

3、最后更新工作负载的副本数

下面主要详细分析 `computeReplicasForMetrics() 、normalizeDesiredReplicas()` 的实现

## 计算期望副本数

在主流程中通过 `computeReplicasForMetrics()` 函数计算期望副本数，

```go
// pkg/controller/podautoscaler/horizontal.go:248
func (a *HorizontalController) computeReplicasForMetrics(hpa *autoscalingv2.HorizontalPodAutoscaler, scale *autoscalingv1.Scale,
	metricSpecs []autoscalingv2.MetricSpec) (replicas int32, metric string, statuses []autoscalingv2.MetricStatus, timestamp time.Time, err error) {

		......

		// 遍历所有 metric, 一个 HPA 支持多个 metric 指标
		for i, metricSpec := range metricSpecs {
				// 调用 computeReplicasForMetric() 计算期望副本数
				replicaCountProposal, metricNameProposal, timestampProposal, condition, err := a.computeReplicasForMetric(hpa, metricSpec, specReplicas, statusReplicas, selector, &statuses[i])
		
				if err != nil {
						if invalidMetricsCount <= 0 {
							invalidMetricCondition = condition
							invalidMetricError = err
						}
						invalidMetricsCount++
				}
				// 求最大副本数
				if err == nil && (replicas == 0 || replicaCountProposal > replicas) {
						timestamp = timestampProposal
						****replicas = replicaCountProposal
						metric = metricNameProposal
				}
		}
	
		return replicas, metric, statuses, timestamp, nil
}
```

遍历该 HPA所有的 metrics，通过调用 `computeReplicasForMetric()` 获取对应 metric 的期望副本数，算出最大期望副本数，作为最终副本数。也就是说一个工作负载具有 metrics 的话，会采用计算得到最大的副本数。但是如果是多个 HPA 工作一个工作负载的话，则可能会存在指标相互影响的情况，所以建议多个 metric 关联同一个工作负载话将所有 metric 都写到一个 HPA 中。

接下来分析该函数的逻辑：

```go
// pkg/controller/podautoscaler/horizontal.go:302
func (a *HorizontalController) computeReplicasForMetric(hpa *autoscalingv2.HorizontalPodAutoscaler, spec autoscalingv2.MetricSpec,
	specReplicas, statusReplicas int32, selector labels.Selector, status *autoscalingv2.MetricStatus) (replicaCountProposal int32, metricNameProposal string,
	timestampProposal time.Time, condition autoscalingv2.HorizontalPodAutoscalerCondition, err error) {
	
		针对于五 metric 类型, 具有不同的计算逻辑
		switch spec.Type {
		// Object metric 类型
		case autoscalingv2.ObjectMetricSourceType:
				metricSelector, err := metav1.LabelSelectorAsSelector(spec.Object.Metric.Selector)
				if err != nil {
						condition := a.getUnableComputeReplicaCountCondition(hpa, "FailedGetObjectMetric", err)
						return 0, "", time.Time{}, condition, fmt.Errorf("failed to get object metric value: %v", err)
				}
				replicaCountProposal, timestampProposal, metricNameProposal, condition, err = a.computeStatusForObjectMetric(specReplicas, statusReplicas, spec, hpa, selector, status, metricSelector)
				if err != nil {
						return 0, "", time.Time{}, condition, fmt.Errorf("failed to get object metric value: %v", err)
				}
		// Pod metric 类型
		case autoscalingv2.PodsMetricSourceType:
				metricSelector, err := metav1.LabelSelectorAsSelector(spec.Pods.Metric.Selector)
				if err != nil {
						condition := a.getUnableComputeReplicaCountCondition(hpa, "FailedGetPodsMetric", err)
						return 0, "", time.Time{}, condition, fmt.Errorf("failed to get pods metric value: %v", err)
				}
				replicaCountProposal, timestampProposal, metricNameProposal, condition, err = a.computeStatusForPodsMetric(specReplicas, spec, hpa, selector, status, metricSelector)
				if err != nil {
						return 0, "", time.Time{}, condition, fmt.Errorf("failed to get pods metric value: %v", err)
				}
		// Resource metric 类型
		case autoscalingv2.ResourceMetricSourceType:
				replicaCountProposal, timestampProposal, metricNameProposal, condition, err = a.computeStatusForResourceMetric(specReplicas, spec, hpa, selector, status)
				if err != nil {
						return 0, "", time.Time{}, condition, err
				}
		// ContainerResource metric 类型
		case autoscalingv2.ContainerResourceMetricSourceType:
				replicaCountProposal, timestampProposal, metricNameProposal, condition, err = a.computeStatusForContainerResourceMetric(specReplicas, spec, hpa, selector, status)
				if err != nil {
						return 0, "", time.Time{}, condition, err
				}
		// External metric 类型
		case autoscalingv2.ExternalMetricSourceType:
				replicaCountProposal, timestampProposal, metricNameProposal, condition, err = a.computeStatusForExternalMetric(specReplicas, statusReplicas, spec, hpa, selector, status)
				if err != nil {
						return 0, "", time.Time{}, condition, err
				}
		default:
				errMsg := fmt.Sprintf("unknown metric source type %q", string(spec.Type))
				err = fmt.Errorf(errMsg)
				condition := a.getUnableComputeReplicaCountCondition(hpa, "InvalidMetricSourceType", err)
				return 0, "", time.Time{}, condition, err
		}
		return replicaCountProposal, metricNameProposal, timestampProposal, autoscalingv2.HorizontalPodAutoscalerCondition{}, nil
}
```

上一篇文章介绍过，HPA 中有四种不同的 metric 类型，这里又添加一个 **ContainerResource**，适用于一个 Pod 多个容器的场景，具体原理不多赘述。

因为在 HPA 中经常使用 Resource metric，下面详细分析 Resource metric 的计算逻辑，通过 `computeStatusForResourceMetric()` 函数实现，其他类型可自行分析源码了解详情。

```go
// pkg/controller/podautoscaler/horizontal.go:481
func (a *HorizontalController) computeStatusForResourceMetric(currentReplicas int32, metricSpec autoscalingv2.MetricSpec, hpa *autoscalingv2.HorizontalPodAutoscaler,
	selector labels.Selector, status *autoscalingv2.MetricStatus) (replicaCountProposal int32, timestampProposal time.Time,
	metricNameProposal string, condition autoscalingv2.HorizontalPodAutoscalerCondition, err error) {
	
		// 通过调用 computeStatusForResourceMetricGeneric() 计算期望副本数
		replicaCountProposal, metricValueStatus, timestampProposal, metricNameProposal, condition, err := a.computeStatusForResourceMetricGeneric(currentReplicas, metricSpec.Resource.Target, metricSpec.Resource.Name, hpa.Namespace, "", selector)
		if err != nil {
				condition = a.getUnableComputeReplicaCountCondition(hpa, "FailedGetResourceMetric", err)
				return replicaCountProposal, timestampProposal, metricNameProposal, condition, err
		}
		......
		return replicaCountProposal, timestampProposal, metricNameProposal, condition, nil
}
```

上面函数还是通过调用 `computeStatusForResourceMetricGeneric()` 获取期望副本数

```go
// pkg/controller/podautoscaler/horizontal.go:445
func (a *HorizontalController) computeStatusForResourceMetricGeneric(currentReplicas int32, target autoscalingv2.MetricTarget,
	resourceName v1.ResourceName, namespace string, container string, selector labels.Selector) (replicaCountProposal int32,
	metricStatus *autoscalingv2.MetricValueStatus, timestampProposal time.Time, metricNameProposal string,
	condition autoscalingv2.HorizontalPodAutoscalerCondition, err error) {
	  ......
	  // 处理扩缩容阈值为 AverageValue 类型
		if target.AverageValue != nil {
				var rawProposal int64
				replicaCountProposal, rawProposal, timestampProposal, err := a.replicaCalc.GetRawResourceReplicas(currentReplicas, target.AverageValue.MilliValue(), resourceName, namespace, selector, container)
				if err != nil {
						return 0, nil, time.Time{}, "", condition, fmt.Errorf("failed to get %s utilization: %v", resourceName, err)
				}
				metricNameProposal = fmt.Sprintf("%s resource", resourceName.String())
				status := autoscalingv2.MetricValueStatus{
						AverageValue: resource.NewMilliQuantity(rawProposal, resource.DecimalSI),
				}
				return replicaCountProposal, &status, timestampProposal, metricNameProposal, autoscalingv2.HorizontalPodAutoscalerCondition{}, nil
		}
	
		// 即不是 AverageValue 也不是 AverageUtilization 直接返回报错
		// Resource metric 阈值只能是 AverageValue、AverageUtilization 
		if target.AverageUtilization == nil {
				errMsg := "invalid resource metric source: neither a utilization target nor a value target was set"
				return 0, nil, time.Time{}, "", condition, fmt.Errorf(errMsg)
		}
	
		// 处理扩缩容阈值为 AverageUtilization 类型
		targetUtilization := *target.AverageUtilization
		replicaCountProposal, percentageProposal, rawProposal, timestampProposal, err := a.replicaCalc.GetResourceReplicas(currentReplicas, targetUtilization, resourceName, namespace, selector, container)
		if err != nil {
				return 0, nil, time.Time{}, "", condition, fmt.Errorf("failed to get %s utilization: %v", resourceName, err)
		}
	
		......
		
		return replicaCountProposal, &status, timestampProposal, metricNameProposal, autoscalingv2.HorizontalPodAutoscalerCondition{}, nil
}
```

因为 Resource metric 的 targetValue 支持 **AverageValue 、AverageUtilization** 两种类型，所以需要单独处理。

AverageValue 是平均值的意思，AverageUtilization 是平均利用率的意思，也就是说 `AverageUtilization = AverageValue / request`，K8S HPA 通过 request 值计算利用率.

先看 AverageValue 类型的逻辑：

```go
// pkg/controller/podautoscaler/horizontal.go:151
func (c *ReplicaCalculator) GetRawResourceReplicas(currentReplicas int32, targetUtilization int64, resource v1.ResourceName, namespace string, selector labels.Selector, container string) (replicaCount int32, utilization int64, timestamp time.Time, err error) {
	// 通过调用 metric-server 获取指标使用
	// 获取所有 pod 指标总和
	metrics, timestamp, err := c.metricsClient.GetResourceMetric(resource, namespace, selector, container)
	if err != nil {
		return 0, 0, time.Time{}, fmt.Errorf("unable to get metrics for resource %s: %v", resource, err)
	}
	
	// 传入指标值计算期望副本数
	replicaCount, utilization, err = c.calcPlainMetricReplicas(metrics, currentReplicas, targetUtilization, namespace, selector, resource)
	return replicaCount, utilization, timestamp, err
}
```

1、首先通过调用 metric-server 获取对应指标的使用量，注意这里获取的是该 HPA 关联的工作负载下所有实例的指标，通过 `map` 返回

2、传入 metrics 和调用 `calcPlainMetricReplicas()` 得到副本数

下面分析 `calcPlainMetricReplicas()` 实现

```go
// pkg/controller/podautoscaler/horizontal.go:176
func (c *ReplicaCalculator) calcPlainMetricReplicas(metrics metricsclient.PodMetricsInfo, currentReplicas int32, targetUtilization int64, namespace string, selector labels.Selector, resource v1.ResourceName) (replicaCount int32, utilization int64, err error) {

		// 获取所有该 HPA 关联的 Pod
		podList, err := c.podLister.Pods(namespace).List(selector)
		if err != nil {
				return 0, 0, fmt.Errorf("unable to get pods while calculating replica count: %v", err)
		}
	
		......
	
		// 将 Pod 分类, 得到 ready、unready、missing、ignored 几类
		readyPodCount, unreadyPods, missingPods, ignoredPods := groupPods(podList, metrics, resource, c.cpuInitializationPeriod, c.delayOfInitialReadinessStatus)
		// 将 unready、ignored 类型 pod 忽略，不在于 HPA 计算
		removeMetricsForPods(metrics, ignoredPods)
		removeMetricsForPods(metrics, unreadyPods)
	
		if len(metrics) == 0 {
				return 0, 0, fmt.Errorf("did not receive metrics for any ready pods")
		}
		
		// 计算指标平均使用量与 targetValue 的比值
		usageRatio, utilization := metricsclient.GetMetricUtilizationRatio(metrics, targetUtilization)
	
		// 当 unreadyPods 数量大于 0 并且需要扩容时, 设置 rebalanceIgnored 为 true
		rebalanceIgnored := len(unreadyPods) > 0 && usageRatio > 1.0
	
		if !rebalanceIgnored && len(missingPods) == 0 {
				// 没达到容忍度, 则不触发扩缩容
				if math.Abs(1.0-usageRatio) <= c.tolerance {
						// return the current replicas if the change would be too small
						return currentReplicas, utilization, nil
				}
	
				// 如果 1-usageRatio 大于容忍度, 说明达到扩缩容条件
				// usageRatio 乘以 readyPod 的数量再向上取整得到期望副本数
				return int32(math.Ceil(usageRatio * float64(readyPodCount))), utilization, nil
		}
	
		// 处理 missingPods 的 metric
		if len(missingPods) > 0 {
			// usageRatio < 1.0, 说明会缩容, 将 missingPods 的 metric 设置为 targetUtilization
			if usageRatio < 1.0 {
					// on a scale-down, treat missing pods as using 100% of the resource request
					for podName := range missingPods {
							metrics[podName] = metricsclient.PodMetric{Value: targetUtilization}
					}
			} else {
					// usageRatio > 1.0, 说明会扩容, 将 missingPods 的 metric 设置为 0
					// on a scale-up, treat missing pods as using 0% of the resource request
					for podName := range missingPods {
							metrics[podName] = metricsclient.PodMetric{Value: 0}
					}
				}
		}
	
		if rebalanceIgnored {
				// 对于 unreadyPods metric 在扩容时设置 metric 为 0
				for podName := range unreadyPods {
						metrics[podName] = metricsclient.PodMetric{Value: 0}
				}
		}
	
		// 使用新的 metrics 重新计算 usageRatio
		newUsageRatio, _ := metricsclient.GetMetricUtilizationRatio(metrics, targetUtilization)
	
		// 新的 usageRatio 没达到容忍度且与旧的 usageRatio 不一致, 则不执行扩缩容
		if math.Abs(1.0-newUsageRatio) <= c.tolerance || (usageRatio < 1.0 && newUsageRatio > 1.0) || (usageRatio > 1.0 && newUsageRatio < 1.0) {
				// return the current replicas if the change would be too small,
				// or if the new usage ratio would cause a change in scale direction
				return currentReplicas, utilization, nil
		}
			
		// 使用新的 metrics 计算新的副本数
		newReplicas := int32(math.Ceil(newUsageRatio * float64(len(metrics))))
		// 如果需要缩容且期望副本数大于当前副本数, 不执行缩容
		// 如果需要扩容且期望副本数小于副本数, 不执行扩容
		if (newUsageRatio < 1.0 && newReplicas > currentReplicas) || (newUsageRatio > 1.0 && newReplicas < currentReplicas) {
				// return the current replicas if the change of metrics length would cause a change in scale direction
				return currentReplicas, utilization, nil
		}
	
		// 返回期望副本数
		return newReplicas, utilization, nil
}
```

`calcPlainMetricReplicas()` 可以得到最终的期望副本数，但是考虑 一些特殊场景，还做了 `rebalanceIgnored` 是的扩缩容更加稳定和高效

1、首先获取该 HPA 关联所有的 Pod 实例

2、将所有 Pod 进行分类，用于后续处理，其中 ignoredPods、unreadyPods 会被忽略，不参与 HPA 计算，主要有以下几类：

- **ignoredPods**：pod 正在删除中或者是 Failed 状态
- **unreadyPods**：处于 Pending 状态的 pod
- **missingPods**：没有被 metric-server 获取到指标的 pod，可能由于网络或其他原因导致该时间段某些 pod 并没有被收集到指标
- **readyPods**：处于正常运行状态的 pod

3、调用 `GetMetricUtilizationRatio()` 获取 uasgeRatio，uasgeRatio 等于所有 Pod metric 平均使用量再除以目标阈值得到

```go
// pkg/controller/podautoscaler/metrics/utilization.go:54
func GetMetricUtilizationRatio(metrics PodMetricsInfo, targetUtilization int64) (utilizationRatio float64, currentUtilization int64) {
	metricsTotal := int64(0)
	// 求和所有 ready、missing pod 的 metric
	for _, metric := range metrics {
		metricsTotal += metric.Value
	}

	// 再除以 ready、missing pod 数量得到平均使用量
	currentUtilization = metricsTotal / int64(len(metrics))

	// 再除以目标阈值得到 uasgeRatio
	return float64(currentUtilization) / float64(targetUtilization), currentUtilization
}
```

> 这里的 missingPod 的 metric 值都是 0
>

4、如果该工作负载存在处于 Pending 状态的 pod 且计算需要扩容表示需要重新计算期望副本数，因为存在 Pending 状态 pod，可能后续就 ready，这时进行扩容不仅浪费资源，同时也会短时间内缩容，避免震荡

5、如果不需要重新计算副本数且所有 pod 都有 metric 值，这是运行正常的工作负载，可以直接返回副本数。

- 如果没达到容忍度，则不触发扩缩容
- 达到容忍度，则拿  usageRatio 乘以 readyPod 的数量再向上取整得到期望副本数
- 这里的容忍度用于防止因负载的微小波动而导致 Pod 数量频繁调整的一种机制。其作用是引入一个范围或阈值，只有当实际的资源利用率偏离目标利用率超过这个范围时，HPA 才会触发扩缩容行为。

6、如果工作负载中存在没有被收集到 metric 指标的 Pod，需要填充该类 Pod 的 metric 值，需要估计这些 Pod 对总负载的贡献，避免不合理的扩缩容

- 如果缩容将 metric 设置为 targetUtilization，避免错误低估负载导致过度缩容
- 如果扩容将 metric 设置为 0，controller 认为当前负载较高，设置为 0 有利于安全冗余集群资源

7、针对于 Pending 状态 Pod，设置 metric 为 0

8、使用新的 metrics 集合重新计算得到新的 usageRatio，新的 usageRatio 没达到容忍度且与旧的 usageRatio 不一致, 则不执行扩缩容

9，使用新的 metrics 集合重新计算得到新的副本数

到这 Resource 类型其 target 是 AverageValue 类型的副本数计算就全部梳理清楚了。

target 是 AverageUtilization  计算过程差不多类似，只是在求 usageRatio 的时候需要算下平均利用率，需要除以 request 值，代码如下：

```go
// pkg/controller/podautoscaler/metrics/utilization.go:23
func GetResourceUtilizationRatio(metrics PodMetricsInfo, requests map[string]int64, targetUtilization int32) (utilizationRatio float64, currentUtilization int32, rawAverageValue int64, err error) {
		metricsTotal := int64(0)
		requestsTotal := int64(0)
		numEntries := 0
	
		// 将 pod 的 request、metrics 分别求和
		for podName, metric := range metrics {
				request, hasRequest := requests[podName]
				if !hasRequest {
						// we check for missing requests elsewhere, so assuming missing requests == extraneous metrics
						continue
				}
	
				metricsTotal += metric.Value
				requestsTotal += request
				numEntries++
		}
	
		// if the set of requests is completely disjoint from the set of metrics,
		// then we could have an issue where the requests total is zero
		if requestsTotal == 0 {
				return 0, 0, 0, fmt.Errorf("no metrics returned matched known pods")
		}
	
		// metricsTotal 除以 requestsTotal 得到平均利用率
		currentUtilization = int32((metricsTotal * 100) / requestsTotal)
	
		// 处于 targetUtilization 得到 usageRatio
		return float64(currentUtilization) / float64(targetUtilization), currentUtilization, metricsTotal / int64(numEntries), nil
	}
```

## 稳定调整期望副本数

即使哦通过计算得到期望副本数，还需要再次进行稳定调整，避免频繁扩缩容或者超出限制条件（如 `minReplicas` 和 `maxReplicas`），导致副本数超出用户预期。用户可在 HPA 资源对象中自定义调整行为，不自定义可采用默认行为，看下 HPA 中默认的调整行为，主要 `normalizeDesiredReplicas()` 实现：

```go
func (a *HorizontalController) normalizeDesiredReplicas(hpa *autoscalingv2.HorizontalPodAutoscaler, key string, currentReplicas int32, prenormalizedDesiredReplicas int32, minReplicas int32) int32 {

		// 比较近期历史中推荐的副本数与计算得到副本数, 选择较大值
		stabilizedRecommendation := a.stabilizeRecommendation(key, prenormalizedDesiredReplicas)
		if stabilizedRecommendation != prenormalizedDesiredReplicas {
			setCondition(hpa, autoscalingv2.AbleToScale, v1.ConditionTrue, "ScaleDownStabilized", "recent recommendations were higher than current one, applying the highest recent recommendation")
		} else {
			setCondition(hpa, autoscalingv2.AbleToScale, v1.ConditionTrue, "ReadyForNewScale", "recommended size matches current size")
		}
	
		// 将稳定化的推荐值限制在 minReplicas 和 maxReplicas 范围内
		desiredReplicas, condition, reason := convertDesiredReplicasWithRules(currentReplicas, stabilizedRecommendation, minReplicas, hpa.Spec.MaxReplicas)
	
		if desiredReplicas == stabilizedRecommendation {
			setCondition(hpa, autoscalingv2.ScalingLimited, v1.ConditionFalse, condition, reason)
		} else {
			setCondition(hpa, autoscalingv2.ScalingLimited, v1.ConditionTrue, condition, reason)
		}
	
		return desiredReplicas
}
```

`normalizeDesiredReplicas()`  主要是先得到稳定副本数，然后将稳定后副本数限制在 minReplicas 和 maxReplicas 范围内

1、通过 `stabilizeRecommendation` 函数，考虑一段时间内的历史推荐值，对当前计算的期望副本数 (`prenormalizedDesiredReplicas`) 进行稳定化处理。如果历史记录中最近的推荐值较高，则选择较高值以避免因短期负载波动导致快速缩容。

2、稳定后的副本数可能是历史值，所以可能会不在 minReplicas 和 maxReplicas 范围内，需要限制下

最后就是调用 K8S Client 更新工作负载副本数了，以上就是 HPA 工作过程所有主流程的源码

## 总结

通过以上的源码分析，总结 HPA 就是通过 controller 周期性计算期望副本数，与当前副本数不一致就更新。

期望副本数计算公式：`DesiredReplicas = ceil{currentReplicas * [ ( sum(currentMetricValue) / sum(request) ) / desiredMetricUtilization ]}`

但是为了避免不必要的震荡、频繁扩缩容或者不合理的调整，controller 会使用一些策略保持稳定和高效。