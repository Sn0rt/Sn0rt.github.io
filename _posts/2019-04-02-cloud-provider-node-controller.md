---
author: sn0rt
comments: true
date: 2019-04-02
layout: post
title:  cloud provider node controller
tag: k8s
---

node controller 是负责初始化/维护一个k8s node在云上标识的信息，主要信息如下：

1: 初始化node的云相关的zone/region信息labels。
2: 初始化node的云上的实例信息，比如说type和szie。
3: 获取node的网络地址信息和主机名称。
4: 当客户通过云的虚拟机管理面板删除主机的时候需要从k8s中同步的删除node。


在实现上 cloud node controllr 核心逻辑只是重度依赖 cloud接口 和 node Informers。
```go
// startControllers starts the cloud specific controller loops.
func startControllers(c *cloudcontrollerconfig.CompletedConfig, stop <-chan struct{}, cloud cloudprovider.Interface) error {
...
   // Start the CloudNodeController
   nodeController := cloudcontrollers.NewCloudNodeController(
      c.SharedInformers.Core().V1().Nodes(),
      client("cloud-node-controller"), cloud,
      c.ComponentConfig.KubeCloudShared.NodeMonitorPeriod.Duration,
      c.ComponentConfig.NodeStatusUpdateFrequency.Duration)

   nodeController.Run(stop)
...
}
```

node controller 实现最开始描述4个需求只有两块核心逻辑:
	其一是周期性不断执行的`UpdateNodeStatus`和`MonitorNode`，前者是更新节点状态比如ip地址，后者通过云平台管理接口监控虚拟机，当客户通过虚拟机管理页面移除机器时候保证k8s中node也会被删除。
	其二是通过 controller 机制来触发的两个回调函数`AddCloudNode`和`UpdateCloudNode`添加虚拟机与云相关标签比如实例类型`x2.larget`实例Id`ins-xxx`还有ip地址等。

```go
// NewCloudNodeController creates a CloudNodeController object
func NewCloudNodeController(
   nodeInformer coreinformers.NodeInformer,
   kubeClient clientset.Interface,
   cloud cloudprovider.Interface,
   nodeMonitorPeriod time.Duration,
   nodeStatusUpdateFrequency time.Duration) *CloudNodeController {
...
   // Use shared informer to listen to add/update of nodes. Note that any nodes
   // that exist before node controller starts will show up in the update method
   cnc.nodeInformer.Informer().AddEventHandler(cache.ResourceEventHandlerFuncs{
      AddFunc:    cnc.AddCloudNode,
      UpdateFunc: cnc.UpdateCloudNode,
   })

   return cnc
}
```

cloud node controller 第一块逻辑：在实现上 cloud node controller 仅仅注册了2个回调函数，而且在实现上UpdateCloudNode调用了AddCloudNode。

```go
func (cnc *CloudNodeController) UpdateCloudNode(_, newObj interface{}) {
	if _, ok := newObj.(*v1.Node); !ok {
		utilruntime.HandleError(fmt.Errorf("unexpected object type: %v", newObj))
		return
	}
	cnc.AddCloudNode(newObj)
}
```

