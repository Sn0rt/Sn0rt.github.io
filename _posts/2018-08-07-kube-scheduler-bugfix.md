---
author: sn0rt
comments: true
date: 2018-08-07
layout: post
tag: 容器
title: kube-scheduler pod cidr bugfix
---

​	之前写一个需求需要做容器网络的规划，发现`kuberntes`在调度的时候不会把ip地址作为一个调度的参考项。也就是手当`node`上规划出来的子网中的ip用光且cpu和mem以及其他调度参考项都满足的时候pod还是会被分配到这个节点上，并且`kubelet`会伴随着如下报错：

```
NetworkPlugin kubenet failed to set up pod "frontend-jh0kf_default" network: Error adding container to network: no IP addresses available in network: kubenet
```

​	修复方案有很多种，核心思路是围绕着调度器参考的对象。比较优雅的方式是在`kube-scheduler`中将ip地址也作为一个调度资源，但是这个实现起来工作量相对其他方法大了一点；有个折中取巧的方式是利用`kube-scheduler`中的一个`Allocated Pod`来实现，工作量小，实现简单。

````diff
diff --git a/pkg/scheduler/cache/node_info.go b/pkg/scheduler/cache/node_info.go
index 31be774578e..6c9f5713e94 100644
--- a/pkg/scheduler/cache/node_info.go
+++ b/pkg/scheduler/cache/node_info.go
@@ -29,6 +29,8 @@ import (
        v1helper "k8s.io/kubernetes/pkg/apis/core/v1/helper"
        priorityutil "k8s.io/kubernetes/pkg/scheduler/algorithm/priorities/util"
        "k8s.io/kubernetes/pkg/scheduler/util"
+       "net"
+       "math"
 )

 var (
@@ -315,7 +317,16 @@ func (n *NodeInfo) AllowedPodNumber() int {
        if n == nil || n.allocatableResource == nil {
                return 0
        }
-       return n.allocatableResource.AllowedPodNumber
+       ip, cidr, err := net.ParseCIDR(n.node.Spec.PodCIDR)
+       if err != nil || ip.To4() == nil {
+               return n.allocatableResource.AllowedPodNumber
+       }
+       size, _ := cidr.Mask.Size()
+       if size >= 31 {
+               return 0
+       }
+       // -3 (network address, broadcaster address, gateway address)
+       return int(math.Min(math.Pow(2, float64(32-size)) - 3, float64(n.allocatableResource.AllowedPodNumber)))
 }
````

不过还有需要考虑的是当pod使用的是`  hostNetwork: true `，上面patch 工作是不符合预期的。

## 测试

### case --node-cidr-mask-size=30

期望只有一个pod分配到ip地址并运行，可以查看到cm的信息如下：
```
[root@VM_128_11_centos ~]# systemctl status kube-controller-manager.service -l
● kube-controller-manager.service - kube-controller-manager
   Loaded: loaded (/usr/lib/systemd/system/kube-controller-manager.service; enabled; vendor preset: disabled)
   Active: active (running) since Tue 2018-08-07 13:37:56 CST; 2min 23s ago
 Main PID: 20759 (kube-controller)
   CGroup: /system.slice/kube-controller-manager.service
           └─20759 /usr/bin/kube-controller-manager --node-cidr-mask-size=30 --cluster-cidr=10.255.0.0/19 --allocate-node-cidrs=true --master=http://127.0.0.1:60001 --cloud-config=/etc/kubernetes/qcloud.conf --service-account-private-key-file=/etc/kubernetes/server.key --service-cluster-ip-range=10.255.31.0/24 --allow-untagged-cloud=true --cloud-provider=qcloud --cluster-name=cls-n1jte9ty --root-ca-file=/etc/kubernetes/cluster-ca.crt --use-service-account-credentials=true --horizontal-pod-autoscaler-use-rest-clients=true
```
kubelet信息如下，看见`cni`插件的参数：

```
Aug 07 13:38:24 VM-0-43-ubuntu kubelet[23809]: I0807 13:38:24.454373   23809 kubenet_linux.go:308] CNI network config set to {
Aug 07 13:38:24 VM-0-43-ubuntu kubelet[23809]:   "cniVersion": "0.1.0",
Aug 07 13:38:24 VM-0-43-ubuntu kubelet[23809]:   "name": "kubenet",
Aug 07 13:38:24 VM-0-43-ubuntu kubelet[23809]:   "type": "bridge",
Aug 07 13:38:24 VM-0-43-ubuntu kubelet[23809]:   "bridge": "cbr0",
Aug 07 13:38:24 VM-0-43-ubuntu kubelet[23809]:   "mtu": 1500,
Aug 07 13:38:24 VM-0-43-ubuntu kubelet[23809]:   "addIf": "eth0",
Aug 07 13:38:24 VM-0-43-ubuntu kubelet[23809]:   "isGateway": true,
Aug 07 13:38:24 VM-0-43-ubuntu kubelet[23809]:   "ipMasq": false,
Aug 07 13:38:24 VM-0-43-ubuntu kubelet[23809]:   "hairpinMode": false,
Aug 07 13:38:24 VM-0-43-ubuntu kubelet[23809]:   "ipam": {
Aug 07 13:38:24 VM-0-43-ubuntu kubelet[23809]:     "type": "host-local",
Aug 07 13:38:24 VM-0-43-ubuntu kubelet[23809]:     "subnet": "10.255.0.0/30",
Aug 07 13:38:24 VM-0-43-ubuntu kubelet[23809]:     "gateway": "10.255.0.1",
Aug 07 13:38:24 VM-0-43-ubuntu kubelet[23809]:     "routes": [
Aug 07 13:38:24 VM-0-43-ubuntu kubelet[23809]:       { "dst": "0.0.0.0/0" }
Aug 07 13:38:24 VM-0-43-ubuntu kubelet[23809]:     ]
Aug 07 13:38:24 VM-0-43-ubuntu kubelet[23809]:   }
Aug 07 13:38:24 VM-0-43-ubuntu kubelet[23809]: }
```
确认一下运行中的pod数量和pod所在节点的信息：

```
[root@VM_128_11_centos ~]# kubectl get pod --all-namespaces | grep Running  | wc -l
1
```

```
[root@VM_128_11_centos ~]# kubectl describe node 172.30.0.43
...
Non-terminated Pods:         (1 in total)
  Namespace                  Name                       CPU Requests  CPU Limits  Memory Requests  Memory Limits
  ---------                  ----                       ------------  ----------  ---------------  -------------
  default                    guohao-555fb5456d-kdx8n    0 (0%)        0 (0%)      0 (0%)           0 (0%)
Allocated resources:
```

### case --node-cidr-mask-size=29

期望运行 2^(32-29) - 3 = 5 个pod分配到ip并运行，可以查看到下面kubelet的cni信息：

```
Aug 07 13:44:48 VM-0-43-ubuntu kubelet[25163]: I0807 13:44:48.669847   25163 docker_service.go:307] docker cri received runtime config &RuntimeConfig{NetworkConfig:&NetworkConfig{PodCidr:10.255.0.0/29,},}
Aug 07 13:44:48 VM-0-43-ubuntu kubelet[25163]: I0807 13:44:48.669902   25163 kubenet_linux.go:308] CNI network config set to {
Aug 07 13:44:48 VM-0-43-ubuntu kubelet[25163]:   "cniVersion": "0.1.0",
Aug 07 13:44:48 VM-0-43-ubuntu kubelet[25163]:   "name": "kubenet",
Aug 07 13:44:48 VM-0-43-ubuntu kubelet[25163]:   "type": "bridge",
Aug 07 13:44:48 VM-0-43-ubuntu kubelet[25163]:   "bridge": "cbr0",
Aug 07 13:44:48 VM-0-43-ubuntu kubelet[25163]:   "mtu": 1500,
Aug 07 13:44:48 VM-0-43-ubuntu kubelet[25163]:   "addIf": "eth0",
Aug 07 13:44:48 VM-0-43-ubuntu kubelet[25163]:   "isGateway": true,
Aug 07 13:44:48 VM-0-43-ubuntu kubelet[25163]:   "ipMasq": false,
Aug 07 13:44:48 VM-0-43-ubuntu kubelet[25163]:   "hairpinMode": false,
Aug 07 13:44:48 VM-0-43-ubuntu kubelet[25163]:   "ipam": {
Aug 07 13:44:48 VM-0-43-ubuntu kubelet[25163]:     "type": "host-local",
Aug 07 13:44:48 VM-0-43-ubuntu kubelet[25163]:     "subnet": "10.255.0.0/29",
Aug 07 13:44:48 VM-0-43-ubuntu kubelet[25163]:     "gateway": "10.255.0.1",
Aug 07 13:44:48 VM-0-43-ubuntu kubelet[25163]:     "routes": [
Aug 07 13:44:48 VM-0-43-ubuntu kubelet[25163]:       { "dst": "0.0.0.0/0" }
Aug 07 13:44:48 VM-0-43-ubuntu kubelet[25163]:     ]
Aug 07 13:44:48 VM-0-43-ubuntu kubelet[25163]:   }
Aug 07 13:44:48 VM-0-43-ubuntu kubelet[25163]: }
```

```shell
[root@VM_128_11_centos ~]# kubectl get pod --all-namespaces  |grep Running | wc -l
5
```

```shell
[root@VM_128_11_centos ~]# kubectl describe node 172.30.0.43
...
Non-terminated Pods:         (5 in total)
  Namespace                  Name                                CPU Requests  CPU Limits  Memory Requests  Memory Limits
  ---------                  ----                                ------------  ----------  ---------------  -------------
  default                    guohao-555fb5456d-kjzrk             0 (0%)        0 (0%)      0 (0%)           0 (0%)
  default                    guohao-555fb5456d-lxrmn             0 (0%)        0 (0%)      0 (0%)           0 (0%)
  default                    guohao-555fb5456d-t4fq4             0 (0%)        0 (0%)      0 (0%)           0 (0%)
  default                    guohao-555fb5456d-t9k2b             0 (0%)        0 (0%)      0 (0%)           0 (0%)
  kube-system                l7-lb-controller-95dcf7bd7-v9wx7    0 (0%)        0 (0%)      0 (0%)           0 (0%)
```

### 结论

当时`masksize`为`30`和`29`时候都是符合预期的，但是问题是只有使用`kubenet`时这个`patch`才能正常工作，如果使用其他的`CNI`实现这样实现就显得很鸡肋。因为`PodCIDR`是被`kubenet`传递给`host-local`插件的，其余的`cni`插件不一定使用这个。