可以看一下 AddCloudNode 实现：
```go
// This processes nodes that were added into the cluster, and cloud initialize them if appropriate
func (cnc *CloudNodeController) AddCloudNode(obj interface{}) {
	node := obj.(*v1.Node)

// 这里一个判断是否要进入cloud node controller的初始化流程
	cloudTaint := getCloudTaint(node.Spec.Taints)
	if cloudTaint == nil {
		glog.V(2).Infof("This node %s is registered without the cloud taint. Will not process.", node.Name)
		return
	}

...
	err := clientretry.RetryOnConflict(UpdateNodeSpecBackoff, func() error {
// 移除了gce特有逻辑
...
		curNode, err := cnc.kubeClient.CoreV1().Nodes().Get(node.Name, metav1.GetOptions{})
		if err != nil {
			return err
		}
// 尝试填补 node spec provider:// 字段
		if curNode.Spec.ProviderID == "" {
			providerID, err := cloudprovider.GetInstanceProviderID(context.TODO(), cnc.cloud, types.NodeName(curNode.Name))
			if err == nil {
				curNode.Spec.ProviderID = providerID
			}
			...
		}

		nodeAddresses, err := getNodeAddressesByProviderIDOrName(instances, curNode)
		if err != nil {
			return err
		}

		// If user provided an IP address, ensure that IP address is found
		// in the cloud provider before removing the taint on the node
		if nodeIP, ok := ensureNodeProvidedIPExists(curNode, nodeAddresses); ok {
			if nodeIP == nil {
				return errors.New("failed to find kubelet node IP from cloud provider")
			}
		}

		if instanceType, err := getInstanceTypeByProviderIDOrName(instances, curNode); err != nil {
			return err
		} else if instanceType != "" {
			glog.V(2).Infof("Adding node label from cloud provider: %s=%s", kubeletapis.LabelInstanceType, instanceType)
			// 在instance spec 添加 instance type
			curNode.ObjectMeta.Labels[kubeletapis.LabelInstanceType] = instanceType
		}

		if zones, ok := cnc.cloud.Zones(); ok {
			zone, err := getZoneByProviderIDOrName(zones, curNode)
			if err != nil {
				return fmt.Errorf("failed to get zone from cloud provider: %v", err)
			}
			if zone.FailureDomain != "" {
				glog.V(2).Infof("Adding node label from cloud provider: %s=%s", kubeletapis.LabelZoneFailureDomain, zone.FailureDomain)
				// 在instance spec中准备zone信息
				curNode.ObjectMeta.Labels[kubeletapis.LabelZoneFailureDomain] = zone.FailureDomain
			}
			if zone.Region != "" {
				glog.V(2).Infof("Adding node label from cloud provider: %s=%s", kubeletapis.LabelZoneRegion, zone.Region)
				curNode.ObjectMeta.Labels[kubeletapis.LabelZoneRegion] = zone.Region
			}
		}

		curNode.Spec.Taints = excludeTaintFromList(curNode.Spec.Taints, *cloudTaint)
		// 去更新node spec
		_, err = cnc.kubeClient.CoreV1().Nodes().Update(curNode)
		if err != nil {
			return err
		}
		// After adding, call UpdateNodeAddress to set the CloudProvider provided IPAddresses
		// So that users do not see any significant delay in IP addresses being filled into the node
		cnc.updateNodeAddress(curNode, instances)
		return nil
	})
...

	glog.Infof("Successfully initialized node %s with cloud provider", node.Name)
}
```

cloud node controller 第二块逻辑：周期性调用`UpdateNodeStatus`和`MonitorNode`。
```go
// This controller deletes a node if kubelet is not reporting
// and the node is gone from the cloud provider.
func (cnc *CloudNodeController) Run(stopCh <-chan struct{}) {
   defer utilruntime.HandleCrash()

   // The following loops run communicate with the APIServer with a worst case complexity
   // of O(num_nodes) per cycle. These functions are justified here because these events fire
   // very infrequently. DO NOT MODIFY this to perform frequent operations.

   // Start a loop to periodically update the node addresses obtained from the cloud
   go wait.Until(cnc.UpdateNodeStatus, cnc.nodeStatusUpdateFrequency, stopCh)

   // Start a loop to periodically check if any nodes have been deleted from cloudprovider
   go wait.Until(cnc.MonitorNode, cnc.nodeMonitorPeriod, stopCh)
}
```

`UpdateNodeStatus`的实现更新了`ip address`。

```go
// UpdateNodeStatus updates the node status, such as node addresses
func (cnc *CloudNodeController) UpdateNodeStatus() {
   instances, ok := cnc.cloud.Instances()
...

   nodes, err := cnc.kubeClient.CoreV1().Nodes().List(metav1.ListOptions{ResourceVersion: "0"})
   if err != nil {
      glog.Errorf("Error monitoring node status: %v", err)
      return
   }

   for i := range nodes.Items {
      cnc.updateNodeAddress(&nodes.Items[i], instances)
   }
}
```

MonitorNode 函数也是周期性执行，当调用cloud provider发现节点不存在的时候也会从k8s中移除节点。

```go

// Monitor node queries the cloudprovider for non-ready nodes and deletes them
// if they cannot be found in the cloud provider
func (cnc *CloudNodeController) MonitorNode() {
...
	nodes, err := cnc.kubeClient.CoreV1().Nodes().List(metav1.ListOptions{ResourceVersion: "0"})
	if err != nil {
		glog.Errorf("Error monitoring node status: %v", err)
		return
	}

	for i := range nodes.Items {
		var currentReadyCondition *v1.NodeCondition
		node := &nodes.Items[i]
		// Try to get the current node status
		// If node status is empty, then kubelet has not posted ready status yet. In this case, process next node
		for rep := 0; rep < nodeStatusUpdateRetry; rep++ {
			_, currentReadyCondition = nodeutilv1.GetNodeCondition(&node.Status, v1.NodeReady)
			if currentReadyCondition != nil {
				break
			}
			name := node.Name
			node, err = cnc.kubeClient.CoreV1().Nodes().Get(name, metav1.GetOptions{})
			if err != nil {
				glog.Errorf("Failed while getting a Node to retry updating NodeStatus. Probably Node %s was deleted.", name)
				break
			}
			time.Sleep(retrySleepTime)
		}
		if currentReadyCondition == nil {
			glog.Errorf("Update status of Node %v from CloudNodeController exceeds retry count or the Node was deleted.", node.Name)
			continue
		}
		// If the known node status says that Node is NotReady, then check if the node has been removed
		// from the cloud provider. If node cannot be found in cloudprovider, then delete the node immediately
		if currentReadyCondition != nil {
			if currentReadyCondition.Status != v1.ConditionTrue {
				// we need to check this first to get taint working in similar in all cloudproviders
				// current problem is that shutdown nodes are not working in similar way ie. all cloudproviders
				// does not delete node from kubernetes cluster when instance it is shutdown see issue #46442
				shutdown, err := nodectrlutil.ShutdownInCloudProvider(context.TODO(), cnc.cloud, node)
				if err != nil {
					glog.Errorf("Error checking if node %s is shutdown: %v", node.Name, err)
				}

				if shutdown && err == nil {
					// if node is shutdown add shutdown taint
					err = controller.AddOrUpdateTaintOnNode(cnc.kubeClient, node.Name, controller.ShutdownTaint)
					if err != nil {
						glog.Errorf("Error patching node taints: %v", err)
					}
					// Continue checking the remaining nodes since the current one is shutdown.
					continue
				}

				// Check with the cloud provider to see if the node still exists. If it
				// doesn't, delete the node immediately.
				exists, err := ensureNodeExistsByProviderID(instances, node)
				if err != nil {
					glog.Errorf("Error checking if node %s exists: %v", node.Name, err)
					continue
				}

				if exists {
					// Continue checking the remaining nodes since the current one is fine.
					continue
				}

				glog.V(2).Infof("Deleting node since it is no longer present in cloud provider: %s", node.Name)

				ref := &v1.ObjectReference{
					Kind:      "Node",
					Name:      node.Name,
					UID:       types.UID(node.UID),
					Namespace: "",
				}
				glog.V(2).Infof("Recording %s event message for node %s", "DeletingNode", node.Name)

				cnc.recorder.Eventf(ref, v1.EventTypeNormal, fmt.Sprintf("Deleting Node %v because it's not present according to cloud provider", node.Name), "Node %s event: %s", node.Name, "DeletingNode")

				go func(nodeName string) {
					defer utilruntime.HandleCrash()
					if err := cnc.kubeClient.CoreV1().Nodes().Delete(nodeName, nil); err != nil {
						glog.Errorf("unable to delete node %q: %v", nodeName, err)
					}
				}(node.Name)

			} else {
				// if taint exist remove taint
				err = controller.RemoveTaintOffNode(cnc.kubeClient, node.Name, node, controller.ShutdownTaint)
				if err != nil {
					glog.Errorf("Error patching node taints: %v", err)
				}
			}
		}
	}
}
